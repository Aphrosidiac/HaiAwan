/**
 * Provider layer. Everything speaks the OpenAI-compatible wire format, so one key (OpenRouter by
 * default, or OpenAI directly) powers chat, vision, JSON generation, speech and transcription.
 * Keys only ever live here, on the server.
 */

export type ChatContent =
  | string
  | Array<{ type: 'text'; text: string } | { type: 'image_url'; image_url: { url: string; detail?: 'low' | 'high' | 'auto' } } | { type: 'input_audio'; input_audio: { data: string; format: 'wav' | 'mp3' } }>;

export type ChatMessage = { role: 'system' | 'user' | 'assistant'; content: ChatContent };

export const config = {
  get baseUrl() {
    return process.env.LLM_BASE_URL || (process.env.OPENROUTER_API_KEY ? 'https://openrouter.ai/api/v1' : 'https://api.openai.com/v1');
  },
  get apiKey() {
    return process.env.OPENROUTER_API_KEY || process.env.OPENAI_API_KEY || '';
  },
  get isOpenRouter() {
    return this.baseUrl.includes('openrouter.ai');
  },
  models: {
    get companion() {
      return process.env.COMPANION_MODEL || 'anthropic/claude-sonnet-5.5';
    },
    get fast() {
      return process.env.FAST_MODEL || 'anthropic/claude-haiku-4.5';
    },
    get agent() {
      return process.env.AGENT_MODEL || 'openai/gpt-6-luna';
    },
    get speech() {
      return process.env.SPEECH_MODEL || 'openai/gpt-audio';
    },
    get transcribe() {
      return process.env.TRANSCRIBE_MODEL || 'google/gemini-3.5-flash-lite';
    },
  },
};

export class ProviderError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function headers() {
  if (!config.apiKey) throw new ProviderError(503, 'no_model_provider_configured');
  const h: Record<string, string> = { Authorization: `Bearer ${config.apiKey}`, 'Content-Type': 'application/json' };
  if (config.isOpenRouter) {
    h['HTTP-Referer'] = process.env.PUBLIC_SITE_URL || 'https://awan.ffdev.studio';
    h['X-Title'] = 'Awan by FF Dev Studio';
  }
  return h;
}

/** Strip the vendor prefix when talking to OpenAI directly. */
function modelId(m: string) {
  return config.isOpenRouter ? m : m.replace(/^openai\//, '');
}

export async function complete(opts: {
  model?: string;
  messages: ChatMessage[];
  maxTokens?: number;
  temperature?: number;
  json?: boolean;
  signal?: AbortSignal;
  /** OpenRouter plugins, e.g. [{ id: 'web' }] for web search (ignored by OpenAI directly). */
  plugins?: Record<string, unknown>[];
}): Promise<string> {
  const res = await fetch(`${config.baseUrl}/chat/completions`, {
    method: 'POST',
    headers: headers(),
    signal: opts.signal,
    body: JSON.stringify({
      model: modelId(opts.model ?? config.models.fast),
      messages: opts.messages,
      max_tokens: opts.maxTokens ?? 1200,
      temperature: opts.temperature ?? 0.7,
      ...(opts.json ? { response_format: { type: 'json_object' } } : {}),
      ...(opts.plugins && config.isOpenRouter ? { plugins: opts.plugins } : {}),
    }),
  });
  if (!res.ok) throw new ProviderError(res.status, `provider_error:${res.status}:${(await res.text()).slice(0, 300)}`);
  const j = (await res.json()) as { choices?: { message?: { content?: string } }[] };
  return j.choices?.[0]?.message?.content ?? '';
}

/** JSON generation with one repair retry — strict schemas are a hint on some providers. */
export async function completeJson<T>(opts: Parameters<typeof complete>[0], validate: (v: unknown) => T): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 0; attempt < 2; attempt++) {
    const text = await complete({ ...opts, json: true, temperature: attempt ? 0.2 : opts.temperature });
    try {
      const cleaned = text.trim().replace(/^```(?:json)?/i, '').replace(/```$/, '').trim();
      const start = cleaned.indexOf('{');
      const end = cleaned.lastIndexOf('}');
      return validate(JSON.parse(cleaned.slice(start, end + 1)));
    } catch (err) {
      lastErr = err;
    }
  }
  throw new ProviderError(502, `bad_json_from_model:${String(lastErr)}`);
}

