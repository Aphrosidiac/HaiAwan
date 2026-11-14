/**
 * FF Analytics for Cloudflare Pages and Workers (FF Ops docs/ANALYTICS.md §5). One file, no dependencies.
 *
 *   Pages  — functions/_middleware.js:  import { pagesMiddleware } from './ff-analytics.js'; export const onRequest = pagesMiddleware;
 *   Worker — import { withAnalytics } from './ff-analytics.js'; export default withAnalytics(handler);
 *
 * Settings: FF_ANALYTICS_URL (e.g. https://ops.ffdev.studio) and the secret FF_ANALYTICS_KEY (ffi_…).
 * Optional: FF_ANALYTICS_INJECT=0 when the pages already carry the beacon.
 *
 * What it does, per request:
 *   - /_e (the beacon): answers 204, never cached, and forwards it;
 *   - HTML pages: serves them unchanged except for the beacon script before </head>, then forwards the request;
 *   - robots.txt / sitemaps / llms.txt, and anything that ended 4xx/5xx (crawlers, scanners): forwarded;
 *   - successful static assets: not forwarded (FF Ops would only count them).
 * Forwarding happens in waitUntil after the response is returned, so it never slows the page, and a failure is
 * swallowed. The line has the visitor's CF-Connecting-IP, User-Agent, cf.country and the status; FF Ops classifies.
 */
const BEACON = "(function(){try{var d=document,l=location,n=navigator,q=new URLSearchParams(l.search),ref='';try{if(d.referrer){var u=new URL(d.referrer);if(u.hostname!==l.hostname)ref=u.hostname;}}catch(e){}var us=q.get('utm_source')||'',um=q.get('utm_medium')||'',uc=q.get('utm_campaign')||'';if(!/(?:^|; )ff_ft=/.test(d.cookie)){var h=l.hostname.replace(/^www\\./,'');var ft=encodeURIComponent(JSON.stringify({r:ref,s:us,m:um,c:uc,p:l.pathname,t:Date.now()}));d.cookie='ff_ft='+ft+'; path=/; max-age=15552000; samesite=lax'+(h.indexOf('.')>0?'; domain='+h+'; secure':'');}var sent=false,send=function(e){if(sent)return;sent=true;var p='/_e?p='+encodeURIComponent(l.pathname)+'&r='+encodeURIComponent(ref)+'&us='+encodeURIComponent(us)+'&um='+encodeURIComponent(um)+'&uc='+encodeURIComponent(uc)+'&w='+(window.innerWidth||0)+'&wd='+(n.webdriver?1:0)+'&e='+e;if(n.sendBeacon)n.sendBeacon(p);else new Image().src=p;};['pointerdown','keydown','scroll','touchstart','mousemove'].forEach(function(t){addEventListener(t,function(){send('i');},{once:true,passive:true});});setTimeout(function(){if(d.visibilityState==='visible')send('t');},3000);}catch(e){}})();";
const FILE = /^\/(robots\.txt|sitemap[\w-]*\.xml|llms(-full)?\.txt|[\w-]+\.md|(rss|feed|atom)\.xml|ads\.txt|\.well-known\/.*)$/i;

function line(request, url, status, bytes, started) {
  const h = request.headers;
  let ref = '';
  try { const r = h.get('referer'); if (r) ref = new URL(r).hostname; } catch { /* not a URL */ }
  return {
    t: new Date(started).toISOString(), h: url.hostname, ip: h.get('cf-connecting-ip') || '', m: request.method,
    u: url.pathname + url.search, s: status, b: bytes, rt: (Date.now() - started) / 1000, ua: h.get('user-agent') || '',
    r: ref, c: (request.cf && request.cf.country) || '', q: url.pathname === '/_e' ? url.search.slice(1) : '',
  };
}

function send(env, ctx, l) {
  if (!env.FF_ANALYTICS_URL || !env.FF_ANALYTICS_KEY || !l.ip) return;
  ctx.waitUntil(fetch(env.FF_ANALYTICS_URL.replace(/\/$/, '') + '/api/ingest/traffic', {
    method: 'POST',
    headers: { authorization: 'Bearer ' + env.FF_ANALYTICS_KEY, 'content-type': 'application/x-ndjson', 'x-ff-source': 'cloudflare' },
    body: JSON.stringify(l) + '\n',
  }).catch(() => undefined));
}

async function handle(request, env, ctx, next) {
  const started = Date.now();
  const url = new URL(request.url);
  if (url.pathname === '/_e') {
    send(env, ctx, line(request, url, 204, 0, started));
    return new Response(null, { status: 204, headers: { 'cache-control': 'no-store' } });
  }
  let res = await next();
  const type = res.headers.get('content-type') || '';
  const html = type.includes('text/html');
  if (html || FILE.test(url.pathname) || res.status >= 400) send(env, ctx, line(request, url, res.status, Number(res.headers.get('content-length')) || 0, started));
  if (html && env.FF_ANALYTICS_INJECT !== '0' && res.status < 400) {
    res = new HTMLRewriter().on('head', { element(el) { el.append('<script>' + BEACON + '</script>', { html: true }); } }).transform(res);
  }
  return res;
}

/** Cloudflare Pages: export const onRequest = pagesMiddleware; */
export const pagesMiddleware = (context) => handle(context.request, context.env, context, () => context.next());

/** A Worker: export default withAnalytics({ fetch(request, env, ctx) { … } }) or withAnalytics(fetchFn). */
export function withAnalytics(handler) {
  const fetchFn = typeof handler === 'function' ? handler : handler.fetch.bind(handler);
  const rest = typeof handler === 'function' ? {} : handler;
  return { ...rest, fetch: (request, env, ctx) => handle(request, env, ctx, () => fetchFn(request, env, ctx)) };
}
