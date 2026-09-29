import { $, $$, reducedMotion, currentReferral, observeReveals } from './main';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const narrow = () => document.documentElement.clientWidth < 1024;

// ------------------------------------------------------------------ referral chip ("fakhrul gave you 25% off")
{
  const ref = currentReferral();
  const chip = $('#referral-chip');
  if (ref && chip) {
    $('#referral-name')!.textContent = ref;
    $('#referral-av')!.textContent = ref[0];
    chip.hidden = false;
    // the static host forwards /@handle → /?ref=handle; show the pretty URL again
    if (!location.pathname.startsWith('/@') && new URLSearchParams(location.search).get('from') === '404') {
      history.replaceState(null, '', `/@${ref}`);
    }
    if (location.pathname.startsWith('/@')) document.title = `${ref} invited you to Awan`;
  }
}

// ------------------------------------------------------------------ mobile zoom factors for the px-built scenes
function fitScenes() {
  const w = document.documentElement.clientWidth;
  const demoW = Math.min(353, w - 32);
  document.documentElement.style.setProperty('--dk', String(demoW / 800));
  document.documentElement.style.setProperty('--fz', String((w - 40) / 706));
}
fitScenes();
addEventListener('resize', fitScenes);

// ------------------------------------------------------------------ draggable desktop items (desktop pointer only)
if (matchMedia('(hover: hover) and (pointer: fine)').matches) {
  const hero = $('.hero')!;
  let z = 30;
  const makeDraggable = (el: HTMLElement, handle: HTMLElement) => {
    handle.addEventListener('pointerdown', (e) => {
      if (e.button !== 0 || narrow()) return;
      const sx = e.clientX, sy = e.clientY;
      const zoom = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--z')) || 1;
      const x0 = el.offsetLeft, y0 = el.offsetTop;
      let moved = false;
      const move = (ev: PointerEvent) => {
        const dx = (ev.clientX - sx) / zoom, dy = (ev.clientY - sy) / zoom;
        if (!moved && Math.hypot(dx, dy) < 5) return;
        if (!moved) { moved = true; el.classList.add('dragging'); el.style.zIndex = String(++z); handle.setPointerCapture(e.pointerId); }
        const nx = Math.max(-40, Math.min(hero.clientWidth - 40, x0 + dx));
        const ny = Math.max(-20, Math.min(hero.clientHeight - 40, y0 + dy));
        el.style.left = `${nx}px`;
        el.style.top = `${ny}px`;
      };
      const up = () => {
        removeEventListener('pointermove', move);
        removeEventListener('pointerup', up);
        el.classList.remove('dragging');
        if (moved) {
          // swallow the click that follows a drag
          const stop = (ce: Event) => { ce.stopPropagation(); ce.preventDefault(); };
          el.addEventListener('click', stop, { capture: true, once: true });
          setTimeout(() => el.removeEventListener('click', stop, { capture: true }), 0);
        }
      };
      addEventListener('pointermove', move);
      addEventListener('pointerup', up);
    });
  };
  $$('.hero .draggable').forEach((el) => makeDraggable(el, el));
  $$('.hero .vidwin').forEach((el) => makeDraggable(el, el.querySelector('.win') as HTMLElement));
}