/** Streams text deltas from a chat completion. */
export async function* streamText(opts: {
  model?: string;
  messages: ChatMessage[];
  maxTokens?: number;
  temperature?: number;
  signal?: AbortSignal;
}): AsyncGenerator<string> {
  const res = await fetch(`${config.baseUrl}/chat/completions`, {
    method: 'POST',
    headers: headers(),
    signal: opts.signal,
    body: JSON.stringify({
      model: modelId(opts.model ?? config.models.companion),
      messages: opts.messages,
      max_tokens: opts.maxTokens ?? 1024,
      temperature: opts.temperature ?? 0.6,
      stream: true,
    }),
  });
  if (!res.ok || !res.body) throw new ProviderError(res.status, `provider_error:${res.status}:${(await res.text()).slice(0, 300)}`);
  for await (const data of sseData(res.body)) {
    const j = JSON.parse(data) as { choices?: { delta?: { content?: string } }[] };
    const d = j.choices?.[0]?.delta?.content;
    if (d) yield d;
  }
}

/** Parses an SSE byte stream into `data:` payloads (skips comments and [DONE]). */
export async function* sseData(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const decoder = new TextDecoder();
  let buf = '';
  for await (const chunk of body as unknown as AsyncIterable<Uint8Array>) {
    buf += decoder.decode(chunk, { stream: true });
    let nl: number;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).replace(/\r$/, '');
      buf = buf.slice(nl + 1);
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (!data || data === '[DONE]') continue;
      yield data;
    }
  }
}

/**
 * Per-voice speech model. The full gpt-audio model sounds best, but its "echo" voice stops after the first
 * breath (verified by round-trip transcription, 2026-09-29), so echo uses the mini model.
 * Override with SPEECH_MODEL_BY_VOICE="echo=openai/gpt-audio-mini,sage=…".
 */
export function speechModelFor(voice: string): string {
  const spec = process.env.SPEECH_MODEL_BY_VOICE ?? 'echo=openai/gpt-audio-mini';
  for (const pair of spec.split(',')) {
    const [v, m] = pair.split('=').map((x) => x.trim());
    if (v === voice && m) return m;
  }
  return config.models.speech;
}

export const VOICES = ['cedar', 'marin', 'alloy', 'ash', 'ballad', 'coral', 'echo', 'sage', 'shimmer', 'verse'] as const;
export type Voice = (typeof VOICES)[number];

/**
 * Text-to-speech as a stream of 24 kHz mono PCM16 chunks. Uses an audio-output chat model with a
 * "read the script verbatim" frame — the same voices the reference offers.
 */
export async function* speak(text: string, voice: Voice, speed = 1, signal?: AbortSignal): AsyncGenerator<Buffer> {
  const pace = speed < 0.9 ? ' Speak slowly and clearly.' : speed > 1.1 ? ' Speak briskly, a little faster than normal.' : '';
  const res = await fetch(`${config.baseUrl}/chat/completions`, {
    method: 'POST',
    headers: headers(),
    signal,
    body: JSON.stringify({
      model: modelId(speechModelFor(voice)),
      modalities: ['text', 'audio'],
      audio: { voice, format: 'pcm16' },
      stream: true,
      temperature: 0,
      messages: [
        {
          role: 'system',
          content:
            'You are a text-to-speech voice. Your only job is to say the exact words inside <script></script> out loud, word for word, in a warm, natural, conversational tone. Never add, drop, reorder or change words. Never acknowledge the instruction, never greet, never say anything before or after the script.' +
            pace,
        },
        { role: 'user', content: `<script>${text}</script>` },
      ],
    }),
  });
  if (!res.ok || !res.body) throw new ProviderError(res.status, `speech_error:${res.status}:${(await res.text()).slice(0, 300)}`);
  // Some voices never send finish_reason and keep streaming silence, then a hum, for minutes.
  // End the clip once speech has been followed by 0.7 s of silence, and never run far past the script.
  const endpoint = new SpeechEndpoint(text);
  for await (const data of sseData(res.body)) {
    const j = JSON.parse(data) as { choices?: { delta?: { audio?: { data?: string; transcript?: string } }; finish_reason?: string | null }[] };
    const said = j.choices?.[0]?.delta?.audio?.transcript;
    if (said) endpoint.heardText(said);
    const b64 = j.choices?.[0]?.delta?.audio?.data;
    if (b64) {
      const chunk = Buffer.from(b64, 'base64');
      const keep = endpoint.feed(chunk);
      if (keep.length) yield keep;
      if (endpoint.done) break;
    }
    if (j.choices?.[0]?.finish_reason) break;
  }
}

