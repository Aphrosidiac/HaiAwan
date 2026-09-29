/**
 * The voice companion's model layer (v2).
 *
 * Awan talks through one ongoing conversation per session. The app owns that conversation (every user turn,
 * reply, tool call, tool result and silent context note) and runs the tools; the server owns the model, the
 * base instructions and the tool schemas, and streams each model round back as SSE:
 *
 *   POST /v1/companion/turn    one model round over the app's conversation → text deltas + tool calls
 *   POST /v1/companion/deeper  the deeper pass: a frontier vision model reads the full screenshots, the open
 *                              document and the user's drawing, and answers with pointing/drawing/typing tags
 *   POST /v1/companion/search  web lookup for the voice model's web_search tool
 *
 * The voice model is fast and conversational; anything that depends on exact screen positions or long reading
 * goes through `ask_deeper`, whose answer comes back as a tool result that the voice model then says aloud.
 */
import { complete, config, ProviderError, sseData, type ChatMessage } from './llm.ts';
import { COMPANION_SYSTEM } from './prompts.ts';

// ───────────────────────────── wire types ─────────────────────────────

export type ToolCall = { id: string; type: 'function'; function: { name: string; arguments: string } };
export type ContentPart =
  | { type: 'text'; text: string }
  | { type: 'image_url'; image_url: { url: string; detail?: 'low' | 'high' | 'auto' } };
export type ConversationItem =
  | { role: 'user'; content: string | ContentPart[] }
  | { role: 'assistant'; content: string | null; tool_calls?: ToolCall[] }
  | { role: 'tool'; tool_call_id: string; content: string };

export type ToolSchema = {
  type: 'function';
  function: { name: string; description: string; parameters: Record<string, unknown> };
};

/** What the app tells the server about the session (rendered into the instructions, never trusted as rules). */
export type PromptContext = {
  userFirstName?: string;
  timeZone?: string;
  connectedIntegrations?: string[];
  needsReconnectIntegrations?: string[];
  customConnectors?: { name: string; description?: string }[];
  activeSkills?: { name: string; oneLiner?: string }[];
  shortcuts?: { talk?: string; text?: string; dictation?: string };
  priorMessageCount?: number;
  alwaysOn?: boolean;
  muted?: boolean;
};

// ───────────────────────────── tools ─────────────────────────────

const str = (description: string) => ({ type: 'string', description });
const obj = (properties: Record<string, unknown>, required: string[] = []) => ({
  type: 'object',
  properties,
  required,
  additionalProperties: false,
});

/**
 * Every tool the voice model can call. The app says which ones it implements (`capabilities`); only those are
 * offered. Descriptions are the model's manual, so they say when to use each tool, not only what it does.
 */
