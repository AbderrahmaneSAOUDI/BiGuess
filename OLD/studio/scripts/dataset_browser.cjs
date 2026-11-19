// Actual packaged Flutter + IndexedDB + session/controller integration. The
// alternate test entrypoint supplies only synthetic identity; no production
// Firebase account, Worker deployment, auth bypass or real content is involved.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const crypto = require('node:crypto');
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
let packRevision = 1;
let deniedCardCollector = false;
const topic = {resourceType:'topic',id:'taxonomy',name:'Shared taxonomy',state:'active',revision:1};
const hiddenTopic = {resourceType:'topic',id:'taxonomy-hidden',name:'Hidden classification',state:'hidden',revision:2};
const seasonalTopic = {resourceType:'topic',id:'taxonomy-seasonal',name:'Seasonal Topic',state:'active',revision:1};
const retiredTopic = {resourceType:'topic',id:'taxonomy-retire',name:'Retire Topic',state:'active',revision:1};
const deletedTopic = {resourceType:'topic',id:'taxonomy-deleted',name:'Deleted Topic',state:'deleted',revision:3};
const sharedTaxonomy = [topic,hiddenTopic,seasonalTopic,retiredTopic].sort((a,b) => a.id.localeCompare(b.id));
const ownerProjection = record => ({...record,createdByUid:record.id === 'pack-legacy' ? null : record.resourceType === 'topic' ? 'fixture-private-author' : record.id.endsWith('-b') ? 'b' : 'a',createdAt:'2026-11-10T00:00:00.000Z'});
function pack(uid, partial = false) {return {resourceType:'pack',id:`pack-${uid}`,topicId:'taxonomy',
  name:partial ? `${uid.toUpperCase()} partial staging` : `${uid.toUpperCase()} private pack`,state:'active',revision:packRevision};}
function card(uid) {return {resourceType:'card',id:`card-${uid}`,packId:`pack-${uid}`,name:`${uid.toUpperCase()} private card`,
  imageReference:`opaque-${uid}`,difficulty:1,state:'active',revision:1};}