// ------------------------------------------------------------------ hero windows open in a modal
{
  const modal = $('#hero-modal')!;
  const screen = $('#hero-modal-screen')!;
  const title = $('#hero-modal-title')!;
  let opener: HTMLElement | null = null;
  const close = () => {
    if (modal.hidden) return;
    modal.classList.add('closing');
    setTimeout(() => { modal.hidden = true; modal.classList.remove('closing'); screen.innerHTML = ''; opener?.focus(); }, reducedMotion ? 0 : 200);
  };
  const open = (wrap: HTMLElement) => {
    const win = wrap.querySelector('.win') as HTMLElement;
    const src = wrap.querySelector('.screen') as HTMLElement;
    opener = win;
    title.textContent = wrap.querySelector('.win-caption')?.textContent ?? '';
    screen.innerHTML = '';
    const img = src.querySelector('img');
    if (img) {
      const big = document.createElement('img');
      big.src = img.src;
      big.alt = img.alt;
      screen.append(big);
    } else {
      // scale the little css scene up to the modal
      const w = src.offsetWidth, h = src.offsetHeight;
      const host = document.createElement('div');
      host.className = 'mini-host';
      const maxW = Math.min(900, innerWidth - 60), maxH = innerHeight - 140;
      const k = Math.min(maxW / w, maxH / h);
      host.style.width = `${w}px`;
      host.style.height = `${h}px`;
      host.style.zoom = String(k);
      host.innerHTML = src.innerHTML;
      screen.append(host);
    }
    modal.hidden = false;
    (modal.querySelector('.hm-close') as HTMLElement).focus();
  };
  $$('.hero .vidwin').forEach((wrap) => wrap.querySelector('.win')!.addEventListener('click', () => open(wrap)));
  modal.addEventListener('click', (e) => { if ((e.target as Element).closest('[data-close]')) close(); });
  addEventListener('keydown', (e) => {
    if (modal.hidden) return;
    if (e.key === 'Escape') close();
    if (e.key === 'Tab') { e.preventDefault(); (modal.querySelector('.hm-close') as HTMLElement).focus(); }
  });
}

// ------------------------------------------------------------------ the big demo window (a scripted scene in place of a film)
{
  const demo = $('#demo')!;
  const sub = $('.demo-sub', demo)!;
  const askTxt = $('.da-txt', demo)!;
  const play = $('#demo-play')!;
  const ASK = 'what happened in week 9?';
  let run = 0;
  let visible = false;
  const setSub = (t: string) => { sub.classList.remove('on'); if (t) setTimeout(() => { sub.textContent = t; sub.classList.add('on'); }, 180); };
  const reset = () => { demo.className = 'demo' + (demo.classList.contains('played') ? ' played' : ''); askTxt.textContent = ''; };
  const cls = (...c: string[]) => demo.classList.add(...c);
  const rm = (...c: string[]) => demo.classList.remove(...c);
  async function loop(id: number) {
    const alive = () => id === run;
    while (alive()) {
      if (!visible) { await sleep(400); continue; }
      reset();
      await sleep(700); if (!alive()) return;
      cls('keys', 'listen'); setSub('hold control + option, and just ask.');
      await sleep(800); if (!alive()) return;
      cls('ask', 'typing');
      for (let i = 1; i <= ASK.length; i++) { askTxt.textContent = ASK.slice(0, i); await sleep(55); if (!alive()) return; }
      rm('typing');
      await sleep(500); if (!alive()) return;
      rm('keys', 'listen'); cls('think', 'fly');
      await sleep(1100); if (!alive()) return;
      cls('ring');
      await sleep(700); if (!alive()) return;
      cls('reply'); setSub('awan sees your screen, then points at the answer.');
      await sleep(3200); if (!alive()) return;
      rm('think', 'ask'); cls('agent'); setSub('say “awan, agent” and it goes off and does the work.');
      await sleep(4200); if (!alive()) return;
      await sleep(900);
    }
  }
  const start = () => { run++; loop(run); };
  if (reducedMotion) {
    // resting composition: the answer, pointed at, no loop
    demo.classList.add('ask', 'fly', 'ring', 'reply');
    askTxt.textContent = ASK;
    sub.textContent = 'awan sees your screen, then points at the answer.';
    sub.classList.add('on');
  } else {
    new IntersectionObserver((es) => { visible = es.some((e) => e.isIntersecting); }, { threshold: 0.25 }).observe(demo);
    start();
  }
  play.addEventListener('click', () => { demo.classList.add('played'); if (!reducedMotion) { visible = true; start(); } });
  $('#watch-demo')?.addEventListener('click', (e) => {
    e.preventDefault();
    $('#big-video')!.scrollIntoView({ behavior: reducedMotion ? 'auto' : 'smooth', block: 'center' });
    demo.classList.add('played');
    if (!reducedMotion) { visible = true; start(); }
  });
}

