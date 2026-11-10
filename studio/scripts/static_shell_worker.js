// Generated with an exact allowlist of this public Flutter build. Never cache
// API, identity, image-delivery, token, arbitrary navigation or account traffic.
const CACHE = __CACHE_NAME__;
const STATIC = new Set(__STATIC_PATHS__);
const ROUTES = new Set(__SPA_ROUTES__);

function eligible(request) {
  const url = new URL(request.url);
  return request.method === 'GET' && url.origin === self.location.origin &&
    !url.search && !request.headers.has('Authorization') &&
    !url.pathname.startsWith('/studio/v1') && !url.pathname.startsWith('/content/v1') &&
    (STATIC.has(url.pathname) || (request.mode === 'navigate' && ROUTES.has(url.pathname)));
}

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    // Validate every response before opening this version's cache. Only the
    // generated public files may be installed; no runtime requests add entries.
    const responses = await Promise.all([...STATIC].map(async path => {
      const response = await fetch(new Request(new URL(path, self.location.origin), {
        cache: 'reload', credentials: 'omit', redirect: 'error',
      }));
      if (!response.ok || response.type === 'opaque' ||
          /(?:^|,)\s*(?:no-store|private)(?:\s|,|=|$)/i.test(response.headers.get('Cache-Control') || '')) {
        throw new Error('Public offline shell could not be installed');
      }
      return [path, response];
    }));
    const cache = await caches.open(CACHE);
    await Promise.all(responses.map(([path, response]) => cache.put(path, response)));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key.startsWith('biguess-studio-shell-') && key !== CACHE) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', event => {
  if (!eligible(event.request)) return;
  const url = new URL(event.request.url);
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    if (STATIC.has(url.pathname) && url.pathname !== '/index.html') {
      const stored = await cache.match(url.pathname);
      if (stored) return stored;
    }
    try {
      // Navigation always tries the server. Never put its response in a cache:
      // this prevents account state or a newer release entering the old shell.
      return await fetch(event.request);
    } catch (error) {
      const shell = await cache.match('/index.html');
      if (shell && ROUTES.has(url.pathname)) return shell;
      throw error;
    }
  })());
});