export const VOICE_TOOLS: ToolSchema[] = [
  {
    type: 'function',
    function: {
      name: 'ask_deeper',
      description:
        "Send the request to Awan's deeper pass: a stronger vision model that sees the latest screenshots at full resolution, the complete text of the document the user has open, and anything the user drew while talking. It can move Awan's cursor to point at things, draw on the screen, run click-by-click walkthroughs, type into a field it can see, and show a strip of pictures. Use it whenever the answer depends on exactly what or where something is on screen (find, point, show, highlight, walk me through, what does this say, fix this code, reply to this email, read this page), whenever the question is about the open document, and for hard reasoning you'd rather not guess at. It returns the answer text plus what it did on screen.",
      parameters: obj(
        {
          question: str("The user's request in their own words, lightly cleaned up. Keep their wording and constraints."),
          focus: str('Optional: what to look at or what they mean by "this", from the conversation so far.'),
        },
        ['question'],
      ),
    },
  },
  {
    type: 'function',
    function: {
      name: 'look_at_screen',
      description:
        'Take fresh screenshots of every display right now and add them to the conversation. Use it when the user says something changed ("now?", "i opened it", "look again") or asks about the screen and no screenshot came with their message.',
      parameters: obj({}),
    },
  },
  {
    type: 'function',
    function: {
      name: 'start_awan_task',
      description:
        "Start background work in one of the user's Awans (persistent agents with their own workspace and memory that research, build files and sites, and work in connected apps). Use it for real work: research across sources, making a document, spreadsheet, deck or website, doing something inside an app, anything that takes more than a quick spoken answer. Pick the Awan whose job fits from the [Awans] note and pass its awan_slug. If none fits, found a new one with new_awan instead of awan_slug. Never use it for a question you can answer in a sentence or two.",
      parameters: obj(
        {
          task: str(
            'A complete, standalone instruction for the Awan in the user\'s terms: what to do, for whom, the deliverable, and any constraints they gave. Only ask for a file if the user asked for one or the work is itself a file.',
          ),
          awan_slug: str('The slug of the Awan to give it to (from the [Awans] note). Omit when founding a new one.'),
          new_awan: obj(
            {
              name: str('Two friendly words that say the job, like "Pitch Desk" or "Price Radar".'),
              role: str('Two or three word job title, like "Market researcher".'),
              description: str('One sentence, verb first: what this Awan does for the user.'),
            },
            ['name', 'role', 'description'],
          ),
        },
        ['task'],
      ),
    },
  },
  {
    type: 'function',
    function: {
      name: 'message_awan',
      description:
        'Send a follow-up, correction or steer to an Awan that is working or has worked on something ("make it shorter", "also check their prices", "use the blue one"). The message lands in its chat and it continues from what it already did.',
      parameters: obj(
        {
          awan_slug: str('The Awan to message (from the [Awans] note).'),
          message: str("The user's words, lightly cleaned up."),
        },
        ['awan_slug', 'message'],
      ),
    },
  },
  {
    type: 'function',
    function: {
      name: 'stop_awan',
      description: 'Stop what an Awan is doing right now, when the user asks to stop, cancel or never mind a running task.',
      parameters: obj({ awan_slug: str('The Awan to stop.') }, ['awan_slug']),
    },
  },
  {
    type: 'function',
    function: {
      name: 'awans_status',
      description:
        'List what every Awan is doing or last did: status, task, summary and the files it made. Use it for "how is it going", "what did it make", "is it done", or before opening something an Awan made.',
      parameters: obj({}),
    },
  },
  {
    type: 'function',
    function: {
      name: 'awan_memory',
      description:
        "Read an Awan's notes (its standing preferences and what it has learned) and the last messages of its chat. Use it to answer questions about what an Awan knows, found, decided or did, instead of guessing.",
      parameters: obj({ awan_slug: str('The Awan to read.') }, ['awan_slug']),
    },
  },
  {
    type: 'function',
    function: {
      name: 'answer_awan_request',
      description:
        'Answer an Awan that is waiting on the user (a PENDING REQUEST in the [Awans] note, such as permission to use the mouse and keyboard, or to keep going past its budget). "yes", "go ahead", "allow it" approve; "no", "not now" decline; "always" approves this and every later time.',
      parameters: obj(
        {
          awan_slug: str('The waiting Awan. Omit when exactly one is waiting.'),
          decision: { type: 'string', enum: ['approve', 'decline', 'always'] },
        },
        ['decision'],
      ),
    },
  },
  {
    type: 'function',
    function: {
      name: 'open_file',
      description:
        'Open (or reveal in Finder) a file or link an Awan made. Pass a path or URL from awans_status, or just the awan_slug to open its latest deliverable.',
      parameters: obj({
        awan_slug: str('Whose latest deliverable to open.'),
        path_or_url: str('An absolute path or URL from awans_status.'),
        action: { type: 'string', enum: ['open', 'reveal'] },
      }),
    },
  },
  {
    type: 'function',
    function: {
      name: 'open_home',
      description: "Open or close Awan's Home window (all the user's Awans and their chats), optionally on one Awan's chat.",
      parameters: obj({ action: { type: 'string', enum: ['open', 'close'] }, awan_slug: str('Open on this Awan.') }, ['action']),
    },
  },
  {
    type: 'function',
    function: {
      name: 'web_search',
      description:
        'Look something up on the web: news, prices, scores, weather, opening hours, anything that changes or that you are not sure of. Returns a short sourced answer.',
      parameters: obj({ query: str('What to look up, as a search query with any place or date that matters.') }, ['query']),
    },
  },
  {
    type: 'function',
    function: {
      name: 'remember',
      description:
        'Save a durable fact about the user to their memory when they tell you to remember something, or share something that will matter later (their name, job, projects, preferences, people). Not for passing chit-chat. Never secrets or passwords.',
      parameters: obj({ fact: str('One short line, in the third person ("Prefers British spelling").') }, ['fact']),
    },
  },
  {
    type: 'function',
    function: {
      name: 'type_text',
      description:
        'Type text into the field that has keyboard focus in the app the user is in (a reply, a message, a search, a form field). Use it when they ask you to write something in, and the text is fully decided. If they mean a field they can see but have not clicked into, use ask_deeper, which finds the field on screen. The typed text is never spoken.',
      parameters: obj({ text: str('Exactly what to type, ready to send, in the user\'s voice and the field\'s tone.') }, ['text']),
    },
  },
  {
    type: 'function',
    function: {
      name: 'copy_to_clipboard',
      description: 'Put text on the clipboard so the user can paste it with command V. Do not read the copied text aloud.',
      parameters: obj({ text: str('The text to copy.') }, ['text']),
    },
  },
  {
    type: 'function',
    function: {
      name: 'open_link',
      description: "Open a web address in the user's browser, or an app URL (for example a mailto: or maps link).",
      parameters: obj({ url: str('The full URL.') }, ['url']),
    },
  },
  {
    type: 'function',
    function: {
      name: 'read_file',
      description:
        'Read a text file, PDF or document on the Mac by absolute path (or ~/…). Returns its text, truncated if long. Use it when the user points you at a file by name or path.',
      parameters: obj({ path: str('Absolute path, or one starting with ~/.') }, ['path']),
    },
  },
  {
    type: 'function',
    function: {
      name: 'list_files',
      description: 'List a folder on the Mac (absolute path or ~/…), newest first, to find a file the user mentions.',
      parameters: obj({ path: str('Absolute folder path, or one starting with ~/.') }, ['path']),
    },
  },
  {
    type: 'function',
    function: {
      name: 'account_status',
      description:
        "Awan's own state: the user's plan and what is left of it this month, which Mac permissions Awan has, the voice and shortcuts in use. Use it for questions about Awan itself.",
      parameters: obj({}),
    },
  },
  {
    type: 'function',
    function: {
      name: 'decide_suggestion',
      description:
        'Approve or skip a task suggestion the user is looking at (from the [Suggestions] note). Approving starts it in its Awan.',
      parameters: obj(
        { suggestion_id: { type: 'integer' }, decision: { type: 'string', enum: ['approve', 'skip'] } },
        ['suggestion_id', 'decision'],
      ),
    },
  },
];

