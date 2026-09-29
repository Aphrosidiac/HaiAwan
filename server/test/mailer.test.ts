import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { buildApp } from '../src/app.ts';
import { openDb } from '../src/db.ts';
import { formatEmail, mailerFromEnv, ResendMailer, signInEmail, SmtpMailer, type Mailer, type MailMessage } from '../src/mailer.ts';

process.env.LOG = '0';

/** Records what would have been sent. Nothing leaves the process. */
function fakeMailer(fail = false): Mailer & { sent: MailMessage[] } {
  const sent: MailMessage[] = [];
  return {
    name: 'fake',
    sent,
    async send(m) {
      if (fail) throw new Error('provider down');
      sent.push(m);
      return { id: `fake-${sent.length}` };
    },
  };
}

async function setup(devMode: boolean, mailer: Mailer | null) {
  const db = openDb(':memory:');
  return buildApp({ db, devMode, publicUrl: 'http://api.test', siteUrl: 'http://site.test', mailer, googleClient: null, connectorKey: null });
}

test('magic link is emailed in production: branded, 15-minute note, no devLink, and the link signs in', async () => {
  const mail = fakeMailer();
  const app = await setup(false, mail);
  const r = await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email: 'Fakhrul@Example.com' } });
  assert.equal(r.statusCode, 200);
  assert.deepEqual(r.json(), { sent: true, delivery: 'fake' });
  assert.equal(mail.sent.length, 1);
  const m = mail.sent[0];
  assert.equal(m.to, 'fakhrul@example.com');
  assert.equal(m.subject, 'Your Awan sign-in link');
  assert.match(m.text, /expires in 15 minutes/);
  assert.match(m.html, /#D9FF43/, 'Signal Lime button');
  assert.match(m.html, /\/\/FF/);
  assert.ok(!/clicky/i.test(m.html + m.text));
  const link = /(http:\/\/api\.test\/auth\/verify\?code=[\w-]+)/.exec(m.text)![1];
  assert.ok(m.html.includes(link), 'HTML carries the same link');
  const v = await app.inject({ method: 'GET', url: link.replace('http://api.test', '') });
  assert.equal(v.statusCode, 200);
  assert.match(v.body, /awan:\/\/auth\?token=awn_/);
});

test('no mail provider: production refuses with 503, dev still returns devLink', async () => {
  const prod = await setup(false, null);
  const r = await prod.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email: 'a@b.co' } });
  assert.equal(r.statusCode, 503);
  assert.equal(r.json().error, 'email_unavailable');
  assert.match(r.json().message, /RESEND_API_KEY or SMTP/);
  assert.equal((await prod.inject({ method: 'GET', url: '/v1/config' })).json().features.emailSignIn, false);

  const dev = await setup(true, null);
  const d = await dev.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email: 'a@b.co' } });
  assert.equal(d.statusCode, 200);
  assert.match(d.json().devLink, /^http:\/\/api\.test\/auth\/verify\?code=/);
  assert.equal(d.json().delivery, 'log');
});

test('a failed send is a 502 in production (dev keeps the devLink); links are rate-limited per address', async () => {
  const prod = await setup(false, fakeMailer(true));
  const r = await prod.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email: 'a@b.co' } });
  assert.equal(r.statusCode, 502);
  assert.equal(r.json().error, 'email_failed');

  const dev = await setup(true, fakeMailer(true));
  assert.ok((await dev.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email: 'a@b.co' } })).json().devLink);

  const mail = fakeMailer();
  const app = await setup(false, mail);
  for (let i = 0; i < 5; i++) assert.equal((await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email: 'spam@b.co' } })).statusCode, 200);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email: 'spam@b.co' } })).statusCode, 429);
  assert.equal(mail.sent.length, 5);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email: 'other@b.co' } })).statusCode, 200, 'other addresses are unaffected');
});

test('provider selection: Resend wins, then SMTP (465 → implicit TLS, else STARTTLS), else none', () => {
  assert.equal(mailerFromEnv({}), null);
  assert.equal(mailerFromEnv({ RESEND_API_KEY: 're_x', SMTP_HOST: 'smtp.example.com' })!.name, 'resend');
  const smtp = mailerFromEnv({ SMTP_HOST: 'smtp.example.com', SMTP_PORT: '465' }) as unknown as { name: string; o: { secure: string; from: string } };
  assert.equal(smtp.name, 'smtp');
  assert.equal(smtp.o.secure, 'tls');
  assert.equal((mailerFromEnv({ SMTP_HOST: 'smtp.example.com', SMTP_FROM: 'Awan <hi@x.co>' }) as unknown as { o: { secure: string; from: string } }).o.secure, 'starttls');
  assert.equal((mailerFromEnv({ SMTP_HOST: 'smtp.example.com', SMTP_FROM: 'Awan <hi@x.co>' }) as unknown as { o: { from: string } }).o.from, 'Awan <hi@x.co>');
  assert.throws(() => mailerFromEnv({ SMTP_HOST: 'h', SMTP_SECURE: 'maybe' }));
});

test('Resend: one JSON POST with the key as bearer (fake fetch)', async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const mailer = new ResendMailer('re_test_key', 'Awan <signin@awan.ffdev.studio>', async (url, init = {}) => {
    calls.push({ url: String(url), init });
    return new Response(JSON.stringify({ id: 'email_123' }), { status: 200 });
  });
  const out = await mailer.send({ to: 'a@b.co', ...signInEmail('https://api/x') });
  assert.equal(out.id, 'email_123');
  assert.equal(calls[0].url, 'https://api.resend.com/emails');
  assert.equal((calls[0].init.headers as Record<string, string>).Authorization, 'Bearer re_test_key');
  const body = JSON.parse(String(calls[0].init.body));
  assert.deepEqual(body.to, ['a@b.co']);
  assert.equal(body.from, 'Awan <signin@awan.ffdev.studio>');
  assert.ok(body.html && body.text);

  const refusing = new ResendMailer('bad', 'x@y.co', async () => new Response(JSON.stringify({ message: 'API key is invalid' }), { status: 401 }));
  await assert.rejects(refusing.send({ to: 'a@b.co', subject: 's', html: 'h', text: 't' }), /401: API key is invalid/);
});

