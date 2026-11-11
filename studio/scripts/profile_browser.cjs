// T37 packaged Flutter + IndexedDB + HTTP fixture; no production identity/data.
// Build test/browser_dataset_app.dart into build/dataset-web before running.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const {spawnSync} = require('node:child_process');
const source = path.resolve(process.env.STUDIO_DATASET_WEB_ROOT || 'build/dataset-web');
const temp = fs.mkdtempSync(path.join(os.tmpdir(),'biguess-t37-browser-'));
const root = path.join(temp,'pages');
const config = path.join(temp,'public.json');
fs.writeFileSync(config,JSON.stringify({STUDIO_FIREBASE_API_KEY:'public-fixture-key',STUDIO_FIREBASE_APP_ID:'fixture-app',
  STUDIO_FIREBASE_PROJECT_ID:'browser-fixture',STUDIO_FIREBASE_AUTH_DOMAIN:'fixture.firebaseapp.com',
  STUDIO_FIREBASE_MESSAGING_SENDER_ID:'123',STUDIO_API_BASE_URL:'https://fixture-api.invalid'}));
const packaged = spawnSync('python3',[path.join(__dirname,'prepare_deployment.py'),'--source',source,'--output',root,
  '--commit','d'.repeat(40),'--public-config',config],{encoding:'utf8'});
assert.equal(packaged.status,0,packaged.stderr);
const types = {'.html':'text/html','.js':'text/javascript','.json':'application/json','.svg':'image/svg+xml',
  '.wasm':'application/wasm','.ttf':'font/ttf','.otf':'font/otf','.webp':'image/webp','.png':'image/png'};
const requests = [];
let ownerRole = 'owner_admin';
let revoked = false;
const principal = uid => ({uid,email:`${uid}@fixture.test`,role:uid==='owner'?ownerRole:'collector'});
const topic = {resourceType:'topic',id:'taxonomy',name:'Shared taxonomy',state:'active',revision:1};
const pack = uid => ({resourceType:'pack',id:`pack-${uid}`,topicId:'taxonomy',name:`Private ${uid}`,state:'active',revision:1});
const activity = [
  ['a','pack','pack-a-created','create'],['a','card','card-a-created','create'],['a','card','card-a-hidden','hide'],
  ['b','pack','pack-b-created','create'],['b','card','card-b-created','create'],['owner','topic','topic-owner-created','create'],
].map(([actorId,resourceType,resourceId,action],index)=>({batchId:`batch-${index}`,actorId,
  actorRole:actorId==='owner'?'owner_admin':'collector',resourceType,resourceId,action,revision:1,committedAt:'2026-11-11T10:00:00.000Z'}));