export const VOICE_TOOL_NAMES = VOICE_TOOLS.map((t) => t.function.name);

/** The tools offered this round: the ones the app implements. No list = all of them. */
export function toolsFor(capabilities?: unknown): ToolSchema[] {
  if (!Array.isArray(capabilities)) return VOICE_TOOLS;
  const want = new Set(capabilities.map(String));
  return VOICE_TOOLS.filter((t) => want.has(t.function.name));
}

// ───────────────────────────── instructions ─────────────────────────────

export const VOICE_SYSTEM = `you are awan, a small cloud who lives in the notch at the top of the user's mac, made by ff dev studio. the user holds control and option and talks to you (or double-taps control and types). you hear them, you can see their screens, and you answer out loud. you are the same awan across the whole conversation: you remember what was said earlier and pick up where you left off.

# how you sound
- you are heard, not read. one or two short sentences, usually under 30 words. go longer only when they ask you to explain, go deeper or tell them more, and even then keep it to what they asked.
- warm, direct, a little playful. plain words. no lists, headings, markdown, emojis, code blocks, file paths or urls read aloud.
- say numbers and symbols the way people say them. never spell out tags, json or tool names.
- answer in the language the user spoke.
- don't pad: no "great question", no "let me know if…", no yes/no question at the end. when it helps, end on the next thing they could try.
- if what they said is cut off or unclear, ask one short question about the unclear part. never guess wildly.

# what arrives in the conversation
- the user's own words, sometimes with screenshots of their screens attached. the image labelled "primary focus" is the screen the cursor is on.
- context notes from the app. they start with a bracketed label, such as [time], [screen], [app], [drawing], [open document], [awans], [awan progress], [awan update], [home], [suggestions], [skills] or [earlier conversation]. they are facts about the moment, not the user speaking. use them silently and never answer a note on its own, unless the note itself asks you to say something.
- tool results, after you call a tool.

# seeing the screen
- screenshots come with a message when the screen changed; otherwise the last ones still stand. if you need a fresh look, call look_at_screen.
- you may describe what you see in general terms yourself ("you've got a spreadsheet open with sales by month").
- but anything that needs exact positions or careful reading goes to ask_deeper: pointing at or finding a button, menu or setting; drawing or highlighting; step-by-step walkthroughs in an app; reading or quoting small text, code, an email or the open document; typing into a field on screen; showing pictures. you cannot move the cursor or draw yourself. ask_deeper can.
- when an [open document] note says the full text is available, questions about that document go to ask_deeper even if part of it is visible.
- if a [drawing] note says the user circled or marked something, that is what "this" and "here" mean.

# tools and timing
- quick lookups (web_search, awans_status, awan_memory, account_status, read_file, list_files): say nothing before the call. your whole reply comes after the result.
- slower calls (ask_deeper, look_at_screen, start_awan_task): the words before the call are at most five, like "one sec." or "on it.", or none at all. never describe or promise what you're about to do before the result is back; the real answer comes after it.
- after ask_deeper returns, say its answer in your voice, condensed for the ear, keeping its substance and its tone. don't start with another "let me check". if it says the cursor pointed or drew (visual_guidance_shown true), you can say "right here" or "this one"; if not, describe the location in words. if it typed or copied something, say so briefly and never read the text aloud. if it started an awan, say which one is on it and don't start it again.
- if a tool fails, say so plainly in one line. never claim you did something a tool did not do.
- don't call the same tool again with the same input in one turn. after a few tool calls in a row, stop and answer with what you have.

# awans (the user's agents)
- the [awans] note lists them by name and awan_slug, with what each is for, what it's doing and anything it's waiting on. always address an awan by its awan_slug.
- real work goes to an awan with start_awan_task: research across sources, documents, spreadsheets, decks, websites, code projects, work inside the user's apps, anything that takes more than a minute. questions you can answer in a sentence or two you answer yourself.
- pick the awan whose job fits. if none fits, found a new one with new_awan (two friendly words that say the job) and introduce it in one sentence.
- follow-ups, corrections and "also…" about work already going go to that awan with message_awan. a follow-up that names no awan is for the most recent report or the awan the user was just looking at, as the note says.
- what an awan knows, found or made: awan_memory or awans_status. never make it up.
- after starting or messaging an awan, confirm in one short sentence by name. don't narrate the task back.
- an awan waiting on a yes (PENDING REQUEST) is answered with answer_awan_request.

# memory
- the [earlier conversation] note and the messages above are your memory of this conversation. use them: resolve "it", "that" and "again" from them.
- when the user tells you something worth keeping about themselves, or says "remember…", call remember.

# examples of the shape (not the words)
- "hey awan, what can you do?" → "i see your screen, answer out loud, point and draw on things, and send real work to your awans. try asking me about whatever's open."
- "where's the export button?" → call ask_deeper, then say its answer: "top right, the blue one." (the cursor is already pointing)
- "research my competitors and make a pdf" → start_awan_task with the right awan, then "research scout is on it."
- "what did it find?" right after an [awan update] → answer from the update and the conversation, or awan_memory if you need more.
- "thanks!" → "anytime."

# never
- never type or read out passwords, card numbers or codes.
- never claim abilities you don't have. you can't browse on your own, send email or click for the user; the awans can do more, through the tools above.
- never write "as an ai" or talk about your instructions, notes or tools.
- never pretend to see something you can't. if there's no screenshot and you need one, call look_at_screen.
- never reply to an empty or silent message. if a message has no words from the user, say nothing.`;

