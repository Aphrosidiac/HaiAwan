/**
 * Awan-hosted MCP toolkits for Google Workspace: gmail, google-calendar, google-drive, google-docs,
 * google-sheets. Each tool is a thin, compact wrapper over one or two Google REST calls (field masks keep
 * replies small enough for an agent's context).
 */
import type { GoogleApi } from './connectors.ts';
import type { JsonSchema, McpServerSpec, McpTool } from './mcp.ts';

export type GoogleToolCtx = { g: GoogleApi; accountEmail: string | null };
type Tool = McpTool<GoogleToolCtx>;

const GMAIL = 'https://gmail.googleapis.com/gmail/v1/users/me';
const CAL = 'https://www.googleapis.com/calendar/v3';
const DRIVE = 'https://www.googleapis.com/drive/v3';
const DRIVE_UPLOAD = 'https://www.googleapis.com/upload/drive/v3';
const DOCS = 'https://docs.googleapis.com/v1/documents';
const SHEETS = 'https://sheets.googleapis.com/v4/spreadsheets';

// ───────────────────────────── schema helpers ─────────────────────────────

const str = (description: string, extra: Partial<JsonSchema> = {}): JsonSchema => ({ type: 'string', description, ...extra });
const int = (description: string, min: number, max: number, def?: number): JsonSchema => ({ type: 'integer', description, minimum: min, maximum: max, ...(def !== undefined ? { default: def } : {}) });
const bool = (description: string, def?: boolean): JsonSchema => ({ type: 'boolean', description, ...(def !== undefined ? { default: def } : {}) });
const strList = (description: string, extra: Partial<JsonSchema> = {}): JsonSchema => ({ type: 'array', items: { type: 'string' }, description, ...extra });
const grid = (description: string): JsonSchema => ({ type: 'array', description, minItems: 1, items: { type: 'array', items: { description: 'One cell: text, number or boolean. Formulas start with =.' } } });
const obj = (properties: Record<string, JsonSchema>, required: string[] = []): JsonSchema => ({ type: 'object', properties, required, additionalProperties: false });

// ───────────────────────────── small utilities ─────────────────────────────

const b64url = (s: string | Buffer) => (Buffer.isBuffer(s) ? s : Buffer.from(s, 'utf8')).toString('base64url');
const fromB64url = (s: string) => Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
const enc = encodeURIComponent;

function clip(s: string, max: number): { text: string; truncated: boolean; totalChars: number } {
  return s.length > max ? { text: s.slice(0, max), truncated: true, totalChars: s.length } : { text: s, truncated: false, totalChars: s.length };
}

export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|tr|h[1-6]|blockquote)>/gi, '\n')
    .replace(/<li[^>]*>/gi, '- ')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i]);
      }
    }),
  );
  return out;
}

const asList = (v: unknown): string[] => (Array.isArray(v) ? v.map(String) : typeof v === 'string' && v.trim() ? v.split(',') : []).map((s) => s.trim()).filter(Boolean);

// ───────────────────────────── MIME ─────────────────────────────

/** Header values: no CR/LF (header injection), RFC 2047 for non-ASCII. */
export function mimeHeader(value: string): string {
  const clean = value.replace(/[\r\n]+/g, ' ').trim();
  return /^[\x20-\x7e]*$/.test(clean) ? clean : `=?UTF-8?B?${Buffer.from(clean, 'utf8').toString('base64')}?=`;
}

function wrap76(b64: string) {
  return b64.replace(/.{1,76}/g, '$&\r\n').trimEnd();
}

export type MimeInput = { from?: string | null; to: string[]; cc?: string[]; bcc?: string[]; subject: string; text?: string; html?: string; inReplyTo?: string; references?: string };

export function buildMime(m: MimeInput): string {
  const addr = (list: string[]) => list.map((a) => a.replace(/[\r\n]+/g, ' ').trim()).join(', ');
  const lines: string[] = [];
  if (m.from) lines.push(`From: ${addr([m.from])}`);
  if (m.to.length) lines.push(`To: ${addr(m.to)}`);
  if (m.cc?.length) lines.push(`Cc: ${addr(m.cc)}`);
  if (m.bcc?.length) lines.push(`Bcc: ${addr(m.bcc)}`);
  lines.push(`Subject: ${mimeHeader(m.subject)}`);
  if (m.inReplyTo) lines.push(`In-Reply-To: ${mimeHeader(m.inReplyTo)}`);
  if (m.references) lines.push(`References: ${mimeHeader(m.references)}`);
  lines.push('MIME-Version: 1.0');
  const part = (type: string, body: string) => [`Content-Type: ${type}; charset="UTF-8"`, 'Content-Transfer-Encoding: base64', '', wrap76(Buffer.from(body, 'utf8').toString('base64'))].join('\r\n');
  const text = m.text ?? (m.html ? htmlToText(m.html) : '');
  if (m.html) {
    const boundary = `awan_${Math.random().toString(36).slice(2)}${Date.now().toString(36)}`;
    lines.push(`Content-Type: multipart/alternative; boundary="${boundary}"`, '', `--${boundary}`, part('text/plain', text), `--${boundary}`, part('text/html', m.html), `--${boundary}--`);
  } else {
    lines.push(part('text/plain', text));
  }
  return lines.join('\r\n');
}

// ───────────────────────────── Gmail ─────────────────────────────

type GmailPart = { mimeType?: string; filename?: string; headers?: { name: string; value: string }[]; body?: { size?: number; data?: string; attachmentId?: string }; parts?: GmailPart[] };

const header = (headers: { name: string; value: string }[] | undefined, name: string) => headers?.find((h) => h.name.toLowerCase() === name.toLowerCase())?.value ?? '';

export function extractGmailBody(payload: GmailPart): { text: string; attachments: { filename: string; mimeType: string; size: number; attachmentId: string }[] } {
  let plain = '';
  let html = '';
  const attachments: { filename: string; mimeType: string; size: number; attachmentId: string }[] = [];
  const walk = (p: GmailPart) => {
    if (p.filename && p.body?.attachmentId) {
      attachments.push({ filename: p.filename, mimeType: p.mimeType ?? 'application/octet-stream', size: p.body.size ?? 0, attachmentId: p.body.attachmentId });
      return;
    }
    if (p.body?.data) {
      if (p.mimeType === 'text/plain' && !plain) plain = fromB64url(p.body.data);
      else if (p.mimeType === 'text/html' && !html) html = fromB64url(p.body.data);
    }
    for (const c of p.parts ?? []) walk(c);
  };
  walk(payload);
  return { text: plain || (html ? htmlToText(html) : ''), attachments };
}

async function resolveLabelIds(g: GoogleApi, names: string[]): Promise<string[]> {
  if (!names.length) return [];
  const { labels = [] } = (await g({ url: `${GMAIL}/labels`, query: { fields: 'labels(id,name)' } })) as { labels?: { id: string; name: string }[] };
  return names.map((n) => {
    const hit = labels.find((l) => l.id === n || l.name.toLowerCase() === n.toLowerCase());
    if (!hit) throw new Error(`No Gmail label named "${n}". Call list_labels to see the exact names.`);
    return hit.id;
  });
}

