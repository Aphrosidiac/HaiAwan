// Ad-hoc probe: node scripts/probe.mjs <url> <width> "<js expression>" [scrollToSelector]
import { chromium } from 'playwright';
const [url, w, expr, sel] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: Number(w), height: 844 } });
page.on('console', (m) => console.log('console:', m.text()));
await page.goto(url, { waitUntil: 'networkidle' });
if (sel) { await page.locator(sel).first().scrollIntoViewIfNeeded(); await page.waitForTimeout(1500); }
console.log(JSON.stringify(await page.evaluate(expr), null, 1));
await browser.close();
