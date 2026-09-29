// Interaction checks: node scripts/interact.mjs [baseUrl] [outDir]
// pricing toggle (spring pill + digits), faq accordion, hero window modal, referral chip,
// mobile menu, waitlist placeholder (must not make any network request on submit), drag.
import { chromium } from 'playwright';
import { resolve } from 'node:path';
const base = process.argv[2] ?? 'http://localhost:5191';
const out = resolve(process.argv[3] ?? '../docs/qa/shots/site');
const results = [];
const ok = (name, pass, detail = '') => results.push(`${pass ? 'PASS' : 'FAIL'} ${name}${detail ? ' — ' + detail : ''}`);
const browser = await chromium.launch();

{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto(base + '/', { waitUntil: 'networkidle' });
  // pricing
  await page.locator('#pricing').scrollIntoViewIfNeeded();
  await page.click('.pr-seg-year');
  await page.waitForTimeout(900);
  const prices = await page.$$eval('.pr-price-sr', (els) => els.map((e) => e.textContent));
  const notes = await page.$$eval('.pr-price-note', (els) => els.map((e) => e.textContent));
  const pill = await page.evaluate(() => { const p = document.getElementById('pr-pill').getBoundingClientRect(); const y = document.querySelector('.pr-seg-year').getBoundingClientRect(); return [Math.round(p.left - y.left), Math.round(p.width - y.width)]; });
  ok('pricing yearly digits', prices.join(',') === '0,16,80', prices.join(','));
  ok('pricing yearly notes', notes[1].includes('yearly'), notes[1]);
  ok('spring pill settles on yearly', Math.abs(pill[0]) <= 1 && Math.abs(pill[1]) <= 1, JSON.stringify(pill));
  await page.screenshot({ path: `${out}/int-pricing-yearly.png` });
  await page.click('.pr-seg:not(.pr-seg-year)');
  await page.waitForTimeout(900);
  ok('pricing back to monthly', (await page.$$eval('.pr-price-sr', (els) => els.map((e) => e.textContent))).join(',') === '0,20,100');
  // faq
  await page.click('#faq-q2');
  await page.waitForTimeout(400);
  const faq = await page.evaluate(() => [...document.querySelectorAll('.faq-item')].map((i) => i.classList.contains('open')));
  ok('faq single open', faq.filter(Boolean).length === 1 && faq[1], JSON.stringify(faq));
  const faqBottom = await page.evaluate(() => { const l = document.querySelector('.faq-list').getBoundingClientRect(); const f = document.querySelector('.footer-links').getBoundingClientRect(); return f.top - l.bottom; });
  ok('faq never reaches footer', faqBottom > 40, `${Math.round(faqBottom)}px gap`);
  // modal
  await page.evaluate(() => scrollTo(0, 0));
  await page.waitForTimeout(300);
  await page.click('[data-modal="home"] .win');
  await page.waitForTimeout(500);
  ok('hero modal opens', await page.isVisible('#hero-modal'), await page.textContent('#hero-modal-title'));
  await page.screenshot({ path: `${out}/int-modal.png` });
  await page.keyboard.press('Escape');
  await page.waitForTimeout(400);
  ok('hero modal closes on escape', !(await page.isVisible('#hero-modal')));
  // drag a sticker
  const tag = page.locator('.m-tag');
  const b0 = await tag.boundingBox();
  await page.mouse.move(b0.x + 20, b0.y + 20);
  await page.mouse.down();
  await page.mouse.move(b0.x + 120, b0.y + 80, { steps: 6 });
  await page.mouse.up();
  const b1 = await tag.boundingBox();
  ok('stickers drag', Math.round(b1.x - b0.x) === 100 && Math.round(b1.y - b0.y) === 60, `${Math.round(b1.x - b0.x)},${Math.round(b1.y - b0.y)}`);
  // demo plays
  await page.click('#demo-play');
  await page.waitForTimeout(4200);
  const demo = await page.getAttribute('#demo', 'class');
  ok('demo timeline runs', /fly/.test(demo) && /played/.test(demo), demo);
  await page.screenshot({ path: `${out}/int-demo.png`, clip: { x: 300, y: 0, width: 840, height: 900 } });
  await page.close();
}
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto(base + '/@fakhrul', { waitUntil: 'networkidle' });
  ok('referral chip', (await page.isVisible('#referral-chip')) && (await page.textContent('#referral-name')) === 'fakhrul');
  const href = await page.getAttribute('.btn.lime', 'href');
  ok('download link carries ref', href.includes('ref=fakhrul'), href);
  await page.screenshot({ path: `${out}/int-referral.png` });
  await page.goto(base + '/?ref=<script>', { waitUntil: 'networkidle' });
  ok('hostile ref ignored (remembered handle kept)', (await page.textContent('#referral-name')) === 'fakhrul' && !(await page.content()).includes('<script>&'));
  await page.close();
}
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const posts = [];
  page.on('request', (r) => { if (r.method() !== 'GET') posts.push(r.url()); });
  await page.goto(base + '/download/?plan=pro', { waitUntil: 'networkidle' });
  await page.fill('#wl-email', 'test@example.com');
  const before = posts.length;
  await page.click('#waitlist button[type=submit]');
  await page.waitForTimeout(400);
  ok('waitlist placeholder sends nothing', posts.length === before && (await page.isVisible('#waitlist-done')), await page.textContent('#waitlist-done'));
  ok('plan note shown', await page.isVisible('#plan-note'));
  await page.screenshot({ path: `${out}/int-download.png` });
  await page.close();
}
{
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  await page.goto(base + '/', { waitUntil: 'networkidle' });
  await page.click('.menu-toggle');
  await page.waitForTimeout(500);
  ok('mobile menu opens', await page.isVisible('#mcc'));
  await page.screenshot({ path: `${out}/int-mobile-menu.png` });
  await page.click('.mcc a[href="/#pricing"]');
  await page.waitForTimeout(500);
  ok('mobile menu closes on nav', await page.isHidden('#mcc'));
  await page.close();
}
await browser.close();
console.log(results.join('\n'));