// ------------------------------------------------------------------ feature scenes: fill the spreadsheet and the import table
{
  const grid = $('.ss-grid');
  if (grid) {
    const rows = [['', 'A', 'B', 'C', 'D', 'E', 'F'], ['1', 'item', 'jul', 'aug', 'sep', 'owner', 'notes']];
    const items = [['rent', 2400, 2400, 2400], ['kopi & snacks', 186, 204, 171], ['software', 312, 312, 348], ['ads', 900, 1250, 1100], ['freelance help', 1500, 0, 800], ['travel', 420, 95, 610], ['hardware', 0, 2199, 0], ['internet', 149, 149, 149]];
    const owners = ['fakhrul', 'aina', 'fakhrul', 'wei jie', 'aina', 'fakhrul', 'wei jie', 'aina'];
    items.forEach((it, i) => rows.push([String(i + 2), String(it[0]), ...it.slice(1).map((n) => (n as number).toLocaleString('en-US')), owners[i], '']));
    rows.push(['10', 'total', '', '', '', '', '']);
    grid.innerHTML = rows.map((r, ri) => r.map((c, ci) => {
      const cls = ri === 0 || ci === 0 ? 'h' : ci === 1 ? 'lbl' : '';
      const b = ci === 2 && ri > 1 ? ' colb' : '';
      const total = ri === rows.length - 1 && ci === 2 ? ' total' : '';
      return `<span class="${cls}${b}${total}">${c}</span>`;
    }).join('')).join('');
  }
  const table = $('.si-table');
  if (table) {
    const data = [['aina r.', '03/09/2026', '1,240.00', 'paid'], ['kedai runcit maju', '2026-09-04', '88.50', 'paid'], ['wei jie', 'sept 5', '420.00', 'due'], ['priya s.', '09/06/26', '2,015.00', 'paid'], ['studio hafiz', '7th sep', '310.00', 'due'], ['nurul a.', '2026/09/08', '95.00', 'paid'], ['mei tan', '9/9', '1,100.00', 'paid'], ['daniel k.', 'tuesday', '64.90', 'due']];
    table.insertAdjacentHTML('beforeend', data.map((r) => `<div class="si-row"><span>${r[0]}</span><span class="bad">${r[1]}</span><span>${r[2]}</span><span>${r[3]}</span></div>`).join(''));
  }
}