const gmailTools: Tool[] = [
  {
    name: 'search_messages',
    title: 'Search messages',
    description:
      'Search the user\'s Gmail with Gmail search syntax (e.g. "from:ana is:unread newer_than:7d", "subject:invoice has:attachment"). Returns compact summaries (id, threadId, from, to, subject, date, snippet, labels) newest first. Use get_message for the full body.',
    inputSchema: obj(
      {
        query: str('Gmail search query, exactly as typed in the Gmail search box. Empty string lists the newest mail.'),
        max_results: int('How many messages to return (1–50).', 1, 50, 10),
        page_token: str('nextPageToken from a previous call, to get the next page.'),
        include_spam_trash: bool('Also search Spam and Trash.', false),
      },
      ['query'],
    ),
    annotations: { readOnlyHint: true },
    async run(a, { g }) {
      const list = (await g({
        url: `${GMAIL}/messages`,
        query: { q: a.query, maxResults: a.max_results, pageToken: a.page_token, includeSpamTrash: a.include_spam_trash || undefined },
      })) as { messages?: { id: string }[]; nextPageToken?: string; resultSizeEstimate?: number };
      const messages = await mapLimit(list.messages ?? [], 8, async ({ id }) => {
        const m = (await g({
          url: `${GMAIL}/messages/${enc(id)}`,
          query: { format: 'metadata', metadataHeaders: ['From', 'To', 'Subject', 'Date'], fields: 'id,threadId,labelIds,snippet,payload/headers' },
        })) as { id: string; threadId: string; labelIds?: string[]; snippet?: string; payload?: GmailPart };
        const h = m.payload?.headers;
        return { id: m.id, threadId: m.threadId, from: header(h, 'From'), to: header(h, 'To'), subject: header(h, 'Subject'), date: header(h, 'Date'), snippet: m.snippet ?? '', labels: m.labelIds ?? [] };
      });
      return { messages, nextPageToken: list.nextPageToken ?? null, resultSizeEstimate: list.resultSizeEstimate ?? messages.length };
    },
  },
  {
    name: 'get_message',
    title: 'Read a message',
    description:
      'Read one Gmail message: headers (from, to, cc, subject, date, Message-ID), the plain-text body (HTML is converted to text) and the list of attachments (filename, mimeType, size, attachmentId).',
    inputSchema: obj({ message_id: str('The message id from search_messages.'), max_chars: int('Cut the body at this many characters.', 500, 100_000, 20_000) }, ['message_id']),
    annotations: { readOnlyHint: true },
    async run(a, { g }) {
      const m = (await g({ url: `${GMAIL}/messages/${enc(a.message_id)}`, query: { format: 'full' } })) as {
        id: string;
        threadId: string;
        labelIds?: string[];
        payload: GmailPart;
      };
      const h = m.payload?.headers;
      const { text, attachments } = extractGmailBody(m.payload ?? {});
      const body = clip(text, a.max_chars);
      return {
        id: m.id,
        threadId: m.threadId,
        labels: m.labelIds ?? [],
        from: header(h, 'From'),
        to: header(h, 'To'),
        cc: header(h, 'Cc'),
        replyTo: header(h, 'Reply-To'),
        subject: header(h, 'Subject'),
        date: header(h, 'Date'),
        messageIdHeader: header(h, 'Message-ID'),
        body: body.text,
        bodyTruncated: body.truncated,
        attachments,
      };
    },
  },
  {
    name: 'list_labels',
    title: 'List labels',
    description: 'List the Gmail labels (system and user) with their ids, names and type. Use the names or ids with modify_labels.',
    inputSchema: obj({}),
    annotations: { readOnlyHint: true },
    async run(_a, { g }) {
      const r = (await g({ url: `${GMAIL}/labels`, query: { fields: 'labels(id,name,type)' } })) as { labels?: { id: string; name: string; type: string }[] };
      return { labels: r.labels ?? [] };
    },
  },
  {
    name: 'modify_labels',
    title: 'Change labels',
    description:
      'Add or remove labels on up to 100 messages at once (label names or ids). Archive = remove "INBOX"; mark read = remove "UNREAD"; star = add "STARRED". Reversible triage the user asked for needs no extra confirmation.',
    inputSchema: obj(
      {
        message_ids: strList('Message ids to change.', { minItems: 1, maxItems: 100 }),
        add_labels: strList('Label names or ids to add.'),
        remove_labels: strList('Label names or ids to remove.'),
      },
      ['message_ids'],
    ),
    annotations: { idempotentHint: true },
    async run(a, { g }) {
      const add = await resolveLabelIds(g, asList(a.add_labels));
      const remove = await resolveLabelIds(g, asList(a.remove_labels));
      if (!add.length && !remove.length) throw new Error('Give add_labels or remove_labels.');
      await g({ method: 'POST', url: `${GMAIL}/messages/batchModify`, json: { ids: a.message_ids, addLabelIds: add, removeLabelIds: remove } });
      return { modified: a.message_ids.length, added: add, removed: remove };
    },
  },
  {
    name: 'create_draft',
    title: 'Create a draft',
    description:
      'Create a new Gmail draft (not sent). Returns the draftId. Show the user the recipients, subject and body; send it with send_draft only after they explicitly approve.',
    inputSchema: obj(
      {
        to: strList('Recipient addresses, e.g. ["Ana <ana@example.com>"].', { minItems: 1 }),
        cc: strList('Cc addresses.'),
        bcc: strList('Bcc addresses.'),
        subject: str('Subject line.'),
        body: str('Plain-text body.'),
        html_body: str('Optional HTML body; the plain body is kept as the text alternative.'),
      },
      ['to', 'subject', 'body'],
    ),
    async run(a, { g, accountEmail }) {
      const raw = buildMime({ from: accountEmail, to: a.to, cc: a.cc, bcc: a.bcc, subject: a.subject, text: a.body, html: a.html_body });
      const d = (await g({ method: 'POST', url: `${GMAIL}/drafts`, json: { message: { raw: b64url(raw) } } })) as { id: string; message?: { id: string; threadId: string } };
      return { draftId: d.id, messageId: d.message?.id ?? null, threadId: d.message?.threadId ?? null, to: a.to, subject: a.subject };
    },
  },
  {
    name: 'send_draft',
    title: 'Send a draft',
    description:
      'Send an existing Gmail draft. ONLY call this after the user has explicitly approved sending this exact draft (recipients, subject and body shown to them). Never send on your own initiative.',
    inputSchema: obj({ draft_id: str('The draftId from create_draft or reply_draft.') }, ['draft_id']),
    annotations: { destructiveHint: true, openWorldHint: true },
    async run(a, { g }) {
      const r = (await g({ method: 'POST', url: `${GMAIL}/drafts/send`, json: { id: a.draft_id } })) as { id: string; threadId: string; labelIds?: string[] };
      return { sent: true, messageId: r.id, threadId: r.threadId, labels: r.labelIds ?? [] };
    },
  },
  {
    name: 'reply_draft',
    title: 'Draft a reply',
    description:
      'Draft a reply to a message in its thread (subject "Re: …", In-Reply-To/References set). reply_all also copies the other recipients (never the user themself). Returns the draftId; send it with send_draft only after explicit approval.',
    inputSchema: obj(
      {
        message_id: str('The message being answered.'),
        body: str('Plain-text reply body (without the quoted original).'),
        html_body: str('Optional HTML reply body.'),
        reply_all: bool('Reply to everyone on the message instead of only the sender.', false),
      },
      ['message_id', 'body'],
    ),
    async run(a, { g, accountEmail }) {
      const m = (await g({
        url: `${GMAIL}/messages/${enc(a.message_id)}`,
        query: { format: 'metadata', metadataHeaders: ['From', 'To', 'Cc', 'Reply-To', 'Subject', 'Message-ID', 'References'], fields: 'id,threadId,payload/headers' },
      })) as { threadId: string; payload?: GmailPart };
      const h = m.payload?.headers;
      const me = (accountEmail ?? '').toLowerCase();
      const split = (s: string) => s.split(',').map((x) => x.trim()).filter(Boolean);
      const bare = (s: string) => (/<([^>]+)>/.exec(s)?.[1] ?? s).trim().toLowerCase();
      const sender = header(h, 'Reply-To') || header(h, 'From');
      const fromMe = bare(header(h, 'From')) === me;
      let to = fromMe ? split(header(h, 'To')) : split(sender);
      let cc: string[] = [];
      if (a.reply_all) {
        const others = [...split(header(h, 'To')), ...split(header(h, 'Cc'))].filter((x) => bare(x) !== me);
        cc = others.filter((x) => !to.some((t) => bare(t) === bare(x)));
      }
      to = to.filter((x) => bare(x) !== me || fromMe);
      if (!to.length) throw new Error('Could not work out who to reply to from that message.');
      const subject = header(h, 'Subject');
      const msgId = header(h, 'Message-ID');
      const refs = [header(h, 'References'), msgId].filter(Boolean).join(' ');
      const raw = buildMime({
        from: accountEmail,
        to,
        cc,
        subject: /^re:/i.test(subject) ? subject : `Re: ${subject}`,
        text: a.body,
        html: a.html_body,
        inReplyTo: msgId || undefined,
        references: refs || undefined,
      });
      const d = (await g({ method: 'POST', url: `${GMAIL}/drafts`, json: { message: { raw: b64url(raw), threadId: m.threadId } } })) as { id: string; message?: { id: string; threadId: string } };
      return { draftId: d.id, messageId: d.message?.id ?? null, threadId: d.message?.threadId ?? m.threadId, to, cc, subject: /^re:/i.test(subject) ? subject : `Re: ${subject}` };
    },
  },
];

