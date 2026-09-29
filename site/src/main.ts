// Shared behaviour for every page: menubar clock, mobile control-centre menu, desktop-canvas zoom,
// scroll reveals, the footer's cloud wordmark, and referral capture.

export const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
export const $ = <T extends Element = HTMLElement>(sel: string, root: ParentNode = document) => root.querySelector(sel) as T | null;
export const $$ = <T extends Element = HTMLElement>(sel: string, root: ParentNode = document) => Array.from(root.querySelectorAll(sel)) as T[];

// ------------------------------------------------------------------ storage (never trusted to exist)
function store(key: string, value?: string): string | null {
  try {
    if (value === undefined) return localStorage.getItem(key);
    localStorage.setItem(key, value);
  } catch {
    /* private mode or blocked storage: the page works without it */
  }
  return null;
}

// ------------------------------------------------------------------ clock (tabular, like the reference's status clock)
function tick() {
  const t = new Date().toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  for (const el of $$('#clock, #mcc-clock')) el.textContent = t;
}
tick();
setInterval(tick, 15_000);

// ------------------------------------------------------------------ 1024–1439: zoom the 1440 canvas to the viewport
function fitZoom() {
  const w = document.documentElement.clientWidth;
  const z = w >= 1024 && w < 1440 ? w / 1440 : 1;
  document.documentElement.style.setProperty('--z', String(z));
}
fitZoom();
addEventListener('resize', fitZoom);

// ------------------------------------------------------------------ mobile control-centre menu
const toggle = $<HTMLButtonElement>('.menu-toggle');
const mcc = $('#mcc');
function setMenu(open: boolean) {
  if (!toggle || !mcc) return;
  toggle.setAttribute('aria-expanded', String(open));
  toggle.setAttribute('aria-label', open ? 'close menu' : 'open menu');
  document.documentElement.classList.toggle('nav-open', open);
  if (open) {
    mcc.hidden = false;
    requestAnimationFrame(() => requestAnimationFrame(() => mcc.classList.add('open')));
  } else {
    mcc.classList.remove('open');
    setTimeout(() => { if (!mcc.classList.contains('open')) mcc.hidden = true; }, reducedMotion ? 0 : 260);
  }
}
toggle?.addEventListener('click', () => setMenu(toggle.getAttribute('aria-expanded') !== 'true'));
mcc?.addEventListener('click', (e) => { if ((e.target as Element).closest('a')) setMenu(false); });
addEventListener('keydown', (e) => { if (e.key === 'Escape' && toggle?.getAttribute('aria-expanded') === 'true') { setMenu(false); toggle.focus(); } });
matchMedia('(min-width: 1024px)').addEventListener('change', (m) => { if (m.matches) setMenu(false); });

// ------------------------------------------------------------------ reveal on scroll (resting state is visible; JS only animates to it)
export function observeReveals(root: ParentNode = document) {
  const els = $$('.reveal', root);
  if (!els.length) return;
  if (reducedMotion || !('IntersectionObserver' in window)) { els.forEach((el) => el.classList.add('rvg-in')); return; }
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add('rvg-in'); io.unobserve(e.target); }
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });
  els.forEach((el) => io.observe(el));
  // failsafe: never leave anything hidden (throttled tabs, odd scroll containers)
  setTimeout(() => els.forEach((el) => el.classList.add('rvg-in')), 4000);
}
observeReveals();

