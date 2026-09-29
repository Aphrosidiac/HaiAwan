import { defineConfig, type Plugin } from 'vite';
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

const root = import.meta.dirname;

/** Pages of the site. Each is a static HTML file; shared chrome comes from partials/. */
const pages = {
  index: 'index.html',
  changelog: 'changelog/index.html',
  privacy: 'privacy/index.html',
  terms: 'terms/index.html',
  'referral-terms': 'referral-terms/index.html',
  trust: 'trust/index.html',
  download: 'download/index.html',
  notFound: '404.html',
};

/**
 * `<!-- @include name -->` → contents of partials/name.html, at build and dev time.
 * Keeps the menubar, footer and sprite as plain static HTML in every page (no runtime templating).
 */
function includes(): Plugin {
  const re = /<!--\s*@include\s+([\w-]+)\s*-->/g;
  const expand = (html: string, depth = 0): string =>
    html.replace(re, (_m, name: string) => {
      const file = resolve(root, 'partials', `${name}.html`);
      if (!existsSync(file)) throw new Error(`missing partial ${name}`);
      const body = readFileSync(file, 'utf8');
      return depth < 4 ? expand(body, depth + 1) : body;
    });
  return {
    name: 'awan-includes',
    enforce: 'pre',
    transformIndexHtml: { order: 'pre', handler: (html) => expand(html) },
    handleHotUpdate({ file, server }) {
      if (file.includes('/partials/')) server.ws.send({ type: 'full-reload' });
    },
  };
}

/**
 * Dev/preview routing that mirrors the static host:
 *  /trust → /trust/, /@handle → the home page (referral landing), unknown paths → 404.html.
 * In production the host serves 404.html for unknown paths and that page forwards /@handle
 * to /?ref=handle (see src/notfound.ts).
 */
function routes(): Plugin {
  const known = new Set(Object.values(pages).map((p) => '/' + p.replace(/index\.html$/, '')));
  const handler = (req: { url?: string }, _res: unknown, next: () => void) => {
    const url = new URL(req.url ?? '/', 'http://x');
    const p = url.pathname;
    if (/^\/@[a-z0-9_.-]{1,32}\/?$/i.test(p)) req.url = '/index.html' + url.search;
    else if (!p.includes('.') && !p.endsWith('/') && known.has(p + '/')) req.url = p + '/' + url.search;
    else if (!p.includes('.') && p !== '/' && !known.has(p) && !p.startsWith('/@') && !p.startsWith('/src/') && !p.startsWith('/node_modules/'))
      req.url = '/404.html';
    next();
  };
  return {
    name: 'awan-routes',
    configureServer(server) {
      server.middlewares.use(handler);
    },
    configurePreviewServer(server) {
      server.middlewares.use(handler);
    },
  };
}

export default defineConfig({
  root,
  appType: 'mpa',
  plugins: [includes(), routes()],
  server: { port: 5190, strictPort: true },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: { input: Object.fromEntries(Object.entries(pages).map(([k, v]) => [k, resolve(root, v)])) },
  },
});
