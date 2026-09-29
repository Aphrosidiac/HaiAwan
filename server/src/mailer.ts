/**
 * Outgoing email for sign-in links. Two providers, whichever is configured (Resend wins when both are):
 *   RESEND_API_KEY                     → Resend's HTTP API
 *   SMTP_HOST (+ PORT/USER/PASS/SECURE) → a minimal SMTP client over node:net / node:tls (no dependency)
 * The sender is MAIL_FROM (SMTP_FROM is accepted as an alias).
 */
import net from 'node:net';
import tls from 'node:tls';
import { randomBytes } from 'node:crypto';
import type { FetchLike } from './connectors.ts';

export type MailMessage = { to: string; subject: string; html: string; text: string };
export interface Mailer {
  readonly name: string;
  send(msg: MailMessage): Promise<{ id?: string }>;
}

export class MailError extends Error {}

const DEFAULT_FROM = 'Awan <signin@awan.ffdev.studio>';

// ───────────────────────────── Resend ─────────────────────────────

export class ResendMailer implements Mailer {
  readonly name = 'resend';
  private apiKey: string;
  private from: string;
  private fetch: FetchLike;
  constructor(apiKey: string, from: string, fetchImpl: FetchLike = fetch) {
    this.apiKey = apiKey;
    this.from = from;
    this.fetch = fetchImpl;
  }
  async send(msg: MailMessage) {
    const res = await this.fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${this.apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: this.from, to: [msg.to], subject: msg.subject, html: msg.html, text: msg.text }),
    });
    const body = (await res.json().catch(() => ({}))) as { id?: string; message?: string; name?: string };
    if (!res.ok) throw new MailError(`Resend refused the email (${res.status}${body.message ? `: ${body.message}` : ''})`);
    return { id: body.id };
  }
}

// ───────────────────────────── SMTP ─────────────────────────────

export type SmtpOptions = {
  host: string;
  port: number;
  user?: string;
  pass?: string;
  from: string;
  /** tls = implicit TLS (465); starttls = upgrade, required; none = plaintext (local relays / tests only). */
  secure: 'tls' | 'starttls' | 'none';
  heloName?: string;
  timeoutMs?: number;
  tlsOptions?: tls.ConnectionOptions;
};

type Reply = { code: number; lines: string[] };

/** Line-oriented SMTP conversation over a socket that can be upgraded to TLS in place. */
class SmtpSession {
  private socket!: net.Socket;
  private buf = '';
  private replies: Reply[] = [];
  private waiting: { resolve: (r: Reply) => void; reject: (e: Error) => void } | null = null;
  private failure: Error | null = null;
  private partial: string[] = [];
  private timeoutMs: number;
  constructor(timeoutMs: number) {
    this.timeoutMs = timeoutMs;
  }

  attach(socket: net.Socket) {
    this.socket = socket;
    this.buf = '';
    socket.setEncoding('utf8');
    socket.setTimeout(this.timeoutMs, () => this.fail(new MailError('SMTP server timed out')));
    socket.on('data', (chunk: string) => this.onData(chunk));
    socket.on('error', (e) => this.fail(new MailError(`SMTP connection failed: ${e.message}`)));
    socket.on('close', () => this.fail(new MailError('SMTP server closed the connection')));
  }

  private onData(chunk: string) {
    this.buf += chunk;
    let i: number;
    while ((i = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, i).replace(/\r$/, '');
      this.buf = this.buf.slice(i + 1);
      const m = /^(\d{3})([ -])(.*)$/.exec(line);
      if (!m) continue;
      this.partial.push(m[3]);
      if (m[2] === ' ') {
        const reply = { code: Number(m[1]), lines: this.partial };
        this.partial = [];
        if (this.waiting) {
          const w = this.waiting;
          this.waiting = null;
          w.resolve(reply);
        } else this.replies.push(reply);
      }
    }
  }

  private fail(e: Error) {
    if (this.failure) return;
    this.failure = e;
    if (this.waiting) {
      const w = this.waiting;
      this.waiting = null;
      w.reject(e);
    }
  }

  /** Stop treating close/timeout of the current socket as a failure (before a STARTTLS swap or QUIT). */
  detach() {
    this.socket.removeAllListeners('data');
    this.socket.removeAllListeners('close');
    this.socket.removeAllListeners('error');
    this.socket.setTimeout(0);
  }

  read(): Promise<Reply> {
    const r = this.replies.shift();
    if (r) return Promise.resolve(r);
    if (this.failure) return Promise.reject(this.failure);
    return new Promise((resolve, reject) => (this.waiting = { resolve, reject }));
  }

  async cmd(line: string | null, expect: number[], what = line ?? 'greeting'): Promise<Reply> {
    if (line !== null) this.socket.write(`${line}\r\n`);
    const r = await this.read();
    if (!expect.includes(r.code)) throw new MailError(`SMTP ${what.split(' ')[0]} failed: ${r.code} ${r.lines.join(' ')}`.slice(0, 300));
    return r;
  }