// ------------------------------------------------------------------ feature rows: the row nearest the viewport centre speaks; the others dim
{
  const rows = $$('.feat-row');
  const WAVE_REST = [8, 8, 14, 8, 20, 8, 8, 26, 8, 14, 8];
  rows.forEach((row) => $$('.wbars i', row).forEach((b, i) => b.style.setProperty('--h', `${WAVE_REST[i]}px`)));
  const played = new WeakMap<HTMLElement, number>();
  let active: HTMLElement | null = null;
  let token = 0;

  async function speak(row: HTMLElement) {
    const id = ++token;
    const txt = $('.feat-bubble.req .txt', row)!;
    const ask = row.dataset.ask ?? '';
    const bars = $$('.wbars i', row);
    row.classList.remove('replied', 'pointing');
    if (reducedMotion) { txt.textContent = ask; row.classList.add('replied', 'pointing'); return; }
    row.classList.add('speaking', 'typing');
    txt.textContent = '';
    const wave = setInterval(() => bars.forEach((b, i) => b.style.setProperty('--h', `${8 + Math.round(Math.random() * (i % 3 === 0 ? 20 : 14))}px`)), 110);
    for (let i = 1; i <= ask.length; i++) {
      if (id !== token) break;
      txt.textContent = ask.slice(0, i);
      await sleep(ask[i - 1] === ' ' ? 70 : 42);
    }
    clearInterval(wave);
    bars.forEach((b, i) => b.style.setProperty('--h', `${WAVE_REST[i]}px`));
    row.classList.remove('typing', 'speaking');
    if (id !== token) { txt.textContent = ask; return; }
    await sleep(350);
    if (id !== token) return;
    row.classList.add('pointing');
    await sleep(900);
    if (id === token) row.classList.add('replied');
    if (row.querySelector('.ss-formula')) {
      const f = $('.ss-formula', row)!;
      const formula = '=SUM(B2:B9)';
      await sleep(900);
      for (let i = 1; i <= formula.length && id === token; i++) { f.textContent = formula.slice(0, i); await sleep(60); }
      const total = $('.ss-grid .total', row);
      if (total && id === token) total.textContent = '5,867';
    }
  }

  function pick() {
    const mid = innerHeight / 2;
    let best: HTMLElement | null = null;
    let bestD = Infinity;
    for (const row of rows) {
      const r = row.getBoundingClientRect();
      const d = Math.abs(r.top + r.height / 2 - mid);
      if (d < bestD) { bestD = d; best = row; }
    }
    const sec = $('#features')!.getBoundingClientRect();
    const inSection = sec.top < innerHeight * 0.85 && sec.bottom > innerHeight * 0.15;
    if (!inSection) best = null;
    rows.forEach((row) => row.classList.toggle('dimmed', !!best && row !== best && !reducedMotion));
    if (best && best !== active) {
      active = best;
      const last = played.get(best) ?? 0;
      if (Date.now() - last > 1500) { played.set(best, Date.now()); speak(best); }
    }
    if (!best) active = null;
  }
  let raf = 0;
  addEventListener('scroll', () => { if (!raf) raf = requestAnimationFrame(() => { raf = 0; pick(); }); }, { passive: true });
  addEventListener('resize', pick);
  pick();
}

// ------------------------------------------------------------------ the idea: two arcs of little clouds, and the notes typing out
{
  const arches = $('#man-arches');
  if (arches) {
    const tones = { left: ['#c0a0eb', '#b39bef', '#d7a4dc', '#f7a3c6', '#f5a9b8', '#fab5a0'], right: ['#88db96', '#9ddc84', '#bfe07a', '#fae371', '#f8c96b', '#f7b16f'] };
    const frag = document.createDocumentFragment();
    const addArc = (cx: number, cy: number, r: number, a0: number, a1: number, colors: string[], step: number) => {
      const n = Math.max(2, Math.round((Math.abs(a1 - a0) * Math.PI / 180 * r) / step));
      for (let i = 0; i <= n; i++) {
        const t = i / n;
        const a = ((a0 + (a1 - a0) * t) * Math.PI) / 180;
        const x = cx + Math.cos(a) * r - 32, y = cy - Math.sin(a) * r - 22;
        if (y > 700 || y < 96) continue;
        const tile = document.createElement('span');
        tile.className = 'arc-tile reveal';
        tile.style.left = `${x}px`;
        tile.style.top = `${y}px`;
        tile.style.setProperty('--rd', `${(t * 0.5).toFixed(2)}s`);
        tile.style.color = colors[Math.min(colors.length - 1, Math.floor(t * colors.length))];
        tile.style.rotate = `${(((a1 - a0) > 0 ? -1 : 1) * (1 - t) * 10).toFixed(1)}deg`;
        tile.innerHTML = '<svg viewBox="0 0 100 70"><use href="#i-cloud" fill="currentColor"/></svg>';
        frag.append(tile);
      }
    };
    // two concentric rainbows behind the notes window, only their outer legs visible
    // two concentric rainbow arches rising from behind the notes window; only the outer legs show
    addArc(720, 560, 400, 128, 186, tones.left, 30);
    addArc(720, 560, 400, 52, -6, tones.right, 30);
    addArc(720, 560, 600, 134, 186, tones.left.slice().reverse(), 32);
    addArc(720, 560, 600, 46, -6, tones.right.slice().reverse(), 32);
    arches.append(frag);
    observeReveals(arches);
  }

  const txt = $('#notes-txt');
  if (txt && !reducedMotion && 'IntersectionObserver' in window) {
    // type the note into place without moving the layout: typed text + the rest kept invisible
    const walker = document.createTreeWalker(txt, NodeFilter.SHOW_TEXT);
    const nodes: { typed: Text; ghost: HTMLSpanElement; full: string }[] = [];
    const found: Text[] = [];
    while (walker.nextNode()) found.push(walker.currentNode as Text);
    for (const node of found) {
      if (node.parentElement?.classList.contains('car') || !node.data.trim()) continue;
      const ghost = document.createElement('span');
      ghost.className = 'ghost';
      ghost.textContent = node.data;
      const wrap = document.createElement('span');
      wrap.className = 'typed';
      const typed = document.createTextNode('');
      wrap.append(typed);
      node.replaceWith(wrap, ghost);
      nodes.push({ typed, ghost, full: ghost.textContent });
    }
    const car = $('.car', txt)!;
    car.hidden = true;
    txt.classList.add('is-typing');
    let started = false;
    const run = async () => {
      if (started) return;
      started = true;
      for (const n of nodes) {
        n.typed.parentElement!.after(car);
        car.hidden = false;
        for (let i = 1; i <= n.full.length; i++) {
          n.typed.data = n.full.slice(0, i);
          n.ghost.textContent = n.full.slice(i);
          await sleep(n.full[i - 1] === '.' ? 160 : 14);
        }
      }
      txt.querySelector('p:last-child')!.append(car);
      txt.classList.remove('is-typing');
    };
    const io = new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) { io.disconnect(); run(); } }, { threshold: 0.35 });
    io.observe(txt);
    setTimeout(() => { if (!started) { nodes.forEach((n) => { n.typed.data = n.full; n.ghost.textContent = ''; }); car.hidden = false; started = true; txt.classList.remove('is-typing'); } }, 20000);
  }
}