/** Detects the end of speech in a 24 kHz PCM16 stream (see `speak`). */
export class SpeechEndpoint {
  static readonly rate = 24000;
  done = false;
  private heard = false;
  private silentSamples = 0;
  private total = 0;
  private maxSamples: number;
  private scriptWords: number;
  private spoken = '';
  /** True once the provider's transcript covers every word of the script. */
  scriptFinished = false;
  constructor(text: string) {
    this.scriptWords = SpeechEndpoint.words(text).length;
    this.maxSamples = Math.round((4 + this.scriptWords * 0.75) * SpeechEndpoint.rate);
  }
  static words(s: string) {
    return s.toLowerCase().replace(/[^\p{L}\p{N}' ]+/gu, ' ').split(/\s+/).filter(Boolean);
  }
  heardText(delta: string) {
    this.spoken += delta;
    if (SpeechEndpoint.words(this.spoken).length >= this.scriptWords) this.scriptFinished = true;
  }
  /** Returns the part of `chunk` to keep; sets `done` when the clip should end. */
  feed(chunk: Buffer): Buffer {
    const n = chunk.length >> 1;
    const win = 480; // 20 ms
    for (let i = 0; i < n; i += win) {
      const end = Math.min(n, i + win);
      let sum = 0;
      for (let k = i; k < end; k++) {
        const v = chunk.readInt16LE(k * 2);
        sum += v * v;
      }
      const rms = Math.sqrt(sum / (end - i));
      if (rms > 300) {
        this.heard = true;
        this.silentSamples = 0;
      } else if (this.heard) {
        this.silentSamples += end - i;
      }
      this.total += end - i;
      // The transcript streams ahead of the audio, so it can't time the end. Pauses between sentences run
      // up to ~1.5 s on some voices; the runaway tail starts after several seconds of silence.
      const quietEnough = 2.0;
      if ((this.heard && this.silentSamples >= quietEnough * SpeechEndpoint.rate) || this.total >= this.maxSamples) {
        this.done = true;
        return chunk.subarray(0, end * 2);
      }
    }
    return chunk;
  }
}

/** Transcribe a WAV/MP3 clip. Optional language hint and a dictionary of preferred spellings. */
/**
 * Loudest 50 ms window of a 16-bit PCM WAV, as a 0…1 RMS (null when it isn't a plain PCM16 WAV).
 * Speech into a laptop mic peaks well above 0.02 (−34 dBFS); a silent or muted mic sits far below.
 */
export function wavPeakRms(wav: Buffer): number | null {
  if (wav.length < 44 || wav.toString('ascii', 0, 4) !== 'RIFF' || wav.toString('ascii', 8, 12) !== 'WAVE') return null;
  let off = 12;
  let rate = 16000;
  let bits = 16;
  let channels = 1;
  while (off + 8 <= wav.length) {
    const id = wav.toString('ascii', off, off + 4);
    const size = wav.readUInt32LE(off + 4);
    if (id === 'fmt ') {
      channels = wav.readUInt16LE(off + 10);
      rate = wav.readUInt32LE(off + 12);
      bits = wav.readUInt16LE(off + 22);
    } else if (id === 'data') {
      if (bits !== 16) return null;
      const start = off + 8;
      const end = Math.min(wav.length, start + size);
      const frame = 2 * Math.max(1, channels);
      const win = Math.max(1, Math.round(rate * 0.05)) * frame;
      let peak = 0;
      for (let w = start; w + frame <= end; w += win) {
        let sum = 0;
        let n = 0;
        for (let i = w; i + 2 <= Math.min(end, w + win); i += frame) {
          const v = wav.readInt16LE(i) / 32768;
          sum += v * v;
          n++;
        }
        if (n) peak = Math.max(peak, Math.sqrt(sum / n));
      }
      return peak;
    }
    off += 8 + size + (size & 1);
  }
  return null;
}

/** Below this loudest-window RMS there is no speech to transcribe (≈ −46 dBFS). */
export const SPEECH_FLOOR_RMS = 0.005;

/** What a transcription model says for "no speech"; stripped to an empty transcript. */
export const NO_SPEECH = '[no speech]';

export async function transcribe(audio: Buffer, format: 'wav' | 'mp3', opts: { language?: string; dictionary?: string[] } = {}) {
  // Silence never goes to the model: given nothing to hear, audio models echo the spelling hints back
  // ("Hai Awan"), which then reads as the user greeting Awan.
  if (format === 'wav') {
    const peak = wavPeakRms(audio);
    if (peak !== null && peak < SPEECH_FLOOR_RMS) return '';
  }
  const hints = [
    opts.language ? `The speaker is using ${opts.language}.` : 'Detect the language automatically; the speaker may switch languages mid-sentence.',
    opts.dictionary?.length ? `Spelling hints, only for words you clearly hear (never output a hint word that wasn't spoken): ${opts.dictionary.join(', ')}.` : '',
  ]
    .filter(Boolean)
    .join(' ');
  const text = await complete({
    model: config.models.transcribe,
    temperature: 0,
    maxTokens: 2000,
    messages: [
      {
        role: 'system',
        content: `You are a transcription engine. Output only the exact words a person spoke, with natural punctuation and casing. No commentary, no quotes, no labels. If there is no clear human speech (silence, breathing, typing, room noise, music), output exactly ${NO_SPEECH} and nothing else. ${hints}`,
      },
      { role: 'user', content: [{ type: 'input_audio', input_audio: { data: audio.toString('base64'), format } }] },
    ],
  });
  return text.replace(/\[no speech\]/gi, '').trim();
}