// ------------------------------------------------------------------ footer wordmark: "hai awan" in a 5-row pixel face, one little cloud per pixel
const GLYPHS: Record<string, string[]> = {
  a: ['.###.', '....#', '.####', '#...#', '.####'],
  w: ['#...#', '#...#', '#.#.#', '#.#.#', '.#.#.'],
  n: ['####.', '#...#', '#...#', '#...#', '#...#'],
  h: ['#....', '#....', '####.', '#...#', '#...#'],
  i: ['#', '.', '#', '#', '#'],
  ' ': ['..', '..', '..', '..', '..'],
};
const CLOUD_TONES = ['#91cefa', '#86c5f5', '#9dd3fb', '#7fbef0', '#a6d8fb'];
function buildWordmark() {
  const mark = $('#footer-mark');
  if (!mark || mark.childElementCount) return;
  const word = 'hai awan';
  const starts: number[] = [];
  let cols = 0;
  for (const ch of word) { starts.push(cols); cols += GLYPHS[ch][0].length + 1; }
  cols -= 1;
  const W = 1139, H = 262, cell = Math.min(48, W / cols);
  const k = cell / 48; // tiles were drawn for a 48px cell
  const offX = (W - cols * cell) / 2, offY = (H - 5 * cell) / 2;
  let rnd = 7;
  const r = () => ((rnd = (rnd * 16807) % 2147483647) / 2147483647);
  const frag = document.createDocumentFragment();
  let n = 0;
  [...word].forEach((ch, li) => {
    GLYPHS[ch].forEach((row, y) => {
      [...row].forEach((px, x) => {
        if (px !== '#') return;
        const cx = offX + (starts[li] + x) * cell + (r() - 0.5) * 6 * k;
        const cy = offY + y * cell + (r() - 0.5) * 6 * k;
        const tile = document.createElement('span');
        tile.className = 'tile';
        tile.style.left = `${((cx - k) / W) * 100}%`;
        tile.style.top = `${((cy + 6 * k) / H) * 100}%`;
        tile.style.width = `${((50 * k) / W) * 100}%`;
        tile.style.height = `${((35 * k) / H) * 100}%`;
        tile.style.setProperty('--r', `${((r() - 0.5) * 10).toFixed(1)}deg`);
        tile.style.setProperty('--d', `${(n * 0.012).toFixed(3)}s`);
        tile.style.color = CLOUD_TONES[Math.floor(r() * CLOUD_TONES.length)];
        tile.innerHTML = '<svg viewBox="0 0 100 70" aria-hidden="true"><use href="#i-cloud" fill="currentColor"/><use href="#i-eyes" color="#fff"/></svg>';
        frag.append(tile);
        n++;
      });
    });
  });
  mark.append(frag);
}
buildWordmark();
const footer = $('#footer');
if (footer) {
  if (reducedMotion || !('IntersectionObserver' in window)) footer.classList.add('revealed');
  else {
    const io = new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) { footer.classList.add('revealed'); io.disconnect(); } }, { threshold: 0.2 });
    io.observe(footer);
    setTimeout(() => footer.classList.add('revealed'), 6000);
  }
}

// ------------------------------------------------------------------ referrals: awan.ffdev.studio/@handle or ?ref=handle, remembered 60 days
const HANDLE = /^[a-z0-9_.-]{1,32}$/i;
const REF_DAYS = 60;
export function referralFromUrl(): string | null {
  const m = location.pathname.match(/^\/@([^/]+)\/?$/);
  const raw = m ? decodeURIComponent(m[1]) : new URLSearchParams(location.search).get('ref');
  return raw && HANDLE.test(raw) ? raw.toLowerCase() : null;
}
export function currentReferral(): string | null {
  const fresh = referralFromUrl();
  if (fresh) {
    store('awan_ref', JSON.stringify({ h: fresh, t: Date.now() }));
    return fresh;
  }
  try {
    const saved = JSON.parse(store('awan_ref') ?? 'null') as { h: string; t: number } | null;
    if (saved && HANDLE.test(saved.h) && Date.now() - saved.t < REF_DAYS * 864e5) return saved.h;
  } catch { /* ignore */ }
  return null;
}
const ref = currentReferral();
if (ref) {
  for (const a of $$<HTMLAnchorElement>('a[data-ref-link], a[href^="/download/"]')) {
    const u = new URL(a.getAttribute('href') ?? '/download/', location.origin);
    u.searchParams.set('ref', ref);
    a.setAttribute('href', u.pathname + u.search + u.hash);
  }
}