const counts = rows => {
  const result = {totalOperations:rows.length,topicsCreated:0,topicsRemoved:0,packsCreated:0,packsRemoved:0,
    cardsAdded:0,cardsRemoved:0,edits:0,hides:0,restores:0,permanentDeletes:0,activations:0};
  const field = {'topic:create':'topicsCreated','pack:create':'packsCreated','card:create':'cardsAdded','card:hide':'hides'};
  for (const row of rows) result[field[`${row.resourceType}:${row.action}`]]++;
  return result;
};
const server = http.createServer((req,res)=>{
  const url = new URL(req.url,'http://localhost');
  if (url.pathname.startsWith('/studio/v1') || url.pathname.startsWith('/content/v1/studio')) {
    const uid = /^Bearer token-(a|b|owner)$/.exec(req.headers.authorization||'')?.[1];
    const log = {method:req.method,path:url.pathname,uid,contributorUid:url.searchParams.get('contributorUid'),cursor:!!url.searchParams.get('cursor')};
    requests.push(log);
    res.setHeader('Cache-Control','no-store');res.setHeader('Content-Type','application/json');
    const send = (status,value)=>res.writeHead(status).end(JSON.stringify(value));
    const fail = (status,code)=>send(status,{protocolVersion:1,error:{code,message:code,requestId:'fixture',retryable:false,currentRevision:null}});
    if (!uid) return fail(401,'unauthenticated');
    if (revoked && uid==='a') return fail(403,'forbidden');
    if (req.method!=='GET') return fail(405,'method_not_allowed');
    if (url.pathname==='/content/v1/studio/session') return send(200,principal(uid));
    if (url.pathname==='/studio/v1/sync/initial') {
      const rows = [topic,...(principal(uid).role==='owner_admin'?['a','b'].map(pack):[pack(uid)])];
      return send(200,{protocolVersion:1,scopeVersion:1,items:rows,nextCursor:null,resumeCursor:`resume-${uid}-${ownerRole}`});
    }
    if (url.pathname==='/studio/v1/profile') {
      const owner=principal(uid).role==='owner_admin';
      if (!owner && url.searchParams.has('contributorUid')) return fail(403,'forbidden');
      const selected=url.searchParams.get('contributorUid');
      const rows=activity.filter(row=>owner?(selected===null||row.actorId===selected):row.actorId===uid);
      let offset=0;
      if (url.searchParams.has('cursor')) {
        let token;try{token=JSON.parse(Buffer.from(url.searchParams.get('cursor'),'base64url').toString());}catch(_){}
        if (!Array.isArray(token)||token[0]!==uid||token[1]!==principal(uid).role||token[2]!==selected||!Number.isInteger(token[3])) return fail(409,'cursor_expired');
        offset=token[3];
      }
      const next=offset+1<rows.length?Buffer.from(JSON.stringify([uid,principal(uid).role,selected,offset+1])).toString('base64url'):null;
      log.actorIds=rows.map(row=>row.actorId);
      return send(200,{protocolVersion:1,scopeVersion:1,principal:principal(uid),contributorUid:owner?selected:null,
        counts:counts(rows),contributors:owner?['a','b','owner'].map(id=>({...principal(id),counts:counts(activity.filter(row=>row.actorId===id))})):[],
        activity:rows.slice(offset,offset+1),nextCursor:next,asOf:'2026-11-11T12:00:00.000Z'});
    }
    return fail(404,'not_found');
  }
  const file=path.resolve(root,'.'+decodeURIComponent(url.pathname));
  if (!file.startsWith(root+path.sep)&&file!==root) return res.writeHead(403).end();
  const target=fs.existsSync(file)&&fs.statSync(file).isFile()?file:path.join(root,'index.html');
  res.writeHead(200,{'Content-Type':types[path.extname(target)]||'application/octet-stream','Cache-Control':url.pathname.startsWith('/releases/')?'public,max-age=31536000,immutable':'public,max-age=0,must-revalidate'});
  fs.createReadStream(target).pipe(res);
});
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin=`http://127.0.0.1:${server.address().port}`;
  const browser=await chromium.launch({...(process.env.CHROME_EXECUTABLE?{executablePath:process.env.CHROME_EXECUTABLE}:{}),args:['--no-sandbox']});
  const errors=[];const failedRequests=[];const consoleErrors=[];let diagnostic;
  try {
    const context=await browser.newContext({viewport:{width:1440,height:1100}});
    context.setDefaultTimeout(20000);
    const snapshot=page=>page.locator('body').ariaSnapshot();
    const until=async(condition,message)=>{
      const deadline=Date.now()+15000;
      while (!await condition()) {
        if (Date.now()>deadline) throw new Error(`Timed out: ${message}`);
        await new Promise(resolve=>setTimeout(resolve,50));
      }
    };
    const hasText=async(page,value)=>until(async()=>(await snapshot(page)).includes(value),value);
    const open=async uid=>{
      const page=await context.newPage();diagnostic=page;
      page.on('pageerror',error=>errors.push(String(error)));
      page.on('requestfailed',request=>failedRequests.push({url:request.url(),error:request.failure()?.errorText}));
      page.on('console',message=>{if(message.type()==='error')consoleErrors.push(message.text());});
      await page.goto(`${origin}/profile?account=${uid}`,{waitUntil:'domcontentloaded',timeout:30000});
      await page.locator('flt-glass-pane').waitFor({state:'attached'});
      const placeholder=page.locator('flt-semantics-placeholder');
      if (await placeholder.count()) await placeholder.evaluate(el=>el.click());
      await page.getByRole('button',{name:'Refresh profile',exact:true}).waitFor();
      await hasText(page,`Email: ${uid}@fixture.test`);
      return page;
    };
    const refresh=async(page,operations)=>{
      const before=requests.filter(r=>r.path==='/studio/v1/profile').length;
      await page.getByRole('button',{name:'Refresh profile',exact:true}).click();
      await until(()=>requests.filter(r=>r.path==='/studio/v1/profile').length>before,'profile response requested');
      await hasText(page,`Validated operations: ${operations}`);
      await page.getByRole('button',{name:'Refresh profile',exact:true}).click({trial:true});
    };
    for (const uid of ['a','b']) {
      const before=requests.filter(r=>r.path==='/studio/v1/profile').length;
      const page=await open(uid);
      assert.equal(requests.filter(r=>r.path==='/studio/v1/profile').length,before,'opening Profile never fetches statistics');
      await hasText(page,'Role: Collector');
      await refresh(page,uid==='a'?3:2);
      const rendered=await snapshot(page);
      assert(rendered.includes('Your contributions'));
      assert(!rendered.includes(`${uid==='a'?'b':'a'}@fixture.test`));
      assert(!rendered.includes('View contributor activity'));
      assert(requests.filter(r=>r.path==='/studio/v1/profile'&&r.uid===uid).every(r=>r.contributorUid===null&&r.actorIds.every(actor=>actor===uid)));
      await page.getByRole('button',{name:'Load more activity',exact:true}).click();
      await hasText(page,`card-${uid}-created`);
      if (uid==='a') {
        await page.getByRole('button',{name:'Load more activity',exact:true}).click();
        await hasText(page,'card-a-hidden');
      }
      assert.equal(await page.getByRole('button',{name:'Load more activity',exact:true}).count(),0);
      assert((await snapshot(page)).includes(`Validated operations: ${uid==='a'?3:2}`),'pagination preserves totals');
      if (uid==='b') {
        await page.setViewportSize({width:390,height:844});
        await refresh(page,2);
        assert((await snapshot(page)).includes('Your contributions'));
        assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>window.innerWidth),false,'narrow page has no horizontal overflow');
      }
      await page.close();
    }
    const owner=await open('owner');await hasText(owner,'Role: Owner');await refresh(owner,6);
    await hasText(owner,'All contributors');await hasText(owner,'b@fixture.test');
    await owner.getByRole('button',{name:'View contributor activity',exact:true}).nth(1).click();
    await hasText(owner,'Contributions by b');
    await hasText(owner,'Validated operations: 2');
    assert(requests.some(r=>r.path==='/studio/v1/profile'&&r.uid==='owner'&&r.contributorUid==='b'));
    ownerRole='collector';
    await refresh(owner,1);
    const downgraded=await snapshot(owner);
    assert(downgraded.includes('Role: Collector'));
    assert(downgraded.includes('Your contributions'));
    assert(!downgraded.includes('b@fixture.test'));
    assert(!downgraded.includes('View contributor activity'));
    await owner.close();
    const a=await open('a');await refresh(a,3);
    const profileReads=requests.filter(r=>r.path==='/studio/v1/profile'&&r.uid==='a').length;
    revoked=true;
    await a.getByRole('button',{name:'Refresh profile',exact:true}).click();
    await hasText(a,'Access denied');
    assert.equal(requests.filter(r=>r.path==='/studio/v1/profile'&&r.uid==='a').length,profileReads,'revoked access blocks profile reads');
    assert(!(await snapshot(a)).includes('card-a-created'));
    assert(!(await snapshot(a)).includes('Your contributions'));
    assert.deepEqual(errors,[]);
    await context.close();
    console.log(`T37 Chromium PASS: explicit Profile refresh; two isolated Collectors; authoritative identity/roles; Owner roster/filter; stable pagination; role downgrade/revocation clears private activity; 390px layout. ${requests.filter(r=>r.path==='/studio/v1/profile').length} synthetic profile requests.`);
  } catch(error) {
    console.error('T37 diagnostics:',JSON.stringify({requests,errors,failedRequests,consoleErrors}));
    if(diagnostic&&!diagnostic.isClosed()) {
      console.error(await diagnostic.locator('body').ariaSnapshot());
      await diagnostic.screenshot({path:'/tmp/t37-profile-browser-failure.png'});
    }
    throw error;
  } finally {
    await browser.close();await new Promise(resolve=>server.close(resolve));fs.rmSync(temp,{recursive:true});
  }
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