const server = http.createServer((req,res) => {
  const url = new URL(req.url,'http://localhost');
  if (url.pathname.startsWith('/studio/v1') || url.pathname.startsWith('/content/v1')) {
    const uid = /^Bearer token-(a|b|new|owner)$/.exec(req.headers.authorization || '')?.[1];
    requests.push({method:req.method,path:url.pathname,uid});
    res.setHeader('Cache-Control','no-store'); res.setHeader('Content-Type','application/json');
    if (!uid) return res.writeHead(401).end(JSON.stringify({error:{code:'unauthenticated'}}));
    if ((revoked && uid === 'a') || (deniedCardCollector && uid === 'b')) return res.writeHead(403).end(JSON.stringify({error:{code:'forbidden'}}));
    if (req.method !== 'GET') return res.writeHead(405).end('{}');
    if (url.pathname === '/content/v1/studio/session') return res.end(JSON.stringify({uid,email:`${uid}@fixture.test`,role:uid === 'owner' ? 'owner_admin' : 'collector'}));
    if (url.pathname === '/studio/v1/sync/initial') {
      const cursor = url.searchParams.get('cursor');
      if (cursor && cursor !== `${uid}-page2`) return res.writeHead(409).end(JSON.stringify({error:{code:'cursor_expired'}}));
      if (cursor && interrupt) return res.writeHead(503).end(JSON.stringify({error:{code:'storage-unavailable'}}));
      const items = uid === 'owner'
        ? (cursor ? [card('a'),card('b'),{...card('a'),id:'card-deleted',name:'Deleted Card fixture',state:'deleted',revision:3}] : [...[...sharedTaxonomy,deletedTopic].sort((a,b) => a.id.localeCompare(b.id)),pack('a'),pack('b'),
          {resourceType:'pack',id:'pack-legacy',topicId:'taxonomy',name:'Unassigned legacy Pack',state:'active',revision:1},
          {resourceType:'pack',id:'pack-deleted',topicId:'taxonomy',name:'Deleted Pack',state:'deleted',revision:3}]).map(ownerProjection)
        : cursor ? [card(uid)] : [...sharedTaxonomy,pack(uid,interrupt)];
      returned.push({uid,items});
      return res.end(JSON.stringify({protocolVersion:1,scopeVersion:1,items,nextCursor:cursor ? null : `${uid}-page2`,
        resumeCursor:cursor ? `resume-${uid}` : null}));
    }
    if (url.pathname === '/studio/v1/sync/changes') {
      const cursor = url.searchParams.get('cursor');
      if (cursor && interrupt) return res.writeHead(503).end(JSON.stringify({error:{code:'storage-unavailable'}}));
      const items = uid === 'owner' && packRevision === 2
        ? [{kind:'upsert',record:ownerProjection(pack('a'))}]
        : [];
      return res.end(JSON.stringify({protocolVersion:1,scopeVersion:1,items,nextCursor:null,
        resumeCursor:cursor ? `${cursor}-next` : `resume-${uid}-next`}));
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
    const content = name => page.getByText(name,{exact:true}).or(page.getByLabel(name,{exact:false})).or(page.getByText(name,{exact:false})).first();
    const typeField = async (name,value) => {
      const field = page.getByRole('textbox',{name,exact:true});
      // Flutter owns the editing DOM: a pointer focus plus actual key input
      // avoids changing an unfocused semantics proxy that is then replaced.
      await field.click();
      await field.press('ControlOrMeta+A');
      if (value) await field.pressSequentially(value); else await field.press('Backspace');
      await page.evaluate(() => new Promise(requestAnimationFrame));
    };
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
    const edit = async (name, existing = false, keyboard = false) => {
      await page.getByRole('button',{name:existing ? 'Edit local draft' : 'Edit Pack',exact:true}).click();
      await typeField('Pack name',name);
      if (keyboard) await page.getByRole('textbox',{name:'Pack name',exact:true}).press('Enter');
      else await page.getByRole('button',{name:'Save Pack draft locally',exact:true}).click();
      await typeField('Search Packs','');
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
    console.log('T28 browser lifecycle regression passed; starting T29 Topic and classification flows.');
    // T29: Owner authoring remains local, explicit and durable. The server fixture
    // exposes global Owner data, while Collector taxonomy remains minimal.
    await context.setOffline(false);
    await page.goto(origin + '/topics?account=owner');
    await enableSemantics();
    const search = page.getByRole('textbox',{name:'Search Topics',exact:true});
    await search.waitFor();
    await content('Shared taxonomy').waitFor();
    const syncCalls = () => requests.filter(request => request.path === '/studio/v1/sync/initial').length;
    const priorSearchCalls = syncCalls();
    await typeField('Search Topics','Seasonal');
    await content('Seasonal Topic').waitFor();
    assert.equal(await content('Shared taxonomy').count(),0,'Topic search uses local names');
    assert.equal(syncCalls(),priorSearchCalls,'search does not fetch per keystroke');
    await page.getByRole('button',{name:'Hide Topic',exact:true}).click();
    await page.getByRole('button',{name:'Queue Topic commit',exact:true}).waitFor();
    await content('Hide Topic').waitFor();
    await page.getByRole('button',{name:'Queue Topic commit',exact:true}).click();
    await content('Unsent').waitFor();
    await typeField('Search Topics','Retire Topic');
    await page.getByRole('button',{name:'Delete Topic',exact:true}).click();
    await page.getByRole('button',{name:'Save deletion locally',exact:true}).waitFor();
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    assert.equal(await page.getByRole('button',{name:'Queue Topic commit',exact:true}).count(),0,
      'cancelling destructive confirmation must not create a pending deletion');
    await page.getByRole('button',{name:'Delete Topic',exact:true}).click();
    await page.getByRole('button',{name:'Save deletion locally',exact:true}).click();
    await page.getByRole('button',{name:'Queue Topic commit',exact:true}).click();
    await typeField('Search Topics','Deleted Topic');
    await page.getByRole('button',{name:'Restore Topic',exact:true}).click();
    await page.getByRole('button',{name:'Save restoration locally',exact:true}).click();
    await page.getByRole('button',{name:'Queue Topic commit',exact:true}).click();
    await typeField('Search Topics','Shared taxonomy');
    await page.getByRole('button',{name:'Rename Topic',exact:true}).click();
    await typeField('Topic name','Renamed taxonomy');
    await page.getByRole('button',{name:'Save Topic locally',exact:true}).click();
    await typeField('Search Topics','Renamed taxonomy');
    await content('Renamed taxonomy').waitFor();
    await page.getByRole('button',{name:'Queue Topic commit',exact:true}).click();
    await typeField('Search Topics','');
    await page.getByRole('button',{name:'New Topic',exact:true}).click();
    await typeField('Topic name','Owner local Topic');
    await page.getByRole('button',{name:'Save Topic locally',exact:true}).click();
    await typeField('Search Topics','Owner local Topic');
    await page.getByRole('button',{name:'Queue Topic commit',exact:true}).click();
    await page.reload();
    await enableSemantics();
    await typeField('Search Topics','Owner local Topic');
    await content('Owner local Topic').waitFor();
    await page.screenshot({path:'/tmp/t29-topics-owner.png'});
    await page.goto(origin + '/my-packs?account=owner');
    await enableSemantics();
    await page.getByRole('button',{name:'New Pack draft',exact:true}).click();
    await typeField('Pack name','Uncommitted parent attempt');
    await typeField('Find a Topic','Owner local Topic');
    await status('No Topics match this search.').waitFor();
    await page.getByRole('button',{name:'Save Pack draft locally',exact:true}).click();
    await status('Enter a Pack name and choose an eligible Topic.').waitFor();
    // A local restoration is not a server-restored parent yet; neither it nor
    // a pending deletion may be used to create a dependent Pack draft.
    for (const unavailable of ['Deleted Topic','Retire Topic']) {
      await typeField('Find a Topic',unavailable);
      await status('No Topics match this search.').waitFor();
      await page.getByRole('button',{name:'Save Pack draft locally',exact:true}).click();
      await status('Enter a Pack name and choose an eligible Topic.').waitFor();
    }
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    console.log('T29 Owner Topic authoring/queue reload and orphan-parent exclusions passed.');
    // Collector sees permitted labels/states only, with no administrative actions.
    await page.goto(origin + '/topics?account=b');
    await enableSemantics();
    await content('Hidden classification').waitFor();
    assert.equal(await content('Deleted Topic').count(),0);
    assert.equal(await content('fixture-private-author').count(),0);
    for (const name of ['New Topic','Rename Topic','Hide Topic','Delete Topic','Restore Topic','Queue Topic commit']) {
      assert.equal(await page.getByRole('button',{name,exact:true}).count(),0,`Collector must not get ${name}`);
    }
    // A separate My Packs entry assigns a real eligible Topic ID to a durable
    // local Pack create draft. It does not require opening the Topic editor.
    await page.setViewportSize({width:360,height:920});
    await page.goto(origin + '/my-packs?account=b');
    await enableSemantics();
    await page.getByRole('button',{name:'New Pack draft',exact:true}).waitFor();
    await page.getByRole('button',{name:'New Pack draft',exact:true}).click();
    await typeField('Pack name','B classified draft');
    await typeField('Find a Topic','Deleted Topic');
    await status('No Topics match this search.').waitFor();
    await page.getByRole('button',{name:'Save Pack draft locally',exact:true}).click();
    await status('Enter a Pack name and choose an eligible Topic.').waitFor();
    await typeField('Find a Topic','Hidden classification');
    await page.getByRole('button',{name:/Topic/}).or(page.getByRole('combobox',{name:/Topic/})).last().click();
    // Target Flutter's actionable menu item, not its tooltip/announcement span.
    await page.getByRole('menuitem',{name:/Hidden classification/}).click().catch(async error => {
      console.error('Topic picker accessibility tree:',await page.locator('body').ariaSnapshot());
      throw error;
    });
    await page.screenshot({path:'/tmp/t29-pack-picker-mobile.png'});
    await page.getByRole('button',{name:'Save Pack draft locally',exact:true}).click();
    await content('B classified draft').waitFor();
    await page.getByRole('button',{name:'Queue commit',exact:true}).click();
    await content('Unsent commit — queued locally').waitFor();
    await page.reload();
    await enableSemantics();
    await content('B classified draft').waitFor();
    await page.screenshot({path:'/tmp/t29-collector-picker-mobile.png'});
    // Inspect the durable payload rather than trusting a visual label: parent ID
    // is the synchronized hidden Topic, with no client-selected creator metadata.
    const classifiedDraft = await page.evaluate(async () => {
      const db = await new Promise((resolve,reject) => {
        const request = indexedDB.open('biguess-studio-datasets');
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      });
      try {
        const values = await new Promise((resolve,reject) => {
          const request = db.transaction('datasets').objectStore('datasets').getAll();
          request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
        });
        const snapshot = values.map(value => JSON.parse(value)).find(value => value.scope.uid === 'b');
        return snapshot.drafts.find(draft => draft.value.name === 'B classified draft');
      } finally { db.close(); }
    });
    assert.equal(classifiedDraft.value.topicId,'taxonomy-hidden');
    assert.equal(classifiedDraft.action,'create');
    assert.equal(classifiedDraft.status,'unsent');
    assert.equal(classifiedDraft.value.createdByUid,undefined);
    assert.equal(classifiedDraft.value.ownerUid,undefined);
    console.log('T29 classification passed; starting T30 Pack lifecycle flows.');
    await page.setViewportSize({width:1440,height:1100});
    await page.goto(origin + '/my-packs?account=owner');
    await enableSemantics();
    for (const name of ['A private pack','B private pack','Unassigned legacy Pack','Deleted Pack']) {
      await content(name).waitFor();
    }
    await content('Creator: Unassigned legacy draft').waitFor();
    const packSyncCalls = syncCalls();
    await typeField('Search Packs','Unassigned legacy Pack');
    await content('Unassigned legacy Pack').waitFor();
    assert.equal(await content('A private pack').count(),0);
    assert.equal(syncCalls(),packSyncCalls,'Pack search is local');
    await content('Draft — no eligible Cards; not playable or publishable').waitFor();
    await typeField('Search Packs','A private pack');
    await edit('Owner stale Pack edit',false,true);
    packRevision = 2;
    await page.getByRole('button',{name:'Refresh dataset',exact:true}).click();
    await typeField('Search Packs','A private pack');
    await content('Conflict — review before queueing').waitFor();
    assert.equal(await page.getByRole('button',{name:'Queue commit',exact:true}).count(),0,
      'a stale Pack edit cannot be queued');
    await page.getByRole('button',{name:'Discard local change',exact:true}).click();
    // Deletion, restoration and permanent deletion each need explicit Owner
    // confirmation. Cancelling leaves the synchronized record untouched.
    for (const [query,action,confirm] of [
      ['A private pack','Delete Pack','delete'],
      ['Deleted Pack','Restore Pack','restore'],
      ['Deleted Pack','Permanently delete Pack','permanently delete'],
    ]) {
      await typeField('Search Packs',query);
      await page.getByRole('button',{name:action,exact:true}).click();
      await page.getByRole('button',{name:'Cancel',exact:true}).click();
      assert.equal(await page.getByRole('button',{name:'Queue commit',exact:true}).count(),0);
      await page.getByRole('button',{name:action,exact:true}).click();
      await page.getByRole('button',{name:`Confirm local ${confirm}`,exact:true}).click();
      await page.getByRole('button',{name:'Queue commit',exact:true}).click();
      await content('Unsent commit — queued locally').waitFor();
      await page.getByRole('button',{name:'Discard local change',exact:true}).click();
    }
    await typeField('Search Packs','B private pack');
    await page.getByRole('button',{name:'Hide Pack',exact:true}).click();
    await page.getByRole('button',{name:'Queue commit',exact:true}).click();
    await content('Unsent commit — queued locally').waitFor();
    await page.reload();
    await enableSemantics();
    await typeField('Search Packs','B private pack');
    await content('Unsent commit — queued locally').waitFor();
    await page.screenshot({path:'/tmp/t30-owner-packs.png'});
    await page.goto(origin + '/my-packs?account=b');
    await enableSemantics();
    await content('B classified draft').waitFor();
    for (const name of ['Delete Pack','Restore Pack','Permanently delete Pack']) {
      assert.equal(await page.getByRole('button',{name,exact:true}).count(),0);
    }
    assert.equal(await content('Unassigned legacy Pack').count(),0);
    assert.equal(await content('A private pack').count(),0);
    console.log('T30 Pack lifecycle passed; starting T31 Card authoring flows.');
    const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGNkqHj2n4GBgYGJAQoAIyICYTlsIJwAAAAASUVORK5CYII=','base64');
    const preview = () => page.getByRole('img',{name:'Selected image preview',exact:true}).or(page.getByLabel('Selected image preview',{exact:true})).last();
    const selectImage = async (button,filename) => {
      const selection = page.waitForEvent('filechooser');
      await page.getByRole('button',{name:button,exact:true}).click();
      await (await selection).setFiles({name:filename,mimeType:'image/png',buffer:png});
      await preview().waitFor();
      // The pipeline may normalize the output filename and extension. The
      // persisted candidate below verifies its final format and metadata.
    };
    const chooseCardPack = async (name,id) => {
      await page.getByRole('button',{name:/^Pack(?:\s|$)/}).or(page.getByRole('combobox',{name:/^Pack(?:\s|$)/})).last().click();
      await page.getByRole('menuitem',{name:new RegExp(`${name}.*${id}`)}).click();
    };
    const storedCard = async (uid,name) => page.evaluate(async ({uid,name}) => {
      const db = await new Promise((resolve,reject) => {
        const request = indexedDB.open('biguess-studio-datasets');
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      });
      try {
        const values = await new Promise((resolve,reject) => {
          const request = db.transaction('datasets').objectStore('datasets').getAll();
          request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
        });
        const snapshot = values.map(value => JSON.parse(value)).find(value => value.scope.uid === uid);
        return name == null ? snapshot?.drafts.filter(draft => draft.resourceType === 'card')
          : snapshot?.drafts.find(draft => draft.resourceType === 'card' && draft.value.name === name);
      } finally { db.close(); }
    },{uid,name});
    // Card review is reachable within the scoped Pack; it never requires Topic
    // administration or an unrestricted global Card lookup.
    await typeField('Search Packs','B private pack');
    await page.getByRole('button',{name:'Review Cards',exact:true}).click();
    await content('B private card').waitFor();
    assert.equal(await content('A private card').count(),0);
    await page.getByRole('button',{name:'Close Card review',exact:true}).click();
    await page.goto(origin + '/cards?account=b');
    await enableSemantics();
    await chooseCardPack('B private pack','pack-b');
    await page.getByRole('button',{name:'New Card',exact:true}).click();
    await page.getByRole('button',{name:'Save Card locally',exact:true}).click();
    assert.equal(await page.getByRole('button',{name:'Queue Card commit',exact:true}).count(),0,
      'an incomplete Card is not silently persisted');
    await selectImage('Select image','Ada_Lovelace.png');
    await page.getByRole('textbox',{name:'Card name',exact:true}).click();
    await page.waitForFunction(() => [...document.querySelectorAll('input,textarea')].some(field => field.value === 'Ada Lovelace'));
    assert.equal(await page.getByRole('textbox',{name:'Card name',exact:true}).inputValue(),'Ada Lovelace');
    await page.screenshot({path:'/tmp/t31-card-preview-desktop.png'});
    await typeField('Card name','B browser identity');
    await page.getByRole('button',{name:/Difficulty/}).or(page.getByRole('combobox',{name:/Difficulty/})).last().click();
    await page.getByRole('menuitem',{name:'3 — Hard',exact:true}).click();
    await page.getByRole('button',{name:'Save Card locally',exact:true}).click();
    await content('B browser identity').waitFor();
    const originalCard = await storedCard('b','B browser identity');
    assert.equal(originalCard.value.packId,'pack-b');
    assert.equal(originalCard.value.difficulty,3);
    assert.equal(originalCard.localImage.filename,'Ada Lovelace.webp');
    assert.equal(originalCard.localImage.preparation.width,2);
    assert.equal(originalCard.localImage.preparation.height,2);
    assert.equal(originalCard.localImage.preparation.sha256,crypto.createHash('sha256').update(Buffer.from(originalCard.localImage.base64,'base64')).digest('hex'),
      'the persisted preparation hash describes normalized output bytes');
    assert.equal(originalCard.localImage.mimeType,'image/webp','Chromium supports metadata-free WebP output');
    assert.equal(originalCard.value.createdByUid,undefined);
    assert.equal(originalCard.value.ownerUid,undefined);
    // The batch preparation panel reviews normalized candidates serially. It
    // detects duplicates and corrupt inputs without creating extra Card drafts.
    await page.getByRole('button',{name:'Prepare images',exact:true}).click();
    const batchSelection = page.waitForEvent('filechooser');
    await page.getByRole('button',{name:'Select images',exact:true}).click();
    await (await batchSelection).setFiles([
      {name:'First_pixel.png',mimeType:'image/png',buffer:png},
      {name:'Renamed_duplicate.png',mimeType:'image/png',buffer:png},
      {name:'Broken_input.png',mimeType:'image/png',buffer:Buffer.from([0,1,2,3])},
    ]);
    await content('1 prepared · 1 duplicates · 1 failed').waitFor();
    await page.screenshot({path:'/tmp/t32-preparation-summary.png'});
    await page.getByRole('button',{name:'Close image preparation',exact:true}).click();
    const afterPreparation = await storedCard('b','B browser identity');
    assert.equal((await storedCard('b',null)).length,1,'batch preparation must not create extra Cards');
    assert.equal(afterPreparation.resourceId,originalCard.resourceId);
    assert.equal(afterPreparation.localImage.preparation.sha256,originalCard.localImage.preparation.sha256);
    // Replace locally while offline and retain the generated canonical Card ID.
    await context.setOffline(true);
    await status(/Offline workspace — local edits only/).waitFor();
    await chooseCardPack('B private pack','pack-b');
    await typeField('Search Cards','B browser identity');
    await page.getByRole('button',{name:'Edit Card',exact:true}).click();
    await selectImage('Replace image','Replacement_identity.png');
    await page.getByRole('textbox',{name:'Card name',exact:true}).click();
    await page.waitForFunction(() => [...document.querySelectorAll('input,textarea')].some(field => field.value === 'B browser identity'));
    assert.equal(await page.getByRole('textbox',{name:'Card name',exact:true}).inputValue(),'B browser identity',
      'replacement filenames never overwrite an edited name');
    await page.getByRole('button',{name:'Save Card locally',exact:true}).click();
    await page.getByRole('button',{name:'Queue Card commit',exact:true}).click();
    await content('Unsent commit — queued locally').waitFor();
    await page.reload();
    await enableSemantics();
    await chooseCardPack('B private pack','pack-b');
    await content('B browser identity').waitFor();
    const replacementCard = await storedCard('b','B browser identity');
    assert.equal(replacementCard.resourceId,originalCard.resourceId,'image replacement retains the Card ID');
    assert.equal(replacementCard.localImage.filename,'Replacement identity.webp');
    assert.equal(replacementCard.localImage.preparation.sha256,originalCard.localImage.preparation.sha256,
      'equal input pixels deduplicate across different candidate filenames');
    assert.equal(replacementCard.status,'unsent');
    for (const action of ['Delete Card','Restore Card','Permanently delete Card']) {
      assert.equal(await page.getByRole('button',{name:action,exact:true}).count(),0);
    }
    await page.setViewportSize({width:360,height:920});
    await typeField('Search Cards','B browser identity');
    await page.getByRole('button',{name:'Edit Card',exact:true}).click();
    await preview().waitFor();
    await page.screenshot({path:'/tmp/t31-card-preview-mobile.png'});
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    await context.setOffline(false);
    await page.goto(origin + '/cards?account=a');
    await enableSemantics();
    await content('A private card').waitFor();
    assert.equal(await content('B private card').count(),0);
    assert.equal(await content('B browser identity').count(),0,'Collector local Cards remain account-isolated');
    // Clear the Owner's prior pending Pack hide before reviewing its children.
    await page.setViewportSize({width:1440,height:1100});
    await page.goto(origin + '/my-packs?account=owner');
    await enableSemantics();
    await typeField('Search Packs','B private pack');
    await page.getByRole('button',{name:'Discard local change',exact:true}).click();
    await page.getByRole('button',{name:'Edit Pack',exact:true}).waitFor();
    await page.goto(origin + '/cards?account=owner');
    await enableSemantics();
    for (const [query,action,confirm] of [
      ['A private card','Delete Card','delete'],
      ['Deleted Card fixture','Restore Card','restore'],
      ['Deleted Card fixture','Permanently delete Card','permanently delete'],
    ]) {
      await typeField('Search Cards',query);
      await page.getByRole('button',{name:action,exact:true}).click();
      await page.getByRole('button',{name:'Cancel',exact:true}).click();
      assert.equal(await page.getByRole('button',{name:'Queue Card commit',exact:true}).count(),0);
      await page.getByRole('button',{name:action,exact:true}).click();
      await page.getByRole('button',{name:`Confirm local ${confirm}`,exact:true}).click();
      await page.getByRole('button',{name:'Queue Card commit',exact:true}).click();
      await content('Unsent commit — queued locally').waitFor();
      await page.getByRole('button',{name:'Discard Card change',exact:true}).click();
    }
    await typeField('Search Cards','A private card');
    await page.getByRole('button',{name:'Hide Card',exact:true}).click();
    await page.getByRole('button',{name:'Queue Card commit',exact:true}).click();
    await content('Unsent commit — queued locally').waitFor();
    await page.screenshot({path:'/tmp/t31-owner-cards.png'});
    // A live denial closes an open Card editor and clears selected-image previews.
    await page.goto(origin + '/cards?account=b');
    await enableSemantics();
    await chooseCardPack('B private pack','pack-b');
    await context.setOffline(true);
    await status(/Offline workspace — local edits only/).waitFor();
    await chooseCardPack('B private pack','pack-b');
    await typeField('Search Cards','B browser identity');
    await page.getByRole('button',{name:'Edit Card',exact:true}).click();
    await preview().waitFor();
    deniedCardCollector = true;
    await context.setOffline(false);
    await status('Access denied').waitFor();
    assert.equal(await preview().count(),0);
    assert.equal(await content('B browser identity').count(),0);
    for (const response of returned.filter(response => response.uid !== 'owner')) {
      for (const record of response.items.filter(record => record.resourceType === 'topic')) {
        assert.deepEqual(Object.keys(record).sort(),['id','name','resourceType','revision','state']);
        assert(!['deleted','purged'].includes(record.state));
      }
    }
    assert.equal(requests.some(request => request.method !== 'GET'),false,'local save/queue must never upload');
    for (const response of returned.filter(response => response.uid !== 'owner')) {
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
    assert(!/Bearer|token-(?:a|b|owner|new)/.test(stored),'dataset IndexedDB must contain no bearer tokens');
    assert.deepEqual(errors,[],'no browser runtime errors');
    await page.screenshot({path:'/tmp/t28-dataset-browser-final.png'});
    await context.close();
    console.log(`T28/T29/T30/T31/T32 dataset Chromium PASS: Normalized Card picker output, persisted dimensions/content hash and content deduplication; Card file selection/preview/name suggestion, difficulty, offline image replacement with stable ID and durable queue, isolated collectors, Owner lifecycle confirmations and live-denial cleanup; Owner global/legacy Pack view, stale edit, confirmed delete/restore/purge and durable hide; Owner Topic create/rename/hide/delete/restore/search and queued reload, Collector minimal taxonomy and independent mobile Pack classification;  scoped initial paging, local draft/queue reload, interrupted sync rollback, offline edits/reload, revoked reconnect, first-offline denial, B isolation and sign-out cleanup; ${requests.length} private GETs, zero uploads.`);
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
