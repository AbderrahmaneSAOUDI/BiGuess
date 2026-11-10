// Actual packaged Flutter + IndexedDB + session/controller integration. The
// alternate test entrypoint supplies only synthetic identity; no production
// Firebase account, Worker deployment, auth bypass or real content is involved.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const {spawnSync} = require('node:child_process');
const source = path.resolve(process.env.STUDIO_DATASET_WEB_ROOT || 'build/dataset-web');
const temp = fs.mkdtempSync(path.join(os.tmpdir(),'biguess-dataset-browser-'));
const root = path.join(temp,'pages');
const config = path.join(temp,'public.json');
fs.writeFileSync(config,JSON.stringify({STUDIO_FIREBASE_API_KEY:'public-fixture-key',STUDIO_FIREBASE_APP_ID:'fixture-app',
  STUDIO_FIREBASE_PROJECT_ID:'browser-fixture',STUDIO_FIREBASE_AUTH_DOMAIN:'fixture.firebaseapp.com',
  STUDIO_FIREBASE_MESSAGING_SENDER_ID:'123',STUDIO_API_BASE_URL:'https://fixture-api.invalid'}));
const packaged = spawnSync('python3',[path.join(__dirname,'prepare_deployment.py'),'--source',source,'--output',root,
  '--commit','b'.repeat(40),'--public-config',config],{encoding:'utf8'});
assert.equal(packaged.status,0,packaged.stderr);
const types = {'.html':'text/html','.js':'text/javascript','.json':'application/json','.svg':'image/svg+xml',
  '.wasm':'application/wasm','.ttf':'font/ttf','.otf':'font/otf','.webp':'image/webp','.png':'image/png'};
const requests = [];
const returned = [];
let revoked = false;
let interrupt = false;
const topic = {resourceType:'topic',id:'taxonomy',name:'Shared taxonomy',state:'active',revision:1};
function pack(uid, partial = false) {return {resourceType:'pack',id:`pack-${uid}`,topicId:'taxonomy',
  name:partial ? `${uid.toUpperCase()} partial staging` : `${uid.toUpperCase()} private pack`,state:'active',revision:1};}
function card(uid) {return {resourceType:'card',id:`card-${uid}`,packId:`pack-${uid}`,name:`${uid.toUpperCase()} private card`,
  imageReference:`opaque-${uid}`,difficulty:1,state:'active',revision:1};}