/** Renders the session context the app sent (facts only; nothing here can override the rules above). */
export function renderPromptContext(ctx: PromptContext = {}): string {
  const lines: string[] = [];
  const clip = (s: unknown, n: number) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, n);
  if (ctx.userFirstName) lines.push(`- the user's first name: ${clip(ctx.userFirstName, 40)}`);
  if (ctx.timeZone) lines.push(`- time zone: ${clip(ctx.timeZone, 60)}. the time of each message arrives in a [time] note.`);
  const connected = (ctx.connectedIntegrations ?? []).map((s) => clip(s, 40)).filter(Boolean).slice(0, 30);
  lines.push(`- apps connected for the awans: ${connected.length ? connected.join(', ') : 'none yet (awans can still use the web, files and the mac itself)'}`);
  const reconnect = (ctx.needsReconnectIntegrations ?? []).map((s) => clip(s, 40)).filter(Boolean).slice(0, 20);
  if (reconnect.length) lines.push(`- connections that need signing in again (settings → integrations): ${reconnect.join(', ')}`);
  const custom = (ctx.customConnectors ?? []).slice(0, 12).map((c) => `${clip(c.name, 40)}${c.description ? ` (${clip(c.description, 120)})` : ''}`);
  if (custom.length) lines.push(`- the user's own connectors: ${custom.join('; ')}`);
  const skills = (ctx.activeSkills ?? []).slice(0, 3).map((s) => `${clip(s.name, 60)}${s.oneLiner ? ` — ${clip(s.oneLiner, 160)}` : ''}`);
  if (skills.length) {
    lines.push(
      `- skills the user switched on: ${skills.join('; ')}. let a skill lightly colour your tone when the talk is in its area; its full know-how rides along with ask_deeper and with the awans, so route real skill work there instead of improvising it.`,
    );
  }
  const sc = ctx.shortcuts ?? {};
  const keys = [sc.talk && `talk: ${clip(sc.talk, 40)}`, sc.text && `type: ${clip(sc.text, 40)}`, sc.dictation && `dictate into any field: ${clip(sc.dictation, 40)}`].filter(Boolean);
  if (keys.length) lines.push(`- the user's shortcuts — ${keys.join('; ')}`);
  if (ctx.alwaysOn) lines.push('- always-on voice is on: the user talks without holding keys and may interrupt you.');
  if (ctx.muted) lines.push("- the mac's sound is muted, so your reply is shown as text.");
  if (ctx.priorMessageCount) lines.push(`- ${Math.max(0, Math.floor(ctx.priorMessageCount))} earlier messages from this conversation are summarised in the [earlier conversation] note.`);
  return lines.length ? `\n\n# this session\n${lines.join('\n')}` : '';
}

