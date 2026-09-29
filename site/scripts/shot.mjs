// One viewport capture: node scripts/shot.mjs <url> <width> <scrollY> <out.png> [waitMs] [height]
import { chromium } from 'playwright';
const [url, w, y, out, wait = '1500', h = '900'] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: Number(w), height: Number(h) } });
await page.goto(url, { waitUntil: 'networkidle' });
await page.evaluate(() => document.fonts.ready);
await page.evaluate((yy) => scrollTo(0, yy), Number(y));
await page.waitForTimeout(Number(wait));
await page.screenshot({ path: out });
await browser.close();
