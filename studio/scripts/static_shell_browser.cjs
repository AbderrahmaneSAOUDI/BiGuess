// Actual Chromium service-worker proof against a packaged local fixture. This
// tests shell Cache Storage only; dataset/identity tests have their own harness.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const {spawnSync} = require('node:child_process');
const os = require('node:os');
let fixture;
if (process.argv[2] === '--fixture') {
  fixture = fs.mkdtempSync(path.join(os.tmpdir(),'biguess-shell-'));
  const source = path.join(fixture,'web');
  fs.mkdirSync(path.join(source,'assets'),{recursive:true});
  fs.writeFileSync(path.join(source,'index.html'),'<head><base href="/"></head><body>Public shell fixture<script src="flutter_bootstrap.js"></script></body>');
  fs.writeFileSync(path.join(source,'flutter_bootstrap.js'),"const studioConfig = {fontFallbackBaseUrl: '/font-fallbacks/'}; function initializeEngine(x) {} initializeEngine(studioConfig);");
  fs.writeFileSync(path.join(source,'main.dart.js'),'// Public test artifact');
  fs.writeFileSync(path.join(source,'assets/test.svg'),'<svg/>');
  const config = path.join(fixture,'public.json');
  fs.writeFileSync(config,JSON.stringify({STUDIO_FIREBASE_API_KEY:'public-test-key',STUDIO_FIREBASE_APP_ID:'test-app',
    STUDIO_FIREBASE_PROJECT_ID:'test-project',STUDIO_FIREBASE_AUTH_DOMAIN:'test.firebaseapp.com',
    STUDIO_FIREBASE_MESSAGING_SENDER_ID:'123',STUDIO_API_BASE_URL:'https://private-api.example'}));
  const packaged = spawnSync('python3',[path.join(__dirname,'prepare_deployment.py'),'--source',source,
    '--output',path.join(fixture,'pages'),'--commit','a'.repeat(40),'--public-config',config],{encoding:'utf8'});
  assert.equal(packaged.status,0,packaged.stderr);
}
const root = path.resolve(fixture ? path.join(fixture,'pages') : process.env.STUDIO_SHELL_TEST_ROOT || process.argv[2] || 'build/pages');
let servingRoot = root;
const types = {'.html':'text/html','.js':'text/javascript','.json':'application/json','.svg':'image/svg+xml','.wasm':'application/wasm'};
let privateReads = 0;
const server = http.createServer((req,res) => {
  const url = new URL(req.url,'http://localhost');
  if (url.pathname.startsWith('/studio/v1') || url.pathname.startsWith('/content/v1') ||
      req.headers.authorization || url.search) {
    privateReads++;
    res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'}).end(JSON.stringify({private:'fixture-secret'}));
    return;
  }
  const file = path.resolve(servingRoot,'.' + decodeURIComponent(url.pathname));
  if (!file.startsWith(servingRoot + path.sep) && file !== servingRoot) return res.writeHead(403).end();
  const target = fs.existsSync(file) && fs.statSync(file).isFile() ? file : path.join(servingRoot,'index.html');
  res.writeHead(200, {'Content-Type': types[path.extname(target)] || 'application/octet-stream',
    'Cache-Control': url.pathname.startsWith('/releases/') ? 'public,max-age=31536000,immutable' : 'public,max-age=0,must-revalidate'});
  fs.createReadStream(target).pipe(res);
});
(async () => {
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({...(process.env.CHROME_EXECUTABLE ? {executablePath:process.env.CHROME_EXECUTABLE} : {}),args:['--no-sandbox']});
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(origin + '/dashboard');
    await page.evaluate(async () => {
      await navigator.serviceWorker.ready;
      if (!navigator.serviceWorker.controller) await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange',resolve,{once:true}));
    });
    const inspect = () => page.evaluate(async () => {
      const result = {};
      for (const name of await caches.keys()) {
        const cache = await caches.open(name);
        result[name] = await Promise.all((await cache.keys()).map(async key => ({url:key.url,body:await (await cache.match(key)).text()})));
      }
      return result;
    });
    const before = await inspect();
    assert.equal(Object.keys(before).length,1);
    const assets = Object.values(before)[0];
    assert(assets.some(item => item.url.endsWith('/index.html')));
    const staticUrl = assets.find(item => item.url.endsWith('.svg')).url;
    for (const target of ['/studio/v1/session','/content/v1/studio/packs',new URL(staticUrl).pathname + '?secret=fixture']) {
      assert((await page.evaluate(async target => (await fetch(target)).text(),target)).includes('fixture-secret'));
    }
    assert((await page.evaluate(async url => (await fetch(url,{cache:'no-store',headers:{Authorization:'Bearer fixture'}})).text(),staticUrl)).includes('fixture-secret'));
    assert.equal(privateReads,4);
    assert.deepEqual(await inspect(),before,'private runtime responses must never modify the shell cache');
    await context.setOffline(true);
    await page.reload();
    assert.equal(await page.locator('meta[name="studio-commit"]').count(),1,'actual offline reload must restore the static shell');
    await page.goto(origin + '/cards');
    assert.equal(await page.locator('meta[name="studio-commit"]').count(),1,'known deep link works offline');
    assert.equal(await page.evaluate(async url => (await fetch(url)).ok,staticUrl),true);
    assert.equal(await page.evaluate(async () => {try {await fetch('/studio/v1/session');return false;}catch{return true;}}),true,'private endpoint must fail offline, never fall back to cached public/private bytes');
    assert.deepEqual(await inspect(),before);
    if (fixture) {
      const config = path.join(fixture,'public.json');
      const disabled = {...JSON.parse(fs.readFileSync(config,'utf8')),STUDIO_API_BASE_URL:''};
      fs.writeFileSync(config,JSON.stringify(disabled));
      const packaged = spawnSync('python3',[path.join(__dirname,'prepare_deployment.py'),'--source',path.join(fixture,'web'),
        '--output',path.join(fixture,'disabled'),'--commit','c'.repeat(40),'--public-config',config],{encoding:'utf8'});
      assert.equal(packaged.status,0,packaged.stderr);
      servingRoot = path.join(fixture,'disabled');
      await context.setOffline(false);
      await page.goto(origin + '/dashboard');
      await page.waitForFunction(async () => (await navigator.serviceWorker.getRegistrations()).length === 0 &&
        !(await caches.keys()).some(key => key.startsWith('biguess-studio-shell-')));
      assert.equal(await page.locator('meta[name="studio-commit"]').getAttribute('content'),'c'.repeat(40));
    }
    await context.close();
    console.log('Chromium static shell PASS: real offline reload/deep link/assets; API, bearer and query responses never cached; API-disabled rollback unregisters own shell and clears static cache.');
  } finally {
    await browser.close(); await new Promise(resolve => server.close(resolve));
    if (fixture) fs.rmSync(fixture,{recursive:true});
  }
})().catch(error => {console.error(error);server.close();process.exitCode=1;});