// ------------------------------------------------------------------ sample asks wall
{
  type Ask = { name: string; role: string; c: string; mode: string; text: string };
  const asks: Ask[][] = [
    [
      { name: 'aina', role: 'student', c: '#91cefa', mode: 'talk · pointing', text: 'awan, explain this graph like i slept four hours' },
      { name: 'hafiz', role: 'runs a small shop', c: '#88db96', mode: 'agent', text: 'awan, agent. find every order that hasn\'t shipped since friday and make me a list' },
      { name: 'mei', role: 'designer', c: '#f7a3c6', mode: 'talk · drawing', text: 'where did the export settings go in this version?' },
    ],
    [
      { name: 'wei jie', role: 'engineer', c: '#fab5a0', mode: 'talk', text: 'what is this stack trace actually trying to tell me?' },
      { name: 'sarah', role: 'freelancer', c: '#fae371', mode: 'dictation', text: 'turn what i just said into a polite email to the client, keep it short' },
      { name: 'arif', role: 'operations', c: '#8c99db', mode: 'routine · mondays 9am', text: 'every monday at nine, pull last week\'s numbers into a one-page summary' },
    ],
    [
      { name: 'priya', role: 'marketer', c: '#c0a0eb', mode: 'agent', text: 'awan, agent. find ten podcasts about small business in malaysia and draft a pitch for each' },
      { name: 'daniel', role: 'new to mac', c: '#f7b16f', mode: 'talk · pointing', text: 'how do i screenshot just this part of the screen?' },
      { name: 'nurul', role: 'teacher', c: '#88db96', mode: 'agent', text: 'make a ten-question quiz from this chapter, answers at the end' },
    ],
  ];
  const wall = $('#fb-wall');
  if (wall) {
    const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
    wall.innerHTML = asks.map((col) => `<div class="fb-col">${col.map((a) => `
      <article class="fb-card reveal" style="--c:${a.c}">
        <div class="fb-bar"><span class="dots"><i></i><i></i><i></i></span><span class="x" aria-hidden="true">✕</span></div>
        <div class="fb-body">
          <div class="fb-head">
            <span class="fb-av" aria-hidden="true">${esc(a.name[0])}</span>
            <span class="fb-who"><span class="fb-name">${esc(a.name)} <span class="fb-sample">sample</span></span><span class="fb-role">${esc(a.role)}</span></span>
            <button class="fb-copy" type="button" data-ask="${esc(a.text)}" aria-label="copy this ask"><svg aria-hidden="true"><use href="#i-copy"/></svg><span>copy</span></button>
          </div>
          <p class="fb-text">${esc(a.text)}</p>
          <p class="fb-meta"><span>${esc(a.mode)}</span></p>
        </div>
      </article>`).join('')}</div>`).join('');
    observeReveals(wall);
    wall.addEventListener('click', async (e) => {
      const btn = (e.target as Element).closest<HTMLButtonElement>('.fb-copy');
      if (!btn) return;
      try { await navigator.clipboard.writeText(btn.dataset.ask ?? ''); } catch { /* clipboard blocked: still acknowledge */ }
      btn.classList.add('done');
      btn.querySelector('span')!.textContent = 'copied';
      setTimeout(() => { btn.classList.remove('done'); btn.querySelector('span')!.textContent = 'copy'; }, 1600);
    });
  }
  // marquee drifts with scroll, like the reference's translate3d track
  const track = $('.fb-marquee-track');
  const sec = $('#asks');
  if (track && sec && !reducedMotion) {
    let raf = 0;
    const move = () => {
      raf = 0;
      const r = sec.getBoundingClientRect();
      const p = (innerHeight - r.top) / (innerHeight + r.height);
      if (p < -0.1 || p > 1.1) return;
      track.style.transform = `translate3d(${(0.5 - p) * 260}px,0,0)`;
    };
    addEventListener('scroll', () => { if (!raf) raf = requestAnimationFrame(move); }, { passive: true });
    move();
  }
}

