// Renders public/og.png (1200×630) from brand assets: node scripts/og.mjs
import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';

const pub = resolve(import.meta.dirname, '../public');
const f = (p) => pathToFileURL(resolve(pub, p)).href;
const cloud = `<ellipse cx="22" cy="42" rx="21" ry="15.4"/><ellipse cx="36" cy="28" rx="23" ry="16.9"/><ellipse cx="56" cy="23.1" rx="25" ry="18.4"/><ellipse cx="76" cy="33.6" rx="21" ry="15.4"/><ellipse cx="84" cy="44.8" rx="16" ry="11.8"/><ellipse cx="14" cy="50.4" rx="14" ry="10.3"/><ellipse cx="50" cy="46.2" rx="30" ry="22"/><rect x="8" y="36.4" width="84" height="25.2" rx="11.2"/>`;
const eyes = `<path d="M35.8 45 41 39.4l5.2 5.6M53.8 45 59 39.4l5.2 5.6" fill="none" stroke="#fff" stroke-width="4.4" stroke-linecap="round" stroke-linejoin="round"/>`;
const html = `<!doctype html><html><head><style>
@font-face { font-family: IS; src: url(${f('fonts/InstrumentSans-Variable.woff2')}); font-weight: 400 700; }
@font-face { font-family: ISerif; src: url(${f('fonts/InstrumentSerif-Italic.woff2')}); font-style: italic; }
* { margin: 0; box-sizing: border-box; }
body { width: 1200px; height: 630px; background: #F3EFE4; font-family: IS; color: #0B0B0A; position: relative; overflow: hidden;
  background-image: radial-gradient(rgb(11 11 10 / .14) 1px, transparent 1.3px); background-size: 34.238px 34px; }
.h { position: absolute; left: 0; right: 0; top: 196px; text-align: center; font-size: 148px; font-weight: 500; letter-spacing: -4.4px; line-height: 1; }
.s { position: absolute; left: 0; right: 0; top: 368px; text-align: center; font-size: 34px; letter-spacing: -1px; }
.pill { position: absolute; left: 50%; top: 440px; translate: -50% 0; height: 58px; padding: 0 30px; border-radius: 999px; display: flex; align-items: center; gap: 12px;
  font-size: 26px; font-weight: 500; letter-spacing: -.7px; border: 1.5px solid #0B0B0A; background: linear-gradient(#f5ffcf, #ebff95 18%, #d9ff43 50%, #cff53c 80%, #dbfb63); box-shadow: 0 14px 30px rgb(11 11 10 / .14); }
.icon { position: absolute; left: 86px; top: 70px; width: 150px; rotate: -8deg; filter: drop-shadow(0 16px 24px rgb(11 11 10 / .22)); }
.c { position: absolute; fill: #91cefa; filter: drop-shadow(0 4px 4px rgb(11 11 10 / .14)); }
.tag { position: absolute; right: 84px; top: 86px; rotate: 6deg; background: #fff; border-radius: 6px; overflow: hidden; width: 170px; box-shadow: 0 6px 16px rgb(11 11 10 / .18); }
.tag .hd { background: #0B0B0A; color: #F3EFE4; text-align: center; padding: 6px; font-size: 13px; font-weight: 700; letter-spacing: 1px; line-height: 1.1; }
.tag .hd small { display: block; font-weight: 500; font-size: 10px; letter-spacing: 0; }
.tag .bd { height: 64px; display: grid; place-items: center; font-family: ISerif; font-style: italic; font-size: 42px; }
.tag .ft { height: 14px; background: #0B0B0A; }
.ff { position: absolute; right: 70px; bottom: 50px; width: 190px; }
.kbd { position: absolute; left: 110px; bottom: 70px; display: flex; gap: 10px; rotate: -4deg; }
.kbd b { width: 70px; height: 70px; border-radius: 15px; border: 1.5px solid #c9c3b5; background: linear-gradient(#fffdf8, #ebe6da); box-shadow: inset 0 -4px 0 #d6d0c2, 0 8px 18px rgb(11 11 10 / .14); display: grid; place-items: center; font-size: 30px; font-weight: 500; }
</style></head><body>
<img class="icon" src="${f('img/app-icon-512.png')}">
<svg class="c" viewBox="0 0 100 70" style="left:930px;top:250px;width:120px">${cloud}${eyes}</svg>
<svg class="c" viewBox="0 0 100 70" style="left:170px;top:300px;width:80px;fill:#fab5a0">${cloud}${eyes}</svg>
<div class="tag"><div class="hd">HAI<small>nama saya</small></div><div class="bd">awan</div><div class="ft"></div></div>
<div class="h">hai awan</div>
<div class="s">a little cloud that lives on your mac</div>
<div class="pill">hold ⌃ ⌥ and just ask &nbsp;·&nbsp; open source</div>
<div class="kbd"><b>⌃</b><b>⌥</b></div>
<img class="ff" src="${f('img/ff-lockup-horizontal-ink.svg')}">
</body></html>`;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 } });
// file:// page so the local fonts and images load
const tmp = resolve(mkdtempSync(resolve(tmpdir(), 'awan-og-')), 'og.html');
writeFileSync(tmp, html);
await page.goto(pathToFileURL(tmp).href, { waitUntil: 'load' });
await page.evaluate(() => document.fonts.ready);
await page.waitForTimeout(200);
await page.screenshot({ path: resolve(pub, 'og.png') });
await browser.close();
console.log('wrote public/og.png');
