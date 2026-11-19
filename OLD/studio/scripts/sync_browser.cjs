// T36 local-only acceptance against packaged Flutter, real IndexedDB and HTTP.
// Usage (from studio): node scripts/sync_browser.cjs
// Build test/browser_dataset_app.dart into build/dataset-web first.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const {spawnSync} = require('node:child_process');
const source = path.resolve(process.env.STUDIO_DATASET_WEB_ROOT || 'build/dataset-web');
const temp = fs.mkdtempSync(path.join(os.tmpdir(),'biguess-t36-browser-'));
const root = path.join(temp,'pages');
const config = path.join(temp,'public.json');
fs.writeFileSync(config,JSON.stringify({STUDIO_FIREBASE_API_KEY:'public-fixture-key',STUDIO_FIREBASE_APP_ID:'fixture-app',
  STUDIO_FIREBASE_PROJECT_ID:'browser-fixture',STUDIO_FIREBASE_AUTH_DOMAIN:'fixture.firebaseapp.com',
  STUDIO_FIREBASE_MESSAGING_SENDER_ID:'123',STUDIO_API_BASE_URL:'https://fixture-api.invalid'}));
const packaged = spawnSync('python3',[path.join(__dirname,'prepare_deployment.py'),'--source',source,'--output',root,
  '--commit','c'.repeat(40),'--public-config',config],{encoding:'utf8'});
assert.equal(packaged.status,0,packaged.stderr);
const types = {'.html':'text/html','.js':'text/javascript','.json':'application/json','.svg':'image/svg+xml',
  '.wasm':'application/wasm','.ttf':'font/ttf','.otf':'font/otf','.webp':'image/webp','.png':'image/png'};
const topic = {resourceType:'topic',id:'taxonomy',name:'Shared taxonomy',state:'active',revision:1};
const packs = new Map(['a','b'].map(uid => [`pack-${uid}`,{resourceType:'pack',id:`pack-${uid}`,
  topicId:'taxonomy',name:`${uid.toUpperCase()} private pack`,state:'active',revision:1}]));
const events = [];
const idempotency = new Map();
const requests = [];
let revoked = false;
const projection = (record,uid) => uid === 'owner'
  ? {...record,createdByUid:record.id.endsWith('-b') ? 'b' : 'a',createdAt:'2026-11-11T00:00:00Z'} : {...record};