  write(data: string) {
    this.socket.write(data);
  }

  get current(): net.Socket {
    return this.socket;
  }

  end() {
    this.detach();
    this.socket.on('error', () => {});
    this.socket.end();
  }
}

export const bareAddress = (s: string) => (/<([^>]+)>/.exec(s)?.[1] ?? s).trim();

function b64Wrap(s: string) {
  return Buffer.from(s, 'utf8').toString('base64').replace(/.{1,76}/g, '$&\r\n').trimEnd();
}

function encodeHeader(v: string) {
  const clean = v.replace(/[\r\n]+/g, ' ').trim();
  return /^[\x20-\x7e]*$/.test(clean) ? clean : `=?UTF-8?B?${Buffer.from(clean, 'utf8').toString('base64')}?=`;
}

/** RFC 5322 message: multipart/alternative (text + HTML), base64 bodies. */
export function formatEmail(from: string, msg: MailMessage, date = new Date()): string {
  const boundary = `awan_${randomBytes(8).toString('hex')}`;
  const domain = bareAddress(from).split('@')[1] ?? 'awan.local';
  return [
    `From: ${from.replace(/[\r\n]+/g, ' ')}`,
    `To: ${msg.to.replace(/[\r\n]+/g, ' ')}`,
    `Subject: ${encodeHeader(msg.subject)}`,
    `Date: ${date.toUTCString().replace('GMT', '+0000')}`,
    `Message-ID: <${randomBytes(12).toString('hex')}@${domain}>`,
    'MIME-Version: 1.0',
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
    '',
    `--${boundary}`,
    'Content-Type: text/plain; charset="UTF-8"',
    'Content-Transfer-Encoding: base64',
    '',
    b64Wrap(msg.text),
    `--${boundary}`,
    'Content-Type: text/html; charset="UTF-8"',
    'Content-Transfer-Encoding: base64',
    '',
    b64Wrap(msg.html),
    `--${boundary}--`,
    '',
  ].join('\r\n');
}

const isLocalHost = (h: string) => h === 'localhost' || h === '127.0.0.1' || h === '::1';

export class SmtpMailer implements Mailer {
  readonly name = 'smtp';
  private o: SmtpOptions;
  constructor(o: SmtpOptions) {
    this.o = o;
  }

  private connect(session: SmtpSession): Promise<void> {
    const { host, port, secure, tlsOptions } = this.o;
    return new Promise((resolve, reject) => {
      const onError = (e: Error) => reject(new MailError(`Can't reach SMTP server ${host}:${port} (${e.message})`));
      const socket =
        secure === 'tls'
          ? tls.connect({ host, port, servername: net.isIP(host) ? undefined : host, ...tlsOptions }, () => {
              socket.off('error', onError);
              resolve();
            })
          : net.connect({ host, port }, () => {
              socket.off('error', onError);
              resolve();
            });
      socket.once('error', onError);
      session.attach(socket);
    });
  }

  private upgrade(session: SmtpSession, plain: net.Socket): Promise<void> {
    const { host, tlsOptions } = this.o;
    return new Promise((resolve, reject) => {
      const secured = tls.connect({ socket: plain, servername: net.isIP(host) ? undefined : host, ...tlsOptions }, () => resolve());
      secured.once('error', (e) => reject(new MailError(`STARTTLS failed: ${e.message}`)));
      session.attach(secured);
    });
  }

  async send(msg: MailMessage) {
    const o = this.o;
    const session = new SmtpSession(o.timeoutMs ?? 20_000);
    const helo = o.heloName ?? (bareAddress(o.from).split('@')[1] || 'awan.local');
    await this.connect(session);
    try {
      await session.cmd(null, [220]);
      let ehlo = await session.cmd(`EHLO ${helo}`, [250]);
      if (o.secure === 'starttls') {
        if (!ehlo.lines.some((l) => /^STARTTLS\b/i.test(l))) throw new MailError('SMTP server does not offer STARTTLS; refusing to send credentials in the clear');
        await session.cmd('STARTTLS', [220]);
        const plain = session.current;
        session.detach();
        await this.upgrade(session, plain);
        ehlo = await session.cmd(`EHLO ${helo}`, [250]);
      }
      if (o.user) {
        if (o.secure === 'none' && !isLocalHost(o.host)) throw new MailError('Refusing SMTP AUTH over an unencrypted connection');
        const authLine = ehlo.lines.find((l) => /^AUTH\b/i.test(l)) ?? 'AUTH PLAIN';
        if (/\bPLAIN\b/i.test(authLine) || !/\bLOGIN\b/i.test(authLine)) {
          await session.cmd(`AUTH PLAIN ${Buffer.from(`\0${o.user}\0${o.pass ?? ''}`).toString('base64')}`, [235], 'AUTH');
        } else {
          await session.cmd('AUTH LOGIN', [334], 'AUTH');
          await session.cmd(Buffer.from(o.user).toString('base64'), [334], 'AUTH');
          await session.cmd(Buffer.from(o.pass ?? '').toString('base64'), [235], 'AUTH');
        }
      }
      await session.cmd(`MAIL FROM:<${bareAddress(o.from)}>`, [250]);
      await session.cmd(`RCPT TO:<${bareAddress(msg.to)}>`, [250, 251]);
      await session.cmd('DATA', [354]);
      const data = formatEmail(o.from, msg).replace(/(^|\r\n)\./g, '$1..');
      session.write(`${data}\r\n.\r\n`);
      const done = await session.cmd(null, [250], 'DATA');
      await session.cmd('QUIT', [221]).catch(() => undefined);
      const id = /(?:queued as|\bid[=: ]+)\s*(\S+)/i.exec(done.lines.join(' '))?.[1];
      return { id };
    } finally {
      session.end();
    }
  }
}