const server = http.createServer((req,res) => {
  const url = new URL(req.url,'http://localhost');
  if (url.pathname.startsWith('/studio/v1') || url.pathname.startsWith('/content/v1')) {
    const uid = /^Bearer token-(a|b|new)$/.exec(req.headers.authorization || '')?.[1];
    requests.push({method:req.method,path:url.pathname,uid});
    res.setHeader('Cache-Control','no-store'); res.setHeader('Content-Type','application/json');
    if (!uid) return res.writeHead(401).end(JSON.stringify({error:{code:'unauthenticated'}}));
    if (revoked && uid === 'a') return res.writeHead(403).end(JSON.stringify({error:{code:'forbidden'}}));
    if (req.method !== 'GET') return res.writeHead(405).end('{}');
    if (url.pathname === '/content/v1/studio/session') return res.end(JSON.stringify({uid,email:`${uid}@fixture.test`,role:'collector'}));
    if (url.pathname === '/studio/v1/sync/initial') {
      const cursor = url.searchParams.get('cursor');
      if (cursor && cursor !== `${uid}-page2`) return res.writeHead(409).end(JSON.stringify({error:{code:'cursor_expired'}}));
      if (cursor && interrupt) return res.writeHead(503).end(JSON.stringify({error:{code:'storage-unavailable'}}));
      const items = cursor ? [card(uid)] : [topic,pack(uid,interrupt)];
      returned.push({uid,items});
      return res.end(JSON.stringify({protocolVersion:1,scopeVersion:1,items,nextCursor:cursor ? null : `${uid}-page2`,
        resumeCursor:cursor ? `resume-${uid}` : null}));
    }
    return res.writeHead(404).end('{}');
  }
  const file = path.resolve(root,'.' + decodeURIComponent(url.pathname));
  if (!file.startsWith(root + path.sep) && file !== root) return res.writeHead(403).end();
  const target = fs.existsSync(file) && fs.statSync(file).isFile() ? file : path.join(root,'index.html');
  res.writeHead(200,{'Content-Type':types[path.extname(target)] || 'application/octet-stream',
    'Cache-Control':url.pathname.startsWith('/releases/') ? 'public,max-age=31536000,immutable' : 'public,max-age=0,must-revalidate'});
  fs.createReadStream(target).pipe(res);
});
(async () => {
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({...(process.env.CHROME_EXECUTABLE ? {executablePath:process.env.CHROME_EXECUTABLE} : {}),args:['--no-sandbox']});
  let diagnosticPage;
  const errors = [];
  try {
    const context = await browser.newContext({viewport:{width:1440,height:1100}});
    const page = await context.newPage();
    diagnosticPage = page;
    page.on('pageerror',error => errors.push(String(error)));
    page.on('console',message => {
      const text = message.text();
      if (message.type() === 'error' && !/Failed to load resource:.*(?:403|503|ERR_INTERNET_DISCONNECTED)/.test(text)) errors.push(text);
    });
    const enableSemantics = async () => {
      await page.locator('flt-glass-pane').waitFor({state:'attached'});
      const placeholder = page.locator('flt-semantics-placeholder');
      if (await placeholder.count()) await placeholder.evaluate(element => element.click());
    };
    const status = name => page.locator('flt-semantics').getByText(name,{exact:typeof name === 'string'}).last();
    const content = name => page.getByText(name,{exact:true}).or(page.getByLabel(name,{exact:false})).first();
    await page.goto(origin + '/my-packs?account=a');
    await enableSemantics();
    await content('A private pack').waitFor().catch(async error => {
      console.error('Initial fixture diagnostics:',JSON.stringify({errors,requests,returned,body:await page.locator('body').innerText()}));
      await page.screenshot({path:'/tmp/t28-dataset-initial-failure.png'});
      throw error;
    });
    assert.equal(await content('B private pack').count(),0);
    await page.evaluate(async () => {
      await navigator.serviceWorker.ready;
      if (!navigator.serviceWorker.controller) await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange',resolve,{once:true}));
    });
    const edit = async (name, existing = false) => {
      await page.getByRole('button',{name:existing ? 'Edit local draft' : 'Edit name locally',exact:true}).click();
      await page.getByRole('textbox',{name:'Name',exact:true}).fill(name);
      await page.getByRole('button',{name:'Save locally',exact:true}).click();
      await content(name).waitFor();
    };
    await edit('A durable local draft');
    await page.getByRole('button',{name:'Queue commit',exact:true}).click();
    await content('Unsent commit — queued locally').waitFor();
    await page.reload();
    await enableSemantics();
    await content('A durable local draft').waitFor();
    await content('Unsent commit — queued locally').waitFor();
    await page.screenshot({path:'/tmp/t28-dataset-online.png'});
    assert.equal(await content('B private pack').count(),0);
    // A second-page failure must never promote the first page or erase drafts.
    interrupt = true;
    await page.getByRole('button',{name:'Refresh dataset',exact:true}).click();
    await status(/Could not complete the operation/).waitFor();
    assert.equal(await content('A partial staging').count(),0);
    await content('A private pack').waitFor();
    await content('A durable local draft').waitFor();
    interrupt = false;
    await page.getByRole('button',{name:'Refresh dataset',exact:true}).click();
    await page.getByRole('button',{name:'Refresh dataset',exact:true}).waitFor({state:'visible'});
    await status(/Could not complete the operation/).waitFor({state:'hidden'});
    await page.getByRole('button',{name:'Refresh dataset',exact:true}).click({trial:true});
    await context.setOffline(true);
    await status(/Offline workspace — local edits only/).waitFor();
    await edit('A edited while offline',true);
    await page.reload();
    await enableSemantics();
    await status(/Offline workspace — local edits only/).waitFor();
    await content('A edited while offline').waitFor();
    await page.screenshot({path:'/tmp/t28-dataset-offline.png'});
    // Reconnect authorization is checked before any cached content reappears.
    revoked = true;
    await context.setOffline(false);
    await status('Access denied').waitFor();
    assert.equal(await content('A edited while offline').count(),0);
    assert.equal(await content('A private pack').count(),0);
    await context.setOffline(true);
    await page.reload();
    await enableSemantics();
    await status(/No completed authorized dataset is available/).waitFor();
    assert.equal(await content('A edited while offline').count(),0);
    // A new identity with no prior completed dataset cannot open offline.
    await page.evaluate(() => sessionStorage.setItem('biguess-browser-fixture-identity','new'));
    await page.reload();
    await enableSemantics();
    await status(/No completed authorized dataset is available/).waitFor();
    assert.equal(await content('A private pack').count(),0);
    // Resume online with B; A's saved records/drafts remain inaccessible.
    revoked = false;
    await context.setOffline(false);
    await page.goto(origin + '/my-packs?account=b');
    await enableSemantics();
    await content('B private pack').waitFor();
    assert.equal(await content('A private pack').count(),0);
    assert.equal(await content('A edited while offline').count(),0);
    await page.getByRole('button',{name:/^Account(?:\s|$)/}).click();
    await content('Sign out').click();
    await status('Sign in to BiGuess Studio').waitFor();
    assert.equal(await content('B private pack').count(),0);
    await context.setOffline(true);
    await page.reload();
    await enableSemantics();
    await status('Sign in to BiGuess Studio').waitFor();
    assert.equal(await content('B private pack').count(),0);
    assert.equal(requests.some(request => request.method !== 'GET'),false,'local save/queue must never upload');
    for (const response of returned) {
      assert(response.items.every(record => record.resourceType === 'topic' || record.id.endsWith('-' + response.uid)),
        'Collector never receives another contributor record');
    }
    const cachesOnlyStatic = await page.evaluate(async () => {
      for (const name of await caches.keys()) {
        const cache = await caches.open(name);
        for (const request of await cache.keys()) {
          const url = new URL(request.url);
          if (request.headers.has('Authorization') || url.search ||
            !(url.pathname.startsWith('/releases/') || ['/index.html','/studio-shell-register.js'].includes(url.pathname))) return false;
        }
      }
      return true;
    });
    assert.equal(cachesOnlyStatic,true,'private content never enters public/serviceworker caches');
    const stored = await page.evaluate(async () => {
      const db = await new Promise((resolve,reject) => {
        const request = indexedDB.open('biguess-studio-datasets');
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      });
      try {
        const values = [];
        for (const name of db.objectStoreNames) {
          const rows = await new Promise((resolve,reject) => {
            const request = db.transaction(name).objectStore(name).getAll();
            request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
          });
          values.push(...rows);
        }
        return JSON.stringify(values);
      } finally { db.close(); }
    });
    assert(!/Bearer|token-a|token-b/.test(stored),'dataset IndexedDB must contain no bearer tokens');
    assert.deepEqual(errors,[],'no browser runtime errors');
    await page.screenshot({path:'/tmp/t28-dataset-browser-final.png'});
    await context.close();
    console.log(`T28 dataset Chromium PASS: scoped initial paging, local draft/queue reload, interrupted sync rollback, offline edits/reload, revoked reconnect, first-offline denial, B isolation and sign-out cleanup; ${requests.length} private GETs, zero uploads.`);
  } catch (error) {
    if (diagnosticPage && !diagnosticPage.isClosed()) {
      console.error('Dataset browser diagnostics:',JSON.stringify({errors,requests,returned,body:await diagnosticPage.locator('body').innerText()}));
      await diagnosticPage.screenshot({path:'/tmp/t28-dataset-browser-failure.png'});
    }
    throw error;
  } finally {
    await browser.close(); await new Promise(resolve => server.close(resolve));
    fs.rmSync(temp,{recursive:true});
  }
})().catch(error => {console.error(error);server.close();process.exitCode=1;});
