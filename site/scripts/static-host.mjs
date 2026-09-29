// Checks dist/ the way a plain static host serves it (Cloudflare Pages style): directory
// index.html, unknown paths get 404.html with a 404 status. Verifies the /@handle fallback.
//   node scripts/static-host.mjs
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { chromium } from 'playwright';

const dist = resolve(import.meta.dirname, '../dist');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.webp': 'image/webp', '.woff2': 'font/woff2', '.xml': 'application/xml', '.txt': 'text/plain', '.webmanifest': 'application/manifest+json' };
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let file = resolve(dist, '.' + p);
  try { if ((await stat(file)).isDirectory()) file = resolve(file, 'index.html'); await stat(file); res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' }); }
  catch { file = resolve(dist, '404.html'); res.writeHead(404, { 'content-type': 'text/html' }); }
  res.end(await readFile(file));
}).listen(5193);

const browser = await chromium.launch();
const page = await browser.newPage();
const r404 = await page.goto('http://localhost:5193/does-not-exist');
console.log('unknown path status', r404.status(), await page.title());
await page.goto('http://localhost:5193/@aina', { waitUntil: 'networkidle' });
await page.waitForTimeout(500);
console.log('referral landing url', new URL(page.url()).pathname + new URL(page.url()).search, '| chip:', await page.isVisible('#referral-chip'), await page.textContent('#referral-name'), '| title:', await page.title());
for (const p of ['/robots.txt', '/sitemap.xml', '/llms.txt', '/og.png', '/changelog.xml', '/favicon.svg', '/site.webmanifest']) {
  const r = await page.request.get('http://localhost:5193' + p);
  console.log(p, r.status());
}
await browser.close();
server.close();