const cursor = (uid,sequence) => Buffer.from(JSON.stringify([uid,sequence])).toString('base64url');
const envelope = (items,resumeCursor) => ({protocolVersion:1,scopeVersion:1,items,nextCursor:null,resumeCursor});
const server = http.createServer(async (req,res) => {
  const url = new URL(req.url,'http://localhost');
  if (url.pathname.startsWith('/studio/v1') || url.pathname.startsWith('/content/v1/studio')) {
    const uid = /^Bearer token-(a|b|owner)$/.exec(req.headers.authorization || '')?.[1];
    const log = {method:req.method,path:url.pathname,uid}; requests.push(log);
    res.setHeader('Cache-Control','no-store'); res.setHeader('Content-Type','application/json');
    const send = (status,body) => res.writeHead(status).end(JSON.stringify(body));
    const failure = (status,code) => send(status,{error:{code,message:code,requestId:'fixture',retryable:false,currentRevision:null}});
    if (!uid) return failure(401,'unauthenticated');
    if (revoked && uid === 'a') return failure(403,'forbidden');
    if (req.method === 'GET' && /\/(?:studio\/)?session$/.test(url.pathname)) {
      return send(200,{uid,email:`${uid}@fixture.test`,role:uid === 'owner' ? 'owner_admin' : 'collector'});
    }
    if (req.method === 'GET' && url.pathname === '/studio/v1/sync/initial') {
      const rows = [topic,...[...packs.values()].filter(p => uid === 'owner' || p.id === `pack-${uid}`)];
      log.items = rows.length;
      return send(200,envelope(rows.map(r => projection(r,uid)),cursor(uid,events.length)));
    }
    if (req.method === 'GET' && url.pathname === '/studio/v1/sync/changes') {
      let parsed;
      try { parsed = JSON.parse(Buffer.from(url.searchParams.get('cursor'),'base64url').toString()); } catch (_) {}
      if (!Array.isArray(parsed) || parsed[0] !== uid || !Number.isInteger(parsed[1]) || parsed[1] > events.length) {
        return failure(409,'cursor_expired');
      }
      const items = events.slice(parsed[1]).filter(r => uid === 'owner' || r.id === `pack-${uid}`)
        .map(r => ({kind:'upsert',record:projection(r,uid)}));
      log.items = items.length;
      return send(200,envelope(items,cursor(uid,events.length)));
    }
    if (req.method === 'POST' && url.pathname === '/studio/v1/batches') {
      let raw = ''; for await (const chunk of req) raw += chunk;
      let body; try { body = JSON.parse(raw); } catch (_) { return failure(400,'invalid_request'); }
      const {aggregate,operations} = body;
      if (aggregate?.resourceType !== 'pack' || !Array.isArray(operations) || operations.length !== 1) return failure(422,'invalid_batch');
      if (uid !== 'owner' && aggregate.id !== `pack-${uid}`) return failure(404,'not_found');
      const key = `${uid}:${req.headers['idempotency-key']}`;
      const fingerprint = JSON.stringify([body,req.headers['if-match'],req.headers['if-none-match']]);
      const replay = idempotency.get(key);
      if (replay) return replay.fingerprint === fingerprint ? send(200,replay.result) : failure(409,'idempotency_conflict');
      const previous = packs.get(aggregate.id);
      if (previous ? req.headers['if-match'] !== `"rev-${previous.revision}"` : req.headers['if-none-match'] !== '*') {
        return failure(412,'revision_conflict');
      }
      const op = operations[0];
      if (op.resourceType !== 'pack' || op.id !== aggregate.id || !['create','update'].includes(op.action)) return failure(422,'invalid_batch');
      const record = {resourceType:'pack',id:aggregate.id,name:op.value.name,topicId:op.value.topicId,
        state:previous?.state || 'active',revision:(previous?.revision || 0)+1};
      packs.set(record.id,record); events.push({...record});
      const result = {protocolVersion:1,aggregate,revision:record.revision,committedAt:new Date().toISOString(),actorId:uid};
      idempotency.set(key,{fingerprint,result}); log.revision = record.revision;
      return send(200,result);
    }
    return failure(404,'not_found');
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
  const errors = [];
  let diagnostic;
  try {
    const context = await browser.newContext({viewport:{width:1440,height:1100}});
    context.setDefaultTimeout(15000);
    const open = async (uid,ctx = context) => {
      const page = await ctx.newPage(); diagnostic = page;
      page.on('pageerror',error => errors.push(String(error)));
      await page.goto(`${origin}/my-packs?account=${uid}`);
      await page.locator('flt-glass-pane').waitFor({state:'attached'});
      const placeholder = page.locator('flt-semantics-placeholder');
      if (await placeholder.count()) await placeholder.evaluate(el => el.click());
      await page.getByRole('textbox',{name:'Search Packs',exact:true}).waitFor();
      return page;
    };
    const text = (page,value) => page.getByText(value,{exact:typeof value === 'string'})
      .or(page.getByLabel(value,{exact:false})).first();
    const type = async (page,name,value) => {
      const field = page.getByRole('textbox',{name,exact:true});
      await field.click(); await field.press('ControlOrMeta+A');
      if (value) await field.pressSequentially(value); else await field.press('Backspace');
      await page.evaluate(() => new Promise(requestAnimationFrame));
    };
    const edit = async (page,name,existing = false) => {
      await page.getByRole('button',{name:existing ? 'Edit local draft' : 'Edit Pack',exact:true}).click();
      await type(page,'Pack name',name);
      await page.getByRole('button',{name:'Save Pack draft locally',exact:true}).click();
      await type(page,'Search Packs','');
      await text(page,name).waitFor();
    };
    const queue = async page => {
      await page.getByRole('button',{name:'Queue commit',exact:true}).click();
      await text(page,'Unsent commit — queued locally').waitFor();
    };
    const commit = async page => {
      await page.getByRole('button',{name:'Commit queued changes',exact:true}).click();
      await text(page,/Last committed:/).waitFor();
      await page.getByRole('button',{name:'Refresh dataset',exact:true}).click({trial:true});
    };
    for (const uid of ['a','b','owner']) {
      const targetId = uid === 'owner' ? 'pack-a' : `pack-${uid}`;
      const page = await open(uid);
      await type(page,'Search Packs',packs.get(targetId).name);
      await text(page,packs.get(targetId).name).waitFor();
      if (uid !== 'owner') {
        assert.equal(await text(page,packs.get(uid === 'a' ? 'pack-b' : 'pack-a').name).count(),0,
          "Collectors cannot see each other's Packs");
      }
      const writes = requests.filter(r => r.method === 'POST').length;
      await context.setOffline(true);
      await text(page,/Offline workspace — local edits only/).waitFor();
      await type(page,'Search Packs','');
      if (uid === 'owner') await type(page,'Search Packs',packs.get(targetId).name);
      await edit(page,`${uid} offline rename`);
      await type(page,'Search Packs','');
      await queue(page);
      assert.equal(requests.filter(r => r.method === 'POST').length,writes,'offline save/queue never writes');
      await context.setOffline(false);
      await page.getByRole('button',{name:'Commit queued changes',exact:true}).click({trial:true});
      await commit(page);
      assert.equal(packs.get(targetId).name,`${uid} offline rename`);
      assert.equal(requests.filter(r => r.method === 'POST').length,writes+1);
      const initial = requests.filter(r => r.path.endsWith('/sync/initial')).length;
      const before = requests.length;
      await page.getByRole('button',{name:'Refresh dataset',exact:true}).click();
      await page.getByRole('button',{name:'Refresh dataset',exact:true}).click({trial:true});
      assert.equal(requests.filter(r => r.path.endsWith('/sync/initial')).length,initial);
      assert(requests.slice(before).some(r => r.path.endsWith('/sync/changes') && r.items === 0),'unchanged refresh is an empty feed');
      await page.close();
    }
    // Two tabs begin at the same local version. A saves; B's stale editor must
    // receive storage-conflict rather than replacing A's persisted draft.
    const first = await open('a'); const stale = await open('a');
    await stale.getByRole('button',{name:'Edit Pack',exact:true}).click();
    await type(stale,'Pack name','stale tab overwrite');
    await edit(first,'winning local tab');
    await stale.getByRole('button',{name:'Save Pack draft locally',exact:true}).click();
    await text(stale,/This change conflicts with newer data/).waitFor();
    await stale.getByRole('button',{name:'Cancel',exact:true}).click();
    await stale.reload();
    await text(stale,'winning local tab').waitFor();
    assert.equal(await text(stale,'stale tab overwrite').count(),0);
    // Separate browser storage holds an independently stale server revision.
    const remoteContext = await browser.newContext({viewport:{width:1440,height:1100}});
    remoteContext.setDefaultTimeout(15000);
    const remote = await open('owner',remoteContext);
    await type(remote,'Search Packs',packs.get('pack-a').name);
    await edit(remote,'remote winning revision'); await type(remote,'Search Packs',''); await queue(remote); await commit(remote);
    await queue(first);
    await first.getByRole('button',{name:'Commit queued changes',exact:true}).click();
    await text(first,/Commit conflict/).waitFor();
    assert.equal(packs.get('pack-a').name,'remote winning revision','stale server writer cannot overwrite');
    const retained = await first.evaluate(async () => {
      const db = await new Promise((resolve,reject) => {
        const request = indexedDB.open('biguess-studio-datasets');
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      });
      try {
        const rows = await new Promise((resolve,reject) => {
          const request = db.transaction('datasets').objectStore('datasets').getAll();
          request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
        });
        return rows.map(row => JSON.parse(row)).find(row => row.scope.uid === 'a').drafts;
      } finally { db.close(); }
    });
    assert.equal(retained[0].value.name,'winning local tab');
    assert.equal(retained[0].status,'conflict');
    const reads = requests.filter(r => /\/sync\//.test(r.path)).length;
    revoked = true;
    await first.getByRole('button',{name:'Refresh dataset',exact:true}).click();
    await text(first,'Access denied').waitFor();
    assert.equal(requests.filter(r => /\/sync\//.test(r.path)).length,reads,'revocation blocks new private reads');
    assert.equal(await text(first,'winning local tab').count(),0);
    assert.deepEqual(errors,[]);
    await remoteContext.close(); await context.close();
    console.log(`T36 Chromium PASS: two isolated Collectors/Owner offline edit → queued → explicit Commit → manual empty Refresh; local stale-tab CAS and remote 412 retain edits; revoked refresh blocks private reads. ${requests.length} fixture requests.`);
  } catch (error) {
    console.error('T36 diagnostics:',JSON.stringify({requests,errors}));
    if (diagnostic && !diagnostic.isClosed()) {
      console.error(await diagnostic.locator('body').ariaSnapshot());
      await diagnostic.screenshot({path:'/tmp/t36-browser-failure.png'});
    }
    throw error;
  } finally {
    await browser.close(); await new Promise(resolve => server.close(resolve)); fs.rmSync(temp,{recursive:true});
  }
})().catch(error => {console.error(error);server.close();process.exitCode=1;});
