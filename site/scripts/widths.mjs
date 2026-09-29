// Horizontal-overflow sweep across widths + a top-of-page capture per width, and a reduced-motion pass.
//   node scripts/widths.mjs [baseUrl] [outDir]
import { chromium } from 'playwright';
import { resolve } from 'node:path';
const base = process.argv[2] ?? 'http://localhost:5192';
const out = resolve(process.argv[3] ?? '../docs/qa/shots/site');
const widths = [320, 375, 768, 1024, 1280, 1920];
const pages = ['/', '/changelog/', '/trust/', '/privacy/', '/download/', '/terms/', '/referral-terms/'];
const browser = await chromium.launch();
for (const w of widths) {
  const page = await browser.newPage({ viewport: { width: w, height: 900 } });
  const bad = [];
  for (const p of pages) {
    await page.goto(base + p, { waitUntil: 'networkidle' });
    // html/body use overflow-x: clip, which hides overflow from scrollWidth — lift it to measure honestly
    const r = await page.evaluate(() => { const s = document.createElement('style'); s.textContent = 'html,body{overflow-x:visible!important}'; document.head.append(s); const v = [document.documentElement.scrollWidth, document.documentElement.clientWidth]; s.remove(); return v; });
    if (r[0] > r[1] + 1) bad.push(`${p} ${r[0]}>${r[1]}`);
    if (p === '/') await page.screenshot({ path: `${out}/width-${w}.png` });
  }
  console.log(w, bad.length ? bad.join('; ') : 'no horizontal overflow');
  await page.close();
}
const rm = await browser.newPage({ viewport: { width: 1440, height: 900 }, reducedMotion: 'reduce' });
await rm.goto(base + '/', { waitUntil: 'networkidle' });
const hidden = await rm.evaluate(() => [...document.querySelectorAll('.reveal, .hero > .abs, .manifesto p')].filter((e) => getComputedStyle(e).opacity === '0').length);
await rm.evaluate(() => document.getElementById('big-video').scrollIntoView({ block: 'center' }));
await rm.waitForTimeout(300);
await rm.screenshot({ path: `${out}/reduced-motion-demo.png` });
console.log('reduced motion: elements at opacity 0 =', hidden);
await browser.close();