// ------------------------------------------------------------------ pricing: spring pill (k 500, c 38 — the reference's framer values), rolling digits, sky
{
  const pr = $('#pricing')!;
  const toggle = $('#pr-toggle')!;
  const pill = $('#pr-pill')!;
  const segs = $$<HTMLButtonElement>('.pr-seg', toggle);

  // digits → reels
  $$('.pr-digits').forEach((el) => {
    const m = el.dataset.m!, y = el.dataset.y!;
    const len = Math.max(m.length, y.length);
    el.innerHTML = '';
    el.setAttribute('aria-hidden', 'true');
    const label = document.createElement('span');
    label.className = 'sr-only pr-price-sr';
    label.textContent = m;
    el.after(label);
    for (let i = 0; i < len; i++) {
      const col = document.createElement('span');
      col.className = 'col';
      col.innerHTML = `<span class="reel">${Array.from({ length: 10 }, (_, d) => `<span>${d}</span>`).join('')}</span>`;
      el.append(col);
    }
  });
  const setDigits = (period: 'month' | 'year') => {
    $$('.pr-digits').forEach((el) => {
      const v = period === 'month' ? el.dataset.m! : el.dataset.y!;
      const cols = $$('.col', el);
      const pad = cols.length - v.length;
      cols.forEach((col, i) => {
        const ch = i < pad ? null : v[i - pad];
        col.classList.toggle('gone', ch === null);
        if (ch !== null) {
          col.style.width = '';
          (col.firstElementChild as HTMLElement).style.transform = `translateY(-${Number(ch)}em)`;
        } else col.style.width = '0px';
      });
      (el.nextElementSibling as HTMLElement).textContent = v;
    });
    $$('.pr-price-note').forEach((n) => { n.textContent = (period === 'month' ? n.dataset.m : n.dataset.y) ?? ''; });
    pr.classList.toggle('yearly', period === 'year');
  };

  let x = 0, w = 0, vx = 0, vw = 0, tx = 0, tw = 0, raf = 0, last = 0;
  const K = 500, C = 38;
  const render = () => { pill.style.transform = `translateX(${x}px)`; pill.style.width = `${w}px`; };
  const stepSpring = (t: number) => {
    const dt = Math.min(0.032, (t - last) / 1000 || 0.016);
    last = t;
    for (let i = 0; i < 4; i++) {
      const h = dt / 4;
      const ax = -K * (x - tx) - C * vx, aw = -K * (w - tw) - C * vw;
      vx += ax * h; x += vx * h; vw += aw * h; w += vw * h;
    }
    render();
    if (Math.abs(x - tx) + Math.abs(w - tw) + Math.abs(vx) + Math.abs(vw) > 0.05) raf = requestAnimationFrame(stepSpring);
    else { x = tx; w = tw; render(); raf = 0; }
  };
  const target = (btn: HTMLElement, instant = false) => {
    tx = btn.offsetLeft - 4;
    tw = btn.offsetWidth;
    if (instant || reducedMotion) { x = tx; w = tw; vx = vw = 0; render(); return; }
    if (!raf) { last = performance.now(); raf = requestAnimationFrame(stepSpring); }
  };
  const select = (btn: HTMLButtonElement, instant = false) => {
    segs.forEach((s) => { const on = s === btn; s.classList.toggle('on', on); s.setAttribute('aria-checked', String(on)); s.tabIndex = on ? 0 : -1; });
    target(btn, instant);
    setDigits(btn.dataset.period as 'month' | 'year');
  };
  segs.forEach((s) => s.addEventListener('click', () => select(s)));
  toggle.addEventListener('keydown', (e) => {
    if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return;
    e.preventDefault();
    const i = segs.findIndex((s) => s.classList.contains('on'));
    const next = segs[(i + (e.key === 'ArrowRight' ? 1 : segs.length - 1)) % segs.length];
    select(next); next.focus();
  });
  const init = () => select(segs.find((s) => s.classList.contains('on')) ?? segs[0], true);
  document.fonts?.ready.then(init);
  init();
  addEventListener('resize', () => target(segs.find((s) => s.classList.contains('on'))!, true));

  // procedural cloud bank + gentle parallax (no photography)
  const clouds = $('.pr-clouds');
  if (clouds) {
    let seed = 11;
    const r = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
    // Awan's own cloud silhouette, softened: sparse and dim up high, a brighter bank towards the horizon
    const bank: string[] = [];
    for (let i = 0; i < 40; i++) {
      const band = Math.pow(r(), 0.7);
      const top = 120 + band * 700;
      const wv = 140 + r() * 320 + band * 120;
      bank.push(`<svg viewBox="0 0 100 70" style="left:${(r() * 108 - 8).toFixed(1)}%;top:${top.toFixed(0)}px;width:${wv.toFixed(0)}px;height:${(wv * 0.62).toFixed(0)}px;--a:${(0.12 + band * 0.55).toFixed(2)};--b:${(4 + (1 - band) * 10).toFixed(0)}px"><use href="#i-cloud"/></svg>`);
    }
    clouds.innerHTML = bank.join('');
    if (!reducedMotion) {
      let pr2 = 0;
      const par = () => {
        pr2 = 0;
        const rect = pr.getBoundingClientRect();
        if (rect.bottom < -200 || rect.top > innerHeight + 200) return;
        clouds.style.transform = `translate3d(0,${(rect.top * -0.12).toFixed(1)}px,0)`;
      };
      addEventListener('scroll', () => { if (!pr2) pr2 = requestAnimationFrame(par); }, { passive: true });
      par();
    }
  }
}

// ------------------------------------------------------------------ faq accordion (one open at a time, so the fixed canvas never overflows)
{
  const items = $$('.faq-item');
  items.forEach((item) => {
    const btn = item.querySelector('button')!;
    btn.addEventListener('click', () => {
      const open = !item.classList.contains('open');
      items.forEach((o) => { o.classList.remove('open'); o.querySelector('button')!.setAttribute('aria-expanded', 'false'); });
      item.classList.toggle('open', open);
      btn.setAttribute('aria-expanded', String(open));
    });
  });
}