// ───────────────────────────── Calendar ─────────────────────────────

const EVENT_FIELDS = 'id,status,summary,description,location,start,end,attendees(email,responseStatus,optional),organizer(email),hangoutLink,htmlLink,recurringEventId';

type CalEvent = { id: string; status?: string; summary?: string; description?: string; location?: string; start?: { date?: string; dateTime?: string; timeZone?: string }; end?: { date?: string; dateTime?: string; timeZone?: string }; attendees?: { email: string; responseStatus?: string; optional?: boolean }[]; organizer?: { email?: string }; hangoutLink?: string; htmlLink?: string; recurringEventId?: string };

function compactEvent(e: CalEvent) {
  return {
    id: e.id,
    summary: e.summary ?? '(no title)',
    start: e.start?.dateTime ?? e.start?.date ?? null,
    end: e.end?.dateTime ?? e.end?.date ?? null,
    allDay: Boolean(e.start?.date),
    timeZone: e.start?.timeZone ?? null,
    location: e.location ?? null,
    description: e.description ? clip(e.description, 500).text : null,
    attendees: (e.attendees ?? []).map((x) => ({ email: x.email, response: x.responseStatus ?? null })),
    organizer: e.organizer?.email ?? null,
    meetLink: e.hangoutLink ?? null,
    link: e.htmlLink ?? null,
    status: e.status ?? null,
    recurring: Boolean(e.recurringEventId),
  };
}

function eventTimes(a: Record<string, any>) {
  const out: Record<string, unknown> = {};
  const one = (v: string | undefined) => {
    if (!v) return undefined;
    if (a.all_day || /^\d{4}-\d{2}-\d{2}$/.test(v)) return { date: v.slice(0, 10) };
    return { dateTime: v, ...(a.time_zone ? { timeZone: a.time_zone } : {}) };
  };
  if (a.start) out.start = one(a.start);
  if (a.end) out.end = one(a.end);
  return out;
}

/** Offset (ms) of `tz` from UTC at `at`. */
export function tzOffsetMs(tz: string, at: Date): number {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' })
      .formatToParts(at)
      .map((p) => [p.type, p.value]),
  );
  const asUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
  return asUtc - Math.floor(at.getTime() / 1000) * 1000;
}

/** Wall-clock time in `tz` → UTC ms. */
export function zonedToUtc(y: number, m: number, d: number, hh: number, mm: number, tz: string): number {
  const guess = Date.UTC(y, m - 1, d, hh, mm);
  let t = guess - tzOffsetMs(tz, new Date(guess));
  const second = tzOffsetMs(tz, new Date(t));
  if (guess - second !== t) t = guess - second;
  return t;
}

function localDate(tz: string, at: number) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short' }).formatToParts(new Date(at)).map((p) => [p.type, p.value]));
  return { y: +parts.year, m: +parts.month, d: +parts.day, weekday: parts.weekday as string };
}

