// Checks /download against dist/ served like a static host: with an appcast the page shows the
// real download button for the newest DMG (and the link resolves); without one it keeps the waitlist.
//   node scripts/download-check.mjs [out-dir-for-screenshots]
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { chromium } from 'playwright';

const dist = resolve(import.meta.dirname, '../dist');
const out = process.argv[2] ?? '/tmp';
let hideAppcast = false;
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2', '.xml': 'application/xml', '.dmg': 'application/x-apple-diskimage' };
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let file = resolve(dist, '.' + p);
  try {
    if (hideAppcast && p === '/appcast.xml') throw new Error('hidden');
    if ((await stat(file)).isDirectory()) file = resolve(file, 'index.html');
    const s = await stat(file);
    if (req.method === 'HEAD') { res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream', 'content-length': s.size }); return res.end(); }
    res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' });
    res.end(await readFile(file));
  } catch {
    res.writeHead(404, { 'content-type': 'text/html' });
    res.end(await readFile(resolve(dist, '404.html')));
  }
}).listen(5194);

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
await page.goto('http://localhost:5194/download/', { waitUntil: 'networkidle' });
const visible = await page.isVisible('#release');
const href = await page.getAttribute('#release-link', 'href');
console.log('release shown:', visible, '| title:', await page.textContent('#release-title'), '| href:', href, '| meta:', await page.textContent('#release-meta'));
console.log('waitlist hidden:', !(await page.isVisible('#waitlist')), '| heading:', await page.textContent('.ptitle'));
if (href) {
  const r = await page.request.fetch('http://localhost:5194' + href, { method: 'HEAD' });
  console.log('dmg link', r.status(), r.headers()['content-length'], 'bytes');
}
await page.screenshot({ path: `${out}/download-release.png`, fullPage: true });
await page.setViewportSize({ width: 390, height: 844 });
await page.screenshot({ path: `${out}/download-release-phone.png`, fullPage: true });
console.log('phone overflow:', await page.evaluate(() => document.documentElement.scrollWidth > innerWidth));

hideAppcast = true;
await page.setViewportSize({ width: 1280, height: 900 });
await page.goto('http://localhost:5194/download/', { waitUntil: 'networkidle' });
console.log('without appcast → release shown:', await page.isVisible('#release'), '| waitlist shown:', await page.isVisible('#waitlist'));
await page.screenshot({ path: `${out}/download-waitlist.png`, fullPage: true });
await browser.close();
server.close();
