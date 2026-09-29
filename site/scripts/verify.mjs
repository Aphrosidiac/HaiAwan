// Headless verification for the Awan site.
//   node scripts/verify.mjs [baseUrl] [outDir]
// For every page at 1440 and 390: step-scroll (drives reveals), full-page capture, horizontal-overflow
// check with the widest offenders, console errors, and a status check of every internal link.
// Home also gets 800px-step viewport captures at 1440 (the reference's home-s00..s09 cadence).
import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

const base = process.argv[2] ?? 'http://localhost:5191';
const out = resolve(process.argv[3] ?? '../docs/qa/shots/site');
mkdirSync(out, { recursive: true });

const pages = ['/', '/changelog/', '/trust/', '/privacy/', '/terms/', '/referral-terms/', '/download/', '/@fakhrul', '/nope-404'];
const widths = [1440, 390];
const report = { overflow: [], console: [], links: {}, meta: [] };

const browser = await chromium.launch();
const seen = new Set();
for (const w of widths) {
  const ctx = await browser.newContext({ viewport: { width: w, height: w > 600 ? 900 : 844 }, deviceScaleFactor: 1, reducedMotion: 'no-preference' });
  for (const path of pages) {
    const page = await ctx.newPage();
    page.on('console', (m) => { if (m.type() === 'error') report.console.push(`${w} ${path}: ${m.text()}`); });
    page.on('pageerror', (e) => report.console.push(`${w} ${path}: ${e.message}`));
    await page.goto(base + path, { waitUntil: 'networkidle' });
    await page.evaluate(() => document.fonts.ready);
    // step-scroll to fire observers, then back to top
    const H = await page.evaluate(() => document.documentElement.scrollHeight);
    for (let y = 0; y < H; y += 600) { await page.evaluate((yy) => scrollTo(0, yy), y); await page.waitForTimeout(90); }
    await page.waitForTimeout(4200);
    const name = (path === '/' ? 'home' : path.replace(/[/@]/g, (c) => (c === '@' ? 'at-' : '')).replace(/-$/, '') || 'home') + `-${w}`;
    if (path === '/' && w === 1440) {
      for (let i = 0; i < 10; i++) {
        await page.evaluate((yy) => scrollTo(0, yy), i * 800);
        await page.waitForTimeout(i === 1 || i === 2 ? 2600 : 900);
        await page.screenshot({ path: `${out}/home-s${String(i).padStart(2, '0')}.png` });
      }
    }
    await page.evaluate(() => scrollTo(0, 0));
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${out}/${name}-full.png`, fullPage: true });
    const ov = await page.evaluate(() => {
      const de = document.documentElement;
      // html/body use overflow-x: clip, which hides overflow from scrollWidth — lift it to measure honestly
      const lift = document.createElement('style'); lift.textContent = 'html,body{overflow-x:visible!important}'; document.head.append(lift);
      const vw = de.clientWidth;
      const offenders = [];
      if (de.scrollWidth > vw + 1) {
        for (const el of document.querySelectorAll('body *')) {
          const r = el.getBoundingClientRect();
          if (r.width && r.right > vw + 1 && getComputedStyle(el).position !== 'fixed') offenders.push(`${el.tagName.toLowerCase()}.${[...el.classList].join('.')} right=${Math.round(r.right)}`);
          if (offenders.length > 8) break;
        }
      }
      const sw = de.scrollWidth; lift.remove();
      return { scrollWidth: sw, vw, offenders };
    });
    if (ov.scrollWidth > ov.vw + 1) report.overflow.push({ w, path, ...ov });
    const meta = await page.evaluate(() => ({
      title: document.title,
      desc: document.querySelector('meta[name=description]')?.content?.length ?? 0,
      canonical: document.querySelector('link[rel=canonical]')?.href ?? null,
      og: !!document.querySelector('meta[property="og:image"]'),
      h1: document.querySelectorAll('h1').length,
      imgsNoAlt: [...document.images].filter((i) => !i.hasAttribute('alt')).length,
    }));
    if (w === 1440) report.meta.push({ path, ...meta });
    const hrefs = await page.evaluate(() => [...document.querySelectorAll('a[href]')].map((a) => a.getAttribute('href')));
    for (const h of hrefs) {
      if (!h || h.startsWith('mailto:') || h.startsWith('http') || seen.has(h)) continue;
      seen.add(h);
      const url = new URL(h, base + path);
      const res = await page.request.get(url.href);
      const hashOk = url.hash ? await page.request.get(url.origin + url.pathname).then((r) => r.text()).then((t) => t.includes(`id="${url.hash.slice(1)}"`)) : true;
      report.links[h] = `${res.status()}${hashOk ? '' : ' (missing #anchor)'}`;
    }
    await page.close();
  }
  await ctx.close();
}
await browser.close();
console.log(JSON.stringify(report, null, 2));