function fmtLocal(tz: string, at: number) {
  return new Intl.DateTimeFormat('en-GB', { timeZone: tz, weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(at));
}

/** Free gaps of at least `durationMs` inside [min,max], optionally clipped to daily working hours in `tz`. */
export function freeSlots(
  busy: { start: number; end: number }[],
  min: number,
  max: number,
  durationMs: number,
  opts: { tz?: string; workStart?: string; workEnd?: string; weekends?: boolean } = {},
): { start: number; end: number }[] {
  let windows: { start: number; end: number }[] = [{ start: min, end: max }];
  if (opts.tz && opts.workStart && opts.workEnd) {
    const [sh, sm] = opts.workStart.split(':').map(Number);
    const [eh, em] = opts.workEnd.split(':').map(Number);
    windows = [];
    let cursor = min;
    for (let i = 0; i < 400 && cursor < max; i++) {
      const day = localDate(opts.tz, cursor);
      const ws = zonedToUtc(day.y, day.m, day.d, sh, sm, opts.tz);
      const we = zonedToUtc(day.y, day.m, day.d, eh, em, opts.tz);
      const weekend = day.weekday === 'Sat' || day.weekday === 'Sun';
      if (!weekend || opts.weekends) {
        const s = Math.max(ws, min);
        const e = Math.min(we, max);
        if (e > s) windows.push({ start: s, end: e });
      }
      cursor = zonedToUtc(day.y, day.m, day.d, 0, 0, opts.tz) + 36 * 3600_000; // into the next local day
      const next = localDate(opts.tz, cursor);
      cursor = zonedToUtc(next.y, next.m, next.d, 0, 0, opts.tz);
    }
  }
  const merged = [...busy].sort((a, b) => a.start - b.start).reduce<{ start: number; end: number }[]>((acc, b) => {
    const last = acc[acc.length - 1];
    if (last && b.start <= last.end) last.end = Math.max(last.end, b.end);
    else acc.push({ ...b });
    return acc;
  }, []);
  const out: { start: number; end: number }[] = [];
  for (const w of windows) {
    let cursor = w.start;
    for (const b of merged) {
      if (b.end <= cursor || b.start >= w.end) continue;
      if (b.start - cursor >= durationMs) out.push({ start: cursor, end: b.start });
      cursor = Math.max(cursor, b.end);
    }
    if (w.end - cursor >= durationMs) out.push({ start: cursor, end: w.end });
  }
  return out;
}

const calendarTools: Tool[] = [
  {
    name: 'list_calendars',
    title: 'List calendars',
    description: "List the user's calendars (id, name, whether it is primary, time zone, access role). Use the id with the other calendar tools; 'primary' always means the user's main calendar.",
    inputSchema: obj({}),
    annotations: { readOnlyHint: true },
    async run(_a, { g }) {
      const r = (await g({ url: `${CAL}/users/me/calendarList`, query: { fields: 'items(id,summary,primary,timeZone,accessRole)' } })) as { items?: { id: string; summary: string; primary?: boolean; timeZone?: string; accessRole?: string }[] };
      return { calendars: (r.items ?? []).map((c) => ({ id: c.id, name: c.summary, primary: Boolean(c.primary), timeZone: c.timeZone ?? null, accessRole: c.accessRole ?? null })) };
    },
  },
  {
    name: 'list_events',
    title: 'List events',
    description: 'List events on a calendar between two times (recurring events expanded, ordered by start). Times are RFC 3339 with an offset, e.g. "2026-10-01T09:00:00+08:00".',
    inputSchema: obj(
      {
        calendar_id: str("Calendar id; 'primary' for the user's main calendar.", { default: 'primary' }),
        time_min: str('Start of the window (RFC 3339). Defaults to now.'),
        time_max: str('End of the window (RFC 3339).'),
        query: str('Free-text filter on title, description, location and attendees.'),
        max_results: int('How many events (1–100).', 1, 100, 25),
        page_token: str('nextPageToken from a previous call.'),
      },
      [],
    ),
    annotations: { readOnlyHint: true },
    async run(a, { g }) {
      const r = (await g({
        url: `${CAL}/calendars/${enc(a.calendar_id)}/events`,
        query: {
          singleEvents: true,
          orderBy: 'startTime',
          timeMin: a.time_min ?? new Date().toISOString(),
          timeMax: a.time_max,
          q: a.query,
          maxResults: a.max_results,
          pageToken: a.page_token,
          fields: `items(${EVENT_FIELDS}),nextPageToken,timeZone`,
        },
      })) as { items?: CalEvent[]; nextPageToken?: string; timeZone?: string };
      return { timeZone: r.timeZone ?? null, events: (r.items ?? []).map(compactEvent), nextPageToken: r.nextPageToken ?? null };
    },
  },
  {
    name: 'find_free_time',
    title: 'Find free time',
    description:
      'Find open slots of at least duration_minutes across one or more calendars between time_min and time_max. Give working_hours (e.g. {"start":"09:00","end":"18:00"}) to keep slots inside the working day in time_zone (defaults to the user\'s calendar time zone); weekends are skipped unless include_weekends is true.',
    inputSchema: obj(
      {
        time_min: str('Start of the search window (RFC 3339).'),
        time_max: str('End of the search window (RFC 3339).'),
        duration_minutes: int('Minimum slot length in minutes.', 5, 1440, 30),
        calendar_ids: strList("Calendars whose busy times count. Defaults to ['primary'].", { maxItems: 20 }),
        time_zone: str('IANA time zone for working hours and the readable times, e.g. "Asia/Kuala_Lumpur".'),
        working_hours: { ...obj({ start: str('Day start, HH:MM (24-hour).'), end: str('Day end, HH:MM (24-hour).') }, ['start', 'end']), description: 'Keep slots inside this daily window, e.g. {"start":"09:00","end":"18:00"}.' },
        include_weekends: bool('Allow slots on Saturday and Sunday when working_hours is set.', false),
        max_slots: int('Return at most this many slots.', 1, 50, 10),
      },
      ['time_min', 'time_max'],
    ),
    annotations: { readOnlyHint: true },
    async run(a, { g }) {
      const min = Date.parse(a.time_min);
      const max = Date.parse(a.time_max);
      if (!Number.isFinite(min) || !Number.isFinite(max) || max <= min) throw new Error('time_min and time_max must be RFC 3339 times with time_max after time_min.');
      const ids = asList(a.calendar_ids).length ? asList(a.calendar_ids) : ['primary'];
      let tz: string | undefined = a.time_zone;
      if (!tz) {
        const s = (await g({ url: `${CAL}/users/me/settings/timezone` }).catch(() => ({}))) as { value?: string };
        tz = s.value;
      }
      const hhmm = /^([01]?\d|2[0-4]):[0-5]\d$/;
      if (a.working_hours && (!hhmm.test(a.working_hours.start) || !hhmm.test(a.working_hours.end))) throw new Error('working_hours.start and .end must be HH:MM (24-hour).');
      const fb = (await g({ method: 'POST', url: `${CAL}/freeBusy`, json: { timeMin: new Date(min).toISOString(), timeMax: new Date(max).toISOString(), items: ids.map((id) => ({ id })) } })) as {
        calendars?: Record<string, { busy?: { start: string; end: string }[]; errors?: { reason: string }[] }>;
      };
      const busy = Object.values(fb.calendars ?? {}).flatMap((c) => (c.busy ?? []).map((b) => ({ start: Date.parse(b.start), end: Date.parse(b.end) })));
      const errors = Object.entries(fb.calendars ?? {}).filter(([, c]) => c.errors?.length).map(([id, c]) => `${id}: ${c.errors!.map((e) => e.reason).join(', ')}`);
      const slots = freeSlots(busy, min, max, a.duration_minutes * 60_000, {
        tz,
        workStart: a.working_hours?.start,
        workEnd: a.working_hours?.end,
        weekends: a.include_weekends,
      }).slice(0, a.max_slots);
      return {
        timeZone: tz ?? null,
        slots: slots.map((s) => ({
          start: new Date(s.start).toISOString(),
          end: new Date(s.end).toISOString(),
          minutes: Math.round((s.end - s.start) / 60_000),
          ...(tz ? { local: `${fmtLocal(tz, s.start)} – ${fmtLocal(tz, s.end)}` } : {}),
        })),
        busyBlocks: busy.length,
        ...(errors.length ? { calendarErrors: errors } : {}),
      };
    },
  },
  {
    name: 'create_event',
    title: 'Create an event',
    description:
      'Create a calendar event. start/end are RFC 3339 date-times (or YYYY-MM-DD with all_day). Attendees get Google invitations only when send_updates is "all" — the user asking to invite people is the approval for that. Read the result back and tell the user the time in their time zone.',
    inputSchema: obj(
      {
        calendar_id: str("Calendar id; 'primary' by default.", { default: 'primary' }),
        summary: str('Event title.'),
        start: str('Start, RFC 3339 (e.g. 2026-10-02T15:00:00+08:00) or YYYY-MM-DD for all-day.'),
        end: str('End, same format as start. For all-day events the end date is exclusive.'),
        time_zone: str('IANA time zone for the event, e.g. "Asia/Kuala_Lumpur".'),
        all_day: bool('All-day event (start/end are dates).', false),
        description: str('Notes / agenda.'),
        location: str('Place or address.'),
        attendees: strList('Attendee email addresses.'),
        add_meet: bool('Attach a Google Meet link.', false),
        send_updates: str('Who gets invitation emails.', { enum: ['none', 'all', 'externalOnly'], default: 'none' }),
      },
      ['summary', 'start', 'end'],
    ),
    async run(a, { g }) {
      const body: Record<string, unknown> = { summary: a.summary, description: a.description, location: a.location, ...eventTimes(a) };
      if (asList(a.attendees).length) body.attendees = asList(a.attendees).map((email) => ({ email }));
      if (a.add_meet) body.conferenceData = { createRequest: { requestId: `awan-${Date.now().toString(36)}`, conferenceSolutionKey: { type: 'hangoutsMeet' } } };
      const e = (await g({
        method: 'POST',
        url: `${CAL}/calendars/${enc(a.calendar_id)}/events`,
        query: { sendUpdates: a.send_updates, conferenceDataVersion: a.add_meet ? 1 : undefined, fields: EVENT_FIELDS },
        json: body,
      })) as CalEvent;
      return { created: true, event: compactEvent(e) };
    },
  },
  {
    name: 'update_event',
    title: 'Update an event',
    description: 'Change fields of an existing event (only the fields you pass change). Moving an event = new start and end. Adding attendees replaces the attendee list with the one given.',
    inputSchema: obj(
      {
        calendar_id: str("Calendar id; 'primary' by default.", { default: 'primary' }),
        event_id: str('The event id from list_events.'),
        summary: str('New title.'),
        start: str('New start (RFC 3339, or YYYY-MM-DD with all_day).'),
        end: str('New end.'),
        time_zone: str('IANA time zone for start/end.'),
        all_day: bool('Treat start/end as dates.'),
        description: str('New notes.'),
        location: str('New location.'),
        attendees: strList('Full attendee list (replaces the current one).'),
        send_updates: str('Who gets update emails.', { enum: ['none', 'all', 'externalOnly'], default: 'none' }),
      },
      ['event_id'],
    ),
    async run(a, { g }) {
      const body: Record<string, unknown> = { ...eventTimes(a) };
      for (const k of ['summary', 'description', 'location'] as const) if (a[k] !== undefined) body[k] = a[k];
      if (a.attendees !== undefined) body.attendees = asList(a.attendees).map((email) => ({ email }));
      if (!Object.keys(body).length) throw new Error('Nothing to change — pass at least one field.');
      const e = (await g({ method: 'PATCH', url: `${CAL}/calendars/${enc(a.calendar_id)}/events/${enc(a.event_id)}`, query: { sendUpdates: a.send_updates, fields: EVENT_FIELDS }, json: body })) as CalEvent;
      return { updated: true, event: compactEvent(e) };
    },
  },
  {
    name: 'delete_event',
    title: 'Delete an event',
    description: 'Delete (cancel) a calendar event. Confirm with the user first unless they explicitly asked for this deletion.',
    inputSchema: obj(
      {
        calendar_id: str("Calendar id; 'primary' by default.", { default: 'primary' }),
        event_id: str('The event id.'),
        send_updates: str('Who gets cancellation emails.', { enum: ['none', 'all', 'externalOnly'], default: 'none' }),
      },
      ['event_id'],
    ),
    annotations: { destructiveHint: true },
    async run(a, { g }) {
      await g({ method: 'DELETE', url: `${CAL}/calendars/${enc(a.calendar_id)}/events/${enc(a.event_id)}`, query: { sendUpdates: a.send_updates } });
      return { deleted: true, eventId: a.event_id };
    },
  },
];

// ───────────────────────────── Drive ─────────────────────────────

const FILE_FIELDS = 'id,name,mimeType,size,modifiedTime,webViewLink,parents';
const driveQ = (s: string) => s.replace(/\\/g, '\\\\').replace(/'/g, "\\'");

const GOOGLE_EXPORTS: Record<string, { mime: string; note?: string }> = {
  'application/vnd.google-apps.document': { mime: 'text/plain' },
  'application/vnd.google-apps.spreadsheet': { mime: 'text/csv', note: 'CSV export contains only the first sheet; use the Sheets get_values tool for other tabs.' },
  'application/vnd.google-apps.presentation': { mime: 'text/plain' },
  'application/vnd.google-apps.script': { mime: 'application/vnd.google-apps.script+json' },
};
const isTextMime = (m: string) => m.startsWith('text/') || /^(application\/(json|xml|javascript|x-yaml|yaml|csv|x-ndjson|sql))/.test(m);

const CONVERT: Record<string, string> = {
  'text/csv': 'application/vnd.google-apps.spreadsheet',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'application/vnd.google-apps.spreadsheet',
  'text/plain': 'application/vnd.google-apps.document',
  'text/html': 'application/vnd.google-apps.document',
  'text/markdown': 'application/vnd.google-apps.document',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'application/vnd.google-apps.document',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'application/vnd.google-apps.presentation',
};

export const UPLOAD_MAX_BYTES = 20 * 1024 * 1024;

const driveTools: Tool[] = [
  {
    name: 'search_files',
    title: 'Search files',
    description:
      'Search Google Drive. `query` matches file names and contents; or pass raw_query in Drive query syntax (e.g. "mimeType=\'application/pdf\' and modifiedTime > \'2026-09-01\'"). Trashed files are excluded. Returns id, name, mimeType, size, modifiedTime, webViewLink, parents.',
    inputSchema: obj({
      query: str('Words to find in names or contents.'),
      raw_query: str('A Drive `q` expression; combined with query and the filters using "and".'),
      mime_type: str('Only this MIME type, e.g. application/vnd.google-apps.spreadsheet.'),
      folder_id: str('Only files directly inside this folder.'),
      max_results: int('How many files (1–100).', 1, 100, 20),
      page_token: str('nextPageToken from a previous call.'),
    }),
    annotations: { readOnlyHint: true },
    async run(a, { g }) {
      const clauses = ['trashed = false'];
      if (a.query) clauses.push(`(name contains '${driveQ(a.query)}' or fullText contains '${driveQ(a.query)}')`);
      if (a.mime_type) clauses.push(`mimeType = '${driveQ(a.mime_type)}'`);
      if (a.folder_id) clauses.push(`'${driveQ(a.folder_id)}' in parents`);
      if (a.raw_query) clauses.push(`(${a.raw_query})`);
      const r = (await g({
        url: `${DRIVE}/files`,
        query: { q: clauses.join(' and '), pageSize: a.max_results, pageToken: a.page_token, orderBy: a.query ? undefined : 'modifiedTime desc', supportsAllDrives: true, includeItemsFromAllDrives: true, fields: `files(${FILE_FIELDS}),nextPageToken` },
      })) as { files?: unknown[]; nextPageToken?: string };
      return { files: r.files ?? [], nextPageToken: r.nextPageToken ?? null };
    },
  },
  {
    name: 'get_file_metadata',
    title: 'File details',
    description: 'Details of one Drive file or folder: name, type, size, dates, parents, link, owners and who it is shared with.',
    inputSchema: obj({ file_id: str('The file id.') }, ['file_id']),
    annotations: { readOnlyHint: true },
    async run(a, { g }) {
      return g({
        url: `${DRIVE}/files/${enc(a.file_id)}`,
        query: { supportsAllDrives: true, fields: `${FILE_FIELDS},createdTime,description,owners(displayName,emailAddress),shared,permissions(id,type,role,emailAddress,domain)` },
      });
    },
  },
  {
    name: 'download_text',
    title: 'Read a file as text',
    description:
      'Read a Drive file as text: Google Docs and Slides export as plain text, Google Sheets as CSV (first sheet), and text-like files (txt, md, csv, json, xml, html…) are downloaded as-is. Binary files (PDF, images) are refused with their link.',
    inputSchema: obj({ file_id: str('The file id.'), max_chars: int('Cut the text at this many characters.', 500, 200_000, 50_000) }, ['file_id']),
    annotations: { readOnlyHint: true },
    async run(a, { g }) {
      const meta = (await g({ url: `${DRIVE}/files/${enc(a.file_id)}`, query: { supportsAllDrives: true, fields: 'id,name,mimeType,webViewLink' } })) as { id: string; name: string; mimeType: string; webViewLink?: string };
      let text: string;
      let note: string | undefined;
      const exp = GOOGLE_EXPORTS[meta.mimeType];
      if (exp) {
        text = (await g({ url: `${DRIVE}/files/${enc(a.file_id)}/export`, query: { mimeType: exp.mime }, text: true })) as string;
        note = exp.note;
      } else if (isTextMime(meta.mimeType)) {
        text = (await g({ url: `${DRIVE}/files/${enc(a.file_id)}`, query: { alt: 'media', supportsAllDrives: true }, text: true })) as string;
      } else {
        throw new Error(`${meta.name} is ${meta.mimeType}, not a text file. Open it via ${meta.webViewLink ?? 'Drive'} or ask the user to share its text.`);
      }
      const c = clip(text, a.max_chars);
      return { id: meta.id, name: meta.name, mimeType: meta.mimeType, text: c.text, truncated: c.truncated, totalChars: c.totalChars, ...(note ? { note } : {}) };
    },
  },
  {
    name: 'upload_file',
    title: 'Upload a file',
    description:
      'Upload a file to Drive from base64 content (max 20 MB). Set convert_to_google to turn CSV/XLSX into a Google Sheet or TXT/HTML/MD/DOCX into a Google Doc. Returns the new file id and link.',
    inputSchema: obj(
      {
        name: str('File name including extension.'),
        content_base64: str('The file bytes, base64-encoded.'),
        mime_type: str('MIME type of the content, e.g. application/pdf or text/csv.'),
        folder_id: str('Put it in this folder (default: My Drive root).'),
        convert_to_google: bool('Convert to the matching Google Docs/Sheets/Slides format.', false),
      },
      ['name', 'content_base64', 'mime_type'],
    ),
    async run(a, { g }) {
      const bytes = Buffer.from(a.content_base64, 'base64');
      if (!bytes.length) throw new Error('content_base64 decoded to nothing.');
      if (bytes.length > UPLOAD_MAX_BYTES) throw new Error(`File is ${bytes.length} bytes; the limit is ${UPLOAD_MAX_BYTES}.`);
      const metadata: Record<string, unknown> = { name: a.name };
      if (a.folder_id) metadata.parents = [a.folder_id];
      if (a.convert_to_google) {
        const target = CONVERT[a.mime_type];
        if (!target) throw new Error(`Can't convert ${a.mime_type} to a Google format.`);
        metadata.mimeType = target;
      }
      const boundary = `awan${Date.now().toString(36)}${Math.random().toString(36).slice(2)}`;
      const body = Buffer.concat([
        Buffer.from(`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n--${boundary}\r\nContent-Type: ${a.mime_type}\r\n\r\n`),
        bytes,
        Buffer.from(`\r\n--${boundary}--`),
      ]);
      const f = await g({
        method: 'POST',
        url: `${DRIVE_UPLOAD}/files`,
        query: { uploadType: 'multipart', supportsAllDrives: true, fields: FILE_FIELDS },
        headers: { 'Content-Type': `multipart/related; boundary=${boundary}` },
        body,
      });
      return { uploaded: true, file: f };
    },
  },
  {
    name: 'share_file',
    title: 'Share a file',
    description:
      'Share a Drive file or folder. type "user"/"group" needs email; "domain" needs domain; "anyone" makes it available to anyone with the link — only do that when the user explicitly asked for a public link. Sharing with people the user named is approved by their request.',
    inputSchema: obj(
      {
        file_id: str('The file id.'),
        role: str('Access level.', { enum: ['reader', 'commenter', 'writer'], default: 'reader' }),
        type: str('Who gets access.', { enum: ['user', 'group', 'domain', 'anyone'], default: 'user' }),
        email: str('Address for type user or group.'),
        domain: str('Domain for type domain, e.g. example.com.'),
        send_notification: bool('Email the person a notification (user/group only).', true),
        message: str('Note included in the notification email.'),
      },
      ['file_id'],
    ),
    annotations: { openWorldHint: true },
    async run(a, { g }) {
      if ((a.type === 'user' || a.type === 'group') && !a.email) throw new Error('email is required for type user or group.');
      if (a.type === 'domain' && !a.domain) throw new Error('domain is required for type domain.');
      const perm: Record<string, unknown> = { role: a.role, type: a.type };
      if (a.email) perm.emailAddress = a.email;
      if (a.domain) perm.domain = a.domain;
      const notify = a.type === 'user' || a.type === 'group' ? a.send_notification : undefined;
      const p = await g({
        method: 'POST',
        url: `${DRIVE}/files/${enc(a.file_id)}/permissions`,
        query: { supportsAllDrives: true, sendNotificationEmail: notify, emailMessage: notify ? a.message : undefined, fields: 'id,type,role,emailAddress,domain' },
        json: perm,
      });
      const f = (await g({ url: `${DRIVE}/files/${enc(a.file_id)}`, query: { supportsAllDrives: true, fields: 'id,name,webViewLink' } })) as { id: string; name: string; webViewLink?: string };
      return { shared: true, permission: p, file: f };
    },
  },
  {
    name: 'move_file',
    title: 'Move a file',
    description: 'Move a Drive file into another folder (removing it from its current folders), optionally renaming it.',
    inputSchema: obj({ file_id: str('The file id.'), folder_id: str('Destination folder id.'), new_name: str('Optional new name.') }, ['file_id', 'folder_id']),
    async run(a, { g }) {
      const cur = (await g({ url: `${DRIVE}/files/${enc(a.file_id)}`, query: { supportsAllDrives: true, fields: 'parents' } })) as { parents?: string[] };
      const remove = (cur.parents ?? []).filter((p) => p !== a.folder_id).join(',');
      const f = await g({
        method: 'PATCH',
        url: `${DRIVE}/files/${enc(a.file_id)}`,
        query: { addParents: a.folder_id, removeParents: remove || undefined, supportsAllDrives: true, fields: FILE_FIELDS },
        json: a.new_name ? { name: a.new_name } : {},
      });
      return { moved: true, file: f };
    },
  },
];

// ───────────────────────────── Docs ─────────────────────────────

type DocContent = { paragraph?: { elements?: { textRun?: { content?: string } }[] }; table?: { tableRows?: { tableCells?: { content?: DocContent[] }[] }[] } };

export function docText(content: DocContent[] = []): string {
  let out = '';
  for (const c of content) {
    if (c.paragraph) out += (c.paragraph.elements ?? []).map((e) => e.textRun?.content ?? '').join('');
    else if (c.table) {
      for (const row of c.table.tableRows ?? []) {
        out += (row.tableCells ?? []).map((cell) => docText(cell.content).replace(/\n+$/, '').replace(/\n/g, ' ')).join('\t') + '\n';
      }
    }
  }
  return out;
}

const DOC_TEXT_FIELDS =
  'documentId,title,body(content(paragraph(elements(textRun(content))),table(tableRows(tableCells(content(paragraph(elements(textRun(content)))))))))';
const docUrl = (id: string) => `https://docs.google.com/document/d/${id}/edit`;

const docsTools: Tool[] = [
  {
    name: 'create_document',
    title: 'Create a document',
    description: 'Create a Google Doc with a title and, optionally, initial plain text. Returns documentId and link. Read it back with get_document_text to confirm the body landed.',
    inputSchema: obj({ title: str('Document title.'), text: str('Initial body text (plain text; newlines become paragraphs).') }, ['title']),
    async run(a, { g }) {
      const d = (await g({ method: 'POST', url: DOCS, query: { fields: 'documentId,title' }, json: { title: a.title } })) as { documentId: string; title: string };
      if (a.text) {
        await g({ method: 'POST', url: `${DOCS}/${enc(d.documentId)}:batchUpdate`, json: { requests: [{ insertText: { location: { index: 1 }, text: a.text } }] } });
      }
      return { created: true, documentId: d.documentId, title: d.title, url: docUrl(d.documentId), characters: a.text?.length ?? 0 };
    },
  },
  {
    name: 'get_document_text',
    title: 'Read a document',
    description: 'Read a Google Doc as plain text (tables become tab-separated rows).',
    inputSchema: obj({ document_id: str('The document id (from the URL /document/d/<id>/).'), max_chars: int('Cut at this many characters.', 500, 200_000, 50_000) }, ['document_id']),
    annotations: { readOnlyHint: true },
    async run(a, { g }) {
      const d = (await g({ url: `${DOCS}/${enc(a.document_id)}`, query: { fields: DOC_TEXT_FIELDS } })) as { documentId: string; title: string; body?: { content?: DocContent[] } };
      const c = clip(docText(d.body?.content), a.max_chars);
      return { documentId: d.documentId, title: d.title, url: docUrl(d.documentId), text: c.text, truncated: c.truncated, totalChars: c.totalChars };
    },
  },
  {
    name: 'append_text',
    title: 'Append text',
    description: 'Append plain text at the end of a Google Doc. Start the text with "\\n" to begin a new paragraph.',
    inputSchema: obj({ document_id: str('The document id.'), text: str('Text to add at the end.') }, ['document_id', 'text']),
    async run(a, { g }) {
      await g({ method: 'POST', url: `${DOCS}/${enc(a.document_id)}:batchUpdate`, json: { requests: [{ insertText: { endOfSegmentLocation: {}, text: a.text } }] } });
      return { appended: true, documentId: a.document_id, characters: a.text.length };
    },
  },
  {
    name: 'replace_text',
    title: 'Find and replace',
    description: 'Replace every occurrence of `find` with `replace` in a Google Doc. Returns how many were changed (0 means nothing matched).',
    inputSchema: obj({ document_id: str('The document id.'), find: str('Exact text to find.'), replace: str('Replacement text (empty string deletes).'), match_case: bool('Case-sensitive match.', true) }, ['document_id', 'find', 'replace']),
    async run(a, { g }) {
      const r = (await g({
        method: 'POST',
        url: `${DOCS}/${enc(a.document_id)}:batchUpdate`,
        json: { requests: [{ replaceAllText: { containsText: { text: a.find, matchCase: a.match_case }, replaceText: a.replace } }] },
      })) as { replies?: { replaceAllText?: { occurrencesChanged?: number } }[] };
      return { documentId: a.document_id, occurrencesChanged: r.replies?.[0]?.replaceAllText?.occurrencesChanged ?? 0 };
    },
  },
];

// ───────────────────────────── Sheets ─────────────────────────────

export const quoteSheet = (title: string) => `'${title.replace(/'/g, "''")}'`;
const sheetUrl = (id: string) => `https://docs.google.com/spreadsheets/d/${id}/edit`;
const valueInput: JsonSchema = { type: 'string', enum: ['USER_ENTERED', 'RAW'], default: 'USER_ENTERED', description: 'USER_ENTERED parses numbers, dates and =formulas like typing into the sheet; RAW stores strings as-is.' };

const sheetsTools: Tool[] = [
  {
    name: 'create_spreadsheet',
    title: 'Create a spreadsheet',
    description: 'Create a Google Sheet, optionally with named tabs and initial rows written to the first tab from A1. Returns spreadsheetId, link and tabs.',
    inputSchema: obj(
      {
        title: str('Spreadsheet title.'),
        sheet_titles: strList('Tab names (default one tab, "Sheet1").', { maxItems: 50 }),
        rows: grid('Optional rows for the first tab, e.g. [["Name","Email"],["Ana","ana@example.com"]].'),
      },
      ['title'],
    ),
    async run(a, { g }) {
      const tabs = asList(a.sheet_titles);
      const s = (await g({
        method: 'POST',
        url: SHEETS,
        query: { fields: 'spreadsheetId,spreadsheetUrl,sheets(properties(sheetId,title))' },
        json: { properties: { title: a.title }, ...(tabs.length ? { sheets: tabs.map((title) => ({ properties: { title } })) } : {}) },
      })) as { spreadsheetId: string; spreadsheetUrl?: string; sheets?: { properties: { sheetId: number; title: string } }[] };
      const sheets = (s.sheets ?? []).map((x) => x.properties);
      let written: unknown = null;
      if (a.rows?.length && sheets[0]) {
        written = await g({ method: 'PUT', url: `${SHEETS}/${enc(s.spreadsheetId)}/values/${enc(`${quoteSheet(sheets[0].title)}!A1`)}`, query: { valueInputOption: 'USER_ENTERED' }, json: { values: a.rows } });
      }
      return { created: true, spreadsheetId: s.spreadsheetId, url: s.spreadsheetUrl ?? sheetUrl(s.spreadsheetId), sheets, written };
    },
  },
  {
    name: 'get_values',
    title: 'Read cells',
    description: 'Read cell values in A1 notation (e.g. "Sheet1!A1:D50", or just a tab name for the whole tab). Without range, lists the tabs and returns the first tab. Rows are capped at max_rows.',
    inputSchema: obj(
      {
        spreadsheet_id: str('The spreadsheet id (from the URL /spreadsheets/d/<id>/).'),
        range: str('A1 range, e.g. "Sheet1!A1:D50" or "\'Q3 Sales\'".'),
        value_render: str('How values come back.', { enum: ['FORMATTED_VALUE', 'UNFORMATTED_VALUE', 'FORMULA'], default: 'FORMATTED_VALUE' }),
        max_rows: int('Return at most this many rows.', 1, 5000, 500),
      },
      ['spreadsheet_id'],
    ),
    annotations: { readOnlyHint: true },
    async run(a, { g }) {
      let range = a.range as string | undefined;
      let sheets: { sheetId: number; title: string; rows?: number; columns?: number }[] | undefined;
      if (!range) {
        const meta = (await g({ url: `${SHEETS}/${enc(a.spreadsheet_id)}`, query: { fields: 'properties.title,sheets.properties(sheetId,title,gridProperties(rowCount,columnCount))' } })) as {
          sheets?: { properties: { sheetId: number; title: string; gridProperties?: { rowCount?: number; columnCount?: number } } }[];
        };
        sheets = (meta.sheets ?? []).map((s) => ({ sheetId: s.properties.sheetId, title: s.properties.title, rows: s.properties.gridProperties?.rowCount, columns: s.properties.gridProperties?.columnCount }));
        if (!sheets.length) return { sheets: [], values: [] };
        range = quoteSheet(sheets[0].title);
      }
      const r = (await g({ url: `${SHEETS}/${enc(a.spreadsheet_id)}/values/${enc(range)}`, query: { valueRenderOption: a.value_render } })) as { range: string; values?: unknown[][] };
      const values = r.values ?? [];
      return { range: r.range, rowCount: values.length, values: values.slice(0, a.max_rows), truncated: values.length > a.max_rows, ...(sheets ? { sheets } : {}) };
    },
  },
  {
    name: 'append_rows',
    title: 'Append rows',
    description: 'Append rows after the last row of a table (range is usually just the tab name, e.g. "Leads"). Returns the range written; read it back with get_values to confirm.',
    inputSchema: obj(
      { spreadsheet_id: str('The spreadsheet id.'), range: str('Tab name or the table\'s A1 range.'), rows: grid('Rows to add, each an array of cell values.'), value_input: valueInput },
      ['spreadsheet_id', 'range', 'rows'],
    ),
    async run(a, { g }) {
      const r = (await g({
        method: 'POST',
        url: `${SHEETS}/${enc(a.spreadsheet_id)}/values/${enc(a.range)}:append`,
        query: { valueInputOption: a.value_input, insertDataOption: 'INSERT_ROWS', fields: 'updates(updatedRange,updatedRows,updatedCells)' },
        json: { values: a.rows },
      })) as { updates?: { updatedRange?: string; updatedRows?: number; updatedCells?: number } };
      return { appended: true, updatedRange: r.updates?.updatedRange ?? null, updatedRows: r.updates?.updatedRows ?? 0, updatedCells: r.updates?.updatedCells ?? 0 };
    },
  },
  {
    name: 'update_values',
    title: 'Write cells',
    description: 'Overwrite cells starting at an A1 range with a rectangular 2-D array. Only overwrite what the user asked to replace; to shrink a table, clear the old range first or use a new tab.',
    inputSchema: obj(
      { spreadsheet_id: str('The spreadsheet id.'), range: str('Top-left cell or full A1 range, e.g. "Sheet1!B2".'), values: grid('Rows of cell values.'), value_input: valueInput },
      ['spreadsheet_id', 'range', 'values'],
    ),
    async run(a, { g }) {
      const r = (await g({
        method: 'PUT',
        url: `${SHEETS}/${enc(a.spreadsheet_id)}/values/${enc(a.range)}`,
        query: { valueInputOption: a.value_input, fields: 'updatedRange,updatedRows,updatedColumns,updatedCells' },
        json: { values: a.values },
      })) as { updatedRange?: string; updatedRows?: number; updatedColumns?: number; updatedCells?: number };
      return { updated: true, ...r };
    },
  },
  {
    name: 'add_sheet',
    title: 'Add a tab',
    description: 'Add a new tab (sheet) to a spreadsheet.',
    inputSchema: obj(
      { spreadsheet_id: str('The spreadsheet id.'), title: str('New tab name.'), rows: int('Row count.', 1, 100_000, 1000), columns: int('Column count.', 1, 1000, 26) },
      ['spreadsheet_id', 'title'],
    ),
    async run(a, { g }) {
      const r = (await g({
        method: 'POST',
        url: `${SHEETS}/${enc(a.spreadsheet_id)}:batchUpdate`,
        json: { requests: [{ addSheet: { properties: { title: a.title, gridProperties: { rowCount: a.rows, columnCount: a.columns } } } }] },
      })) as { replies?: { addSheet?: { properties?: { sheetId: number; title: string } } }[] };
      const p = r.replies?.[0]?.addSheet?.properties;
      return { added: true, sheetId: p?.sheetId ?? null, title: p?.title ?? a.title };
    },
  },
];

// ───────────────────────────── servers ─────────────────────────────

const VERSION = '1.0.0';
const COMMON = 'Runs on Awan\'s server with the user\'s own Google account; credentials are already set up — never ask for tokens. If a call says Google is not connected or access was revoked, tell the user to connect it in Awan → Settings → Integrations.';

export const GOOGLE_MCP_SERVERS: Record<string, McpServerSpec<GoogleToolCtx>> = {
  gmail: {
    name: 'awan-gmail',
    title: 'Gmail (Awan)',
    version: VERSION,
    instructions: `The user's Gmail. Search with Gmail query syntax, read with get_message, triage with modify_labels. Draft with create_draft / reply_draft; send_draft only after the user explicitly approves that exact draft. ${COMMON}`,
    tools: gmailTools,
  },
  'google-calendar': {
    name: 'awan-google-calendar',
    title: 'Google Calendar (Awan)',
    version: VERSION,
    instructions: `The user's Google Calendar. Times are RFC 3339 with an offset; say times back in the user's time zone. Re-read an event after creating or changing it. ${COMMON}`,
    tools: calendarTools,
  },
  'google-drive': {
    name: 'awan-google-drive',
    title: 'Google Drive (Awan)',
    version: VERSION,
    instructions: `The user's Google Drive. search_files → get_file_metadata / download_text. Public "anyone" sharing only when explicitly asked. ${COMMON}`,
    tools: driveTools,
  },
  'google-docs': {
    name: 'awan-google-docs',
    title: 'Google Docs (Awan)',
    version: VERSION,
    instructions: `The user's Google Docs. After creating or editing, read the text back with get_document_text to confirm. Find documents with the Google Drive server's search_files. ${COMMON}`,
    tools: docsTools,
  },
  'google-sheets': {
    name: 'awan-google-sheets',
    title: 'Google Sheets (Awan)',
    version: VERSION,
    instructions: `The user's Google Sheets. Use A1 ranges; quote tab names with spaces ('Q3 Sales'!A1). Read back with get_values after writing. ${COMMON}`,
    tools: sheetsTools,
  },
};
