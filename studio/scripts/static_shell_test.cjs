// Executes the generated worker in a browser-like JS context, including its
// install/fetch handlers. No application/private bytes enter Cache Storage.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const worker = fs.readFileSync(process.argv[2], 'utf8');

async function harness(cacheControl = 'public, max-age=31536000') {
  const listeners = {};
  const entries = new Map();
  let online = true;
  const cache = {
    put: async (key, response) => entries.set(key, response),
    match: async key => entries.get(key)?.clone(),
  };
  const context = vm.createContext({
    URL, Request, Response, Set, Promise, Error,
    self: { location: {origin: 'https://studio.example'}, addEventListener: (kind, fn) => listeners[kind] = fn,
      skipWaiting: async () => {}, clients: {claim: async () => {}} },
    caches: { open: async () => cache, keys: async () => [], delete: async () => {} },
    fetch: async request => {
      if (!online) throw new Error('offline');
      assert.equal(request.headers.has('Authorization'), false);
      return new Response('public shell', {headers: {'Cache-Control': cacheControl}});
    },
  });
  vm.runInContext(worker, context);
  const install = () => { let pending; listeners.install({waitUntil: value => pending = value}); return pending; };
  const fetch = async (url, init = {}) => {
    let intercepted;
    const req = new Request(url, init);
    if (init.navigation) Object.defineProperty(req, 'mode', {value: 'navigate'});
    listeners.fetch({request: req, respondWith: response => intercepted = response});
    return intercepted;
  };
  return {entries, install, fetch, offline: () => online = false};
}
(async () => {
  if (process.argv[3] === 'cleanup') {
    let load;
    const removed = [];
    const deleted = [];
    const registration = (scriptURL, waiting = false) => ({
      [waiting ? 'waiting' : 'active']: {scriptURL},
      unregister: async () => removed.push(scriptURL),
    });
    const cacheApi = {keys:async () => ['biguess-studio-shell-old','other-static-cache'],delete:async key => deleted.push(key)};
    vm.runInNewContext(worker,{
      URL, location:{origin:'https://studio.example'}, console,
      window:{addEventListener:(_,fn) => load = fn,caches:cacheApi}, caches:cacheApi,
      navigator:{serviceWorker:{getRegistrations:async () => [
        registration('https://studio.example/studio-shell-worker.js'),
        registration('https://studio.example/studio-shell-worker.js',true),
        registration('https://studio.example/unrelated-worker.js'),
        registration('https://other.example/studio-shell-worker.js'),
      ]}},
    });
    await load();
    assert.deepEqual(removed,['https://studio.example/studio-shell-worker.js','https://studio.example/studio-shell-worker.js']);
    assert.deepEqual(deleted,['biguess-studio-shell-old']);
    console.log('Disabled shell cleanup: only own worker/static cache removed; other caches/workers and IndexedDB untouched.');
    return;
  }
  const h = await harness(); await h.install();
  const before = [...h.entries.keys()];
  assert(before.includes('/index.html'));
  assert(before.some(path => path.includes('/main.dart.js')));
  for (const url of ['https://studio.example/studio/v1/session', 'https://studio.example/content/v1/studio/packs',
    'https://studio.example/private-image', 'https://studio.example/cards?token=secret',
    'https://identity.example/token', 'https://studio.example/__/auth/handler']) {
    assert.equal(await h.fetch(url, {navigation: true}), undefined, url);
  }
  assert.equal(await h.fetch('https://studio.example/index.html', {headers:{Authorization:'Bearer secret'}}), undefined);
  assert.equal(await h.fetch('https://studio.example/index.html', {method:'POST'}), undefined);
  h.offline();
  assert.equal(await (await h.fetch('https://studio.example/cards', {navigation:true})).text(), 'public shell');
  assert.equal(await (await h.fetch('https://studio.example' + before.find(path => path.endsWith('/main.dart.js')))).text(), 'public shell');
  assert.deepEqual([...h.entries.keys()], before, 'runtime fetches never populate caches');
  for (const policy of ['no-store', 'public, no-store', 'private, max-age=60']) {
    const denied = await harness(policy);
    await assert.rejects(denied.install(), /could not be installed/);
    assert.equal(denied.entries.size, 0);
  }
  console.log('Static shell: offline routes/assets pass; private/auth/API/query traffic never intercepted or cached; no-store/private install fails closed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