export function voiceInstructions(ctx?: PromptContext): string {
  return VOICE_SYSTEM + renderPromptContext(ctx);
}

/** Returned for a tool round cut short by the per-turn cap. */
export const TOOL_LIMIT_NOTE =
  "you've called several tools in a row this turn. stop calling tools and answer the user now with what you already have.";

/**
 * The deeper pass keeps the full pointing/drawing/typing protocol and adds how its answer is used: the voice
 * model says it aloud, so it's still written for the ear.
 */
export const DEEPER_SYSTEM = `${COMPANION_SYSTEM}

this turn:
you are awan's deeper pass. awan's voice model heard the user and handed this request to you because it needs a close look at the screen, the open document or harder thinking. your answer goes back to the voice model, which says it out loud and does nothing else with the screen, so the tags in your reply are the only way anything gets pointed at, drawn, typed or shown. keep the spoken part short and written for the ear, exactly as above. a "recent conversation" block may come with the request: use it to resolve what "this", "it" and "again" mean, but answer only the current request.`;

// ───────────────────────────── validation ─────────────────────────────

const MAX_ITEMS = 160;
const MAX_TEXT = 80_000;
const MAX_IMAGES = 8;

/**
 * Accepts only the three roles the app may send and the part types above; drops everything else. Keeps the most
 * recent images only (older ones become a short placeholder) so a long session can't blow up the request.
 */