/** A tiny in-process SMTP server that speaks just enough of RFC 5321 to record a delivery. */
function fakeSmtpServer(opts: { starttls?: boolean } = {}) {
  const log: string[] = [];
  let data = '';
  const server = net.createServer((sock) => {
    sock.setEncoding('utf8');
    let inData = false;
    let buf = '';
    sock.write('220 fake.smtp ESMTP ready\r\n');
    sock.on('data', (chunk: string) => {
      buf += chunk;
      if (inData) {
        const end = buf.indexOf('\r\n.\r\n');
        if (end < 0) return;
        data = buf.slice(0, end);
        buf = buf.slice(end + 5);
        inData = false;
        sock.write('250 2.0.0 Ok: queued as ABC123\r\n');
      }
      let i: number;
      while (!inData && (i = buf.indexOf('\r\n')) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 2);
        log.push(line);
        if (/^EHLO/i.test(line)) sock.write(`250-fake.smtp\r\n${opts.starttls ? '250-STARTTLS\r\n' : ''}250-AUTH PLAIN LOGIN\r\n250 8BITMIME\r\n`);
        else if (/^AUTH PLAIN/i.test(line)) sock.write(Buffer.from(line.slice(11), 'base64').toString() === '\0awan\0pw' ? '235 2.7.0 ok\r\n' : '535 bad\r\n');
        else if (/^MAIL FROM/i.test(line) || /^RCPT TO/i.test(line)) sock.write('250 ok\r\n');
        else if (/^DATA/i.test(line)) {
          inData = true;
          sock.write('354 go ahead\r\n');
        } else if (/^QUIT/i.test(line)) {
          sock.write('221 bye\r\n');
          sock.end();
        } else sock.write('502 unknown\r\n');
      }
    });
  });
  return new Promise<{ port: number; log: string[]; data: () => string; close: () => void }>((resolve) =>
    server.listen(0, '127.0.0.1', () => resolve({ port: (server.address() as net.AddressInfo).port, log, data: () => data, close: () => server.close() })),
  );
}

test('SMTP client: full dialogue against a local fake server (AUTH PLAIN, envelope, dot-stuffed base64 body)', async () => {
  const srv = await fakeSmtpServer();
  try {
    const mailer = new SmtpMailer({ host: '127.0.0.1', port: srv.port, user: 'awan', pass: 'pw', from: 'Awan <signin@awan.test>', secure: 'none', timeoutMs: 5000 });
    const email = signInEmail('http://api.test/auth/verify?code=abc');
    const out = await mailer.send({ to: 'Fakhrul <fakhrul@example.com>', ...email });
    assert.equal(out.id, 'ABC123');
    assert.deepEqual(
      srv.log.map((l) => l.split(' ')[0] + (l.startsWith('MAIL') || l.startsWith('RCPT') ? ` ${l.split(':').slice(1).join(':')}` : '')),
      ['EHLO', 'AUTH', 'MAIL <signin@awan.test>', 'RCPT <fakhrul@example.com>', 'DATA', 'QUIT'],
    );
    const raw = srv.data();
    assert.match(raw, /^From: Awan <signin@awan\.test>\r\nTo: Fakhrul <fakhrul@example\.com>\r\nSubject: Your Awan sign-in link\r\n/);
    assert.match(raw, /multipart\/alternative/);
    const b64Parts = [...raw.matchAll(/Content-Transfer-Encoding: base64\r\n\r\n([A-Za-z0-9+/=\r\n]+?)\r\n--/g)].map((m) => Buffer.from(m[1].replace(/\r\n/g, ''), 'base64').toString('utf8'));
    assert.equal(b64Parts.length, 2);
    assert.match(b64Parts[0], /http:\/\/api\.test\/auth\/verify\?code=abc/);
    assert.match(b64Parts[1], /Sign in to Awan/);
  } finally {
    srv.close();
  }
});

test('SMTP client: refuses to send credentials when STARTTLS is required but not offered, or over plaintext to a remote host', async () => {
  const srv = await fakeSmtpServer({ starttls: false });
  try {
    const mailer = new SmtpMailer({ host: '127.0.0.1', port: srv.port, user: 'awan', pass: 'pw', from: 'a@b.co', secure: 'starttls', timeoutMs: 5000 });
    await assert.rejects(mailer.send({ to: 'x@y.co', subject: 's', html: 'h', text: 't' }), /does not offer STARTTLS/);
    assert.ok(!srv.log.some((l) => l.startsWith('AUTH')), 'no AUTH was sent');
  } finally {
    srv.close();
  }
  await assert.rejects(new SmtpMailer({ host: '127.0.0.1', port: 9, from: 'a@b.co', secure: 'none', timeoutMs: 2000 }).send({ to: 'x@y.co', subject: 's', html: 'h', text: 't' }), /Can't reach SMTP server/);
});

test('email formatting: CR/LF in headers is neutralised; non-ASCII subject is RFC 2047', () => {
  const raw = formatEmail('Awan <a@b.co>', { to: 'x@y.co\r\nBcc: evil@z.co', subject: 'Selamat 🎉', html: '<p>hi</p>', text: 'hi' });
  assert.ok(!raw.includes('\r\nBcc:'));
  assert.match(raw, /Subject: =\?UTF-8\?B\?/);
});