// ───────────────────────────── config ─────────────────────────────

export function mailerFromEnv(env: NodeJS.ProcessEnv = process.env, fetchImpl: FetchLike = fetch): Mailer | null {
  const from = env.MAIL_FROM || env.SMTP_FROM || DEFAULT_FROM;
  if (env.RESEND_API_KEY) return new ResendMailer(env.RESEND_API_KEY, from, fetchImpl);
  if (env.SMTP_HOST) {
    const port = Number(env.SMTP_PORT || 587);
    const secure = (env.SMTP_SECURE as SmtpOptions['secure']) || (port === 465 ? 'tls' : 'starttls');
    if (!['tls', 'starttls', 'none'].includes(secure)) throw new Error('SMTP_SECURE must be tls, starttls or none');
    return new SmtpMailer({ host: env.SMTP_HOST, port, user: env.SMTP_USER || undefined, pass: env.SMTP_PASS || undefined, from: env.SMTP_FROM || from, secure });
  }
  return null;
}

// ───────────────────────────── the sign-in email ─────────────────────────────

const escHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

/** "Your Awan sign-in link" — FF Dev Studio styling (Ink, Bone, Signal Lime button), table layout for mail clients. */
export function signInEmail(link: string, minutes = 15): { subject: string; html: string; text: string } {
  const subject = 'Your Awan sign-in link';
  const text = [
    'Hi from Awan,',
    '',
    'Tap the link below to sign in on your Mac:',
    link,
    '',
    `It works once and expires in ${minutes} minutes.`,
    "If you didn't ask for this, ignore this email — nobody can sign in without the link.",
    '',
    '— Awan, by FF Dev Studio',
  ].join('\n');
  const l = escHtml(link);
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark light"><title>${subject}</title></head>
<body style="margin:0;padding:0;background:#0B0B0A;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;">Tap to sign in to Awan. The link expires in ${minutes} minutes.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0B0B0A;">
<tr><td align="center" style="padding:40px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#242421;border-radius:20px;">
<tr><td style="padding:36px 32px 8px 32px;font-family:'Instrument Sans',-apple-system,'Segoe UI',Helvetica,Arial,sans-serif;">
<div style="font-size:13px;font-weight:700;letter-spacing:-0.02em;color:#8B8981;">//FF &middot; Awan</div>
<h1 style="margin:22px 0 10px 0;font-size:26px;line-height:1.2;font-weight:600;color:#F3EFE4;">Your sign-in link</h1>
<p style="margin:0 0 26px 0;font-size:15px;line-height:1.55;color:#F3EFE4;opacity:.82;">Tap the button to sign in to Awan on your Mac. It opens the app for you.</p>
<table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="border-radius:999px;background:#D9FF43;">
<a href="${l}" style="display:inline-block;padding:13px 26px;font-size:15px;font-weight:600;color:#0B0B0A;text-decoration:none;border-radius:999px;">Sign in to Awan</a>
</td></tr></table>
<p style="margin:26px 0 0 0;font-size:13px;line-height:1.55;color:#8B8981;">This link works once and expires in ${minutes} minutes. If you didn&rsquo;t ask for it, you can ignore this email &mdash; nobody can sign in without it.</p>
</td></tr>
<tr><td style="padding:18px 32px 30px 32px;font-family:'Instrument Sans',-apple-system,'Segoe UI',Helvetica,Arial,sans-serif;">
<p style="margin:0;font-size:12px;line-height:1.5;color:#8B8981;word-break:break-all;">Button not working? Paste this into your browser:<br><a href="${l}" style="color:#F3EFE4;">${l}</a></p>
</td></tr>
</table>
<p style="margin:18px 0 0 0;font-family:-apple-system,'Segoe UI',Helvetica,Arial,sans-serif;font-size:11px;color:#8B8981;">Awan by FF Dev Studio</p>
</td></tr></table>
</body></html>`;
  return { subject, html, text };
}