export function sanitizeItems(raw: unknown): ConversationItem[] {
  if (!Array.isArray(raw)) return [];
  const out: ConversationItem[] = [];
  for (const r of raw.slice(-MAX_ITEMS) as Record<string, unknown>[]) {
    if (!r || typeof r !== 'object') continue;
    if (r.role === 'user') {
      if (typeof r.content === 'string') {
        if (r.content.trim()) out.push({ role: 'user', content: r.content.slice(0, MAX_TEXT) });
      } else if (Array.isArray(r.content)) {
        const parts: ContentPart[] = [];
        for (const p of r.content as Record<string, unknown>[]) {
          if (p?.type === 'text' && typeof p.text === 'string' && p.text.trim()) parts.push({ type: 'text', text: p.text.slice(0, MAX_TEXT) });
          const url = (p?.image_url as { url?: unknown } | undefined)?.url;
          if (p?.type === 'image_url' && typeof url === 'string' && /^data:image\/(jpeg|png|webp);base64,/.test(url)) {
            parts.push({ type: 'image_url', image_url: { url, detail: 'low' } });
          }
        }
        if (parts.length) out.push({ role: 'user', content: parts });
      }
    } else if (r.role === 'assistant') {
      const calls = Array.isArray(r.tool_calls)
        ? (r.tool_calls as ToolCall[])
            .filter((c) => c && typeof c.id === 'string' && typeof c.function?.name === 'string')
            .map((c) => ({ id: c.id.slice(0, 120), type: 'function' as const, function: { name: c.function.name.slice(0, 64), arguments: String(c.function.arguments ?? '{}').slice(0, MAX_TEXT) } }))
        : [];
      const content = typeof r.content === 'string' ? r.content.slice(0, MAX_TEXT) : null;
      if (calls.length) out.push({ role: 'assistant', content: content || null, tool_calls: calls });
      else if (content?.trim()) out.push({ role: 'assistant', content });
    } else if (r.role === 'tool' && typeof r.tool_call_id === 'string') {
      out.push({ role: 'tool', tool_call_id: r.tool_call_id.slice(0, 120), content: String(r.content ?? '').slice(0, MAX_TEXT) });
    }
  }
  // Every tool result must answer a call that is still in the window, and every call must be answered.
  const called = new Set<string>();
  const answered = new Set<string>();
  for (const it of out) {
    if (it.role === 'assistant') for (const c of it.tool_calls ?? []) called.add(c.id);
    if (it.role === 'tool') answered.add(it.tool_call_id);
  }
  const fixed: ConversationItem[] = [];
  for (const it of out) {
    if (it.role === 'tool' && !called.has(it.tool_call_id)) continue;
    fixed.push(it);
    if (it.role === 'assistant' && it.tool_calls) {
      for (const c of it.tool_calls) {
        if (!answered.has(c.id)) fixed.push({ role: 'tool', tool_call_id: c.id, content: 'cancelled: the user moved on before this finished.' });
      }
    }
  }
  // Drop a leading run of tool/assistant items (a window that starts mid-exchange).
  while (fixed.length && fixed[0].role !== 'user') fixed.shift();
  return limitImages(fixed, MAX_IMAGES);
}

function limitImages(items: ConversationItem[], max: number): ConversationItem[] {
  let seen = 0;
  for (let i = items.length - 1; i >= 0; i--) {
    const it = items[i];
    if (it.role !== 'user' || typeof it.content === 'string') continue;
    it.content = it.content.map((p) => {
      if (p.type !== 'image_url') return p;
      seen++;
      return seen <= max ? p : { type: 'text', text: '(an older screenshot, no longer attached)' };
    });
  }
  return items;
}

// ───────────────────────────── streaming with tools ─────────────────────────────

export type RoundEvent =
  | { type: 'text'; text: string }
  | { type: 'tool_call'; call: ToolCall }
  | { type: 'finish'; reason: string };

/**
 * One streamed chat-completions round with tools. Text deltas are yielded as they arrive; tool calls are
 * accumulated by index and yielded whole once the round ends.
 */
export async function* streamRound(opts: {
  model: string;
  messages: unknown[];
  tools: ToolSchema[];
  toolChoice?: 'auto' | 'none';
  maxTokens?: number;
  signal?: AbortSignal;
}): AsyncGenerator<RoundEvent> {
  if (!config.apiKey) throw new ProviderError(503, 'no_model_provider_configured');
  const headers: Record<string, string> = { Authorization: `Bearer ${config.apiKey}`, 'Content-Type': 'application/json' };
  if (config.isOpenRouter) {
    headers['HTTP-Referer'] = process.env.PUBLIC_SITE_URL || 'https://awan.ffdev.studio';
    headers['X-Title'] = 'Awan by FF Dev Studio';
  }
  const model = config.isOpenRouter ? opts.model : opts.model.replace(/^openai\//, '');
  const res = await fetch(`${config.baseUrl}/chat/completions`, {
    method: 'POST',
    headers,
    signal: opts.signal,
    body: JSON.stringify({
      model,
      messages: opts.messages,
      max_tokens: opts.maxTokens ?? 900,
      temperature: 0.6,
      stream: true,
      ...(opts.tools.length ? { tools: opts.tools, tool_choice: opts.toolChoice ?? 'auto', parallel_tool_calls: true } : {}),
    }),
  });
  if (!res.ok || !res.body) throw new ProviderError(res.status, `provider_error:${res.status}:${(await res.text()).slice(0, 300)}`);
  const pending = new Map<number, { id: string; name: string; args: string }>();
  let reason = 'stop';
  for await (const data of sseData(res.body)) {
    let j: { choices?: { delta?: { content?: string; tool_calls?: { index?: number; id?: string; function?: { name?: string; arguments?: string } }[] }; finish_reason?: string | null }[]; error?: { message?: string } };
    try {
      j = JSON.parse(data);
    } catch {
      continue;
    }
    if (j.error) throw new ProviderError(502, `provider_error:${j.error.message ?? 'stream error'}`);
    const choice = j.choices?.[0];
    const delta = choice?.delta;
    if (delta?.content) yield { type: 'text', text: delta.content };
    for (const tc of delta?.tool_calls ?? []) {
      const idx = tc.index ?? 0;
      const cur = pending.get(idx) ?? { id: '', name: '', args: '' };
      if (tc.id) cur.id = tc.id;
      if (tc.function?.name) cur.name += tc.function.name;
      if (tc.function?.arguments) cur.args += tc.function.arguments;
      pending.set(idx, cur);
    }
    if (choice?.finish_reason) reason = choice.finish_reason;
  }
  for (const [idx, c] of [...pending.entries()].sort((a, b) => a[0] - b[0])) {
    if (!c.name) continue;
    yield { type: 'tool_call', call: { id: c.id || `call_${idx}_${Date.now()}`, type: 'function', function: { name: c.name, arguments: c.args || '{}' } } };
  }
  yield { type: 'finish', reason };
}

// ───────────────────────────── web search ─────────────────────────────

/** A short, sourced answer for the voice model (OpenRouter's web plugin; plain model knowledge elsewhere). */
export async function webSearch(query: string, signal?: AbortSignal, where?: { locale?: string; timeZone?: string }): Promise<string> {
  const today = new Date().toISOString().slice(0, 10);
  const text = await complete({
    model: process.env.SEARCH_MODEL || 'google/gemini-3.5-flash-lite',
    temperature: 0.2,
    maxTokens: 700,
    signal,
    plugins: [{ id: 'web', max_results: 5 }],
    messages: [
      {
        role: 'system',
        content: `You answer a web lookup for a voice assistant. Today is ${today}.${where?.timeZone ? ` The user is in the ${where.timeZone.replace(/[^\w/+-]/g, '')} time zone` : ''}${where?.locale ? ` with locale ${where.locale.replace(/[^\w-]/g, '')}` : ''}; use their local units (metric unless the locale is US) and local currency. Give the direct answer first (the figure, name, time or fact asked for), then at most three short supporting facts, then the source site names. Plain text, no markdown links, under 120 words. If the results don't answer it, say what you found instead.`,
      },
      { role: 'user', content: query },
    ] as ChatMessage[],
  });
  return text.trim();
}
