// T32A real browser -> cross-origin local gateway -> production Workerd/D1/R2.
// Only the standalone fixture substitutes synthetic identities for signed test
// Firebase JWTs. No production identity, credentials, bucket or network is used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const crypto = require('node:crypto');
const {createRequire} = require('node:module');
const {spawnSync} = require('node:child_process');
const {chromium} = require('playwright');
const repo = path.resolve(__dirname, '../..');
const backend = path.join(repo, 'backend/content-api');
const backendRequire = createRequire(path.join(backend, 'package.json'));
const {Miniflare, convertV4MiniflareOptions} = backendRequire('miniflare');
const source = path.resolve(process.env.STUDIO_DATASET_WEB_ROOT || path.join(repo, 'studio/build/dataset-web'));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'biguess-image-ingestion-browser-'));
const root = path.join(temp, 'pages');
const project = 'browser-ingestion-fixture';
const requests = [];
const errors = [];
let mf;
let apiServer;
let dropNextUploadResponse = false;
let responseDropped = false;
const types = {'.html':'text/html','.js':'text/javascript','.json':'application/json','.svg':'image/svg+xml',
  '.wasm':'application/wasm','.ttf':'font/ttf','.otf':'font/otf','.webp':'image/webp','.png':'image/png'};
let csp;
const webServer = http.createServer((req,res) => {
  const url = new URL(req.url,'http://localhost');
  const file = path.resolve(root,'.' + decodeURIComponent(url.pathname));
  if (!file.startsWith(root + path.sep) && file !== root) return res.writeHead(403).end();
  const target = fs.existsSync(file) && fs.statSync(file).isFile() ? file : path.join(root,'index.html');
  res.writeHead(200,{'Content-Type':types[path.extname(target)] || 'application/octet-stream',
    ...(csp ? {'Content-Security-Policy':csp} : {}),
    'Cache-Control':url.pathname.startsWith('/releases/') ? 'public,max-age=31536000,immutable' : 'no-store'});
  fs.createReadStream(target).pipe(res);
});
const badOriginServer = http.createServer((_,res) => res.end('<!doctype html><title>Unapproved origin fixture</title>'));
const listen = server => new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
const originOf = server => `http://127.0.0.1:${server.address().port}`;
const close = async server => {
  server.closeAllConnections?.();
  await new Promise(resolve => server.close(resolve));
};

(async () => {
  const {generateKeyPair,exportJWK,SignJWT} = await import(backendRequire.resolve('jose'));
  const {workerModules} = await import(path.join(backend,'scripts/local.mjs'));
  const keys = await generateKeyPair('RS256');
  const jwk = {...await exportJWK(keys.publicKey),kid:'ingestion-browser-key',alg:'RS256',use:'sig'};
  const users = ['owner','a','b'].map(uid => ({uid,email:`${uid}@fixture.test`,role:uid==='owner'?'owner_admin':'collector'}));
  const now = Math.floor(Date.now()/1000);
  const tokens = Object.fromEntries(await Promise.all(users.map(async user => [user.uid,
    await new SignJWT({sub:user.uid,email:user.email,email_verified:true,
      firebase:{sign_in_provider:'google.com'},aud:project,iss:`https://securetoken.google.com/${project}`,
      iat:now-10,auth_time:now-20,exp:now+3600}).setProtectedHeader({alg:'RS256',kid:jwk.kid}).sign(keys.privateKey)])));
  await listen(webServer);
  await listen(badOriginServer);
  const webOrigin = originOf(webServer);
  const options = {modules:workerModules(path.join(backend,'dist/index.js')),
    scriptPath:path.join(backend,'dist/index.js'),compatibilityDate:'2026-11-01',
    bindings:{APP_ENV:'staging',FIREBASE_PROJECT_ID:project,STUDIO_USERS:JSON.stringify(users),STUDIO_ALLOWED_ORIGINS:JSON.stringify([webOrigin])},
    d1Databases:{DB:'ingestion-browser-db'},r2Buckets:{CONTENT:'ingestion-browser-images'},
    outboundService:request => {
      assert.equal(request.url,'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com');
      return Response.json({keys:[jwk]});
    }};
  mf = new Miniflare(convertV4MiniflareOptions(options));
  const db = await mf.getD1Database('DB');
  const bucket = await mf.getR2Bucket('CONTENT');
  for (const file of fs.readdirSync(path.join(backend,'migrations')).filter(f=>f.endsWith('.sql')).sort()) {
    await db.exec(fs.readFileSync(path.join(backend,'migrations',file),'utf8').split('\n').filter(line=>!line.trim().startsWith('--')).join(' '));
  }
  apiServer = http.createServer(async (req,res) => {
    try {
      const headers = new Headers();
      for (const [key,value] of Object.entries(req.headers)) if (value !== undefined && !['host','connection','content-length','accept-encoding'].includes(key)) headers.set(key,Array.isArray(value)?value.join(','):value);
      const actor = /^Bearer token-(owner|a|b)$/.exec(headers.get('authorization')||'')?.[1];
      if (actor) headers.set('authorization',`Bearer ${tokens[actor]}`);
      const chunks=[];for await (const chunk of req) chunks.push(chunk);
      const body = Buffer.concat(chunks);
      const record = {method:req.method,path:new URL(req.url,'http://localhost').pathname,origin:req.headers.origin??null,actor,bytes:body.length};
      requests.push(record);
      const response = await mf.dispatchFetch('https://api.fixture'+req.url,{method:req.method,headers,...(body.length?{body}: {})});
      record.status=response.status;
      const bytes=Buffer.from(await response.arrayBuffer());
      if (dropNextUploadResponse && req.method==='POST' && record.path.endsWith('/images') && response.status===200) {
        // Start a response before truncating it so Chromium cannot transparently
        // retry a POST whose connection closed before any headers arrived.
        dropNextUploadResponse=false;responseDropped=true;
        res.writeHead(200,{'Content-Type':'application/json','Content-Length':bytes.length+128,
          'Access-Control-Allow-Origin':webOrigin,'Cache-Control':'no-store','Vary':'Origin'});
        res.write(bytes.subarray(0,16));setTimeout(()=>res.destroy(),20);return;
      }
      res.writeHead(response.status,Object.fromEntries(response.headers));res.end(bytes);
    } catch (error) { console.error('Fixture gateway failure:',error);res.writeHead(500).end('{}'); }
  });
  await listen(apiServer);
  const apiOrigin = originOf(apiServer);
  const config = path.join(temp,'public.json');
  fs.writeFileSync(config,JSON.stringify({STUDIO_FIREBASE_API_KEY:'public-fixture-key',STUDIO_FIREBASE_APP_ID:'fixture-app',
    STUDIO_FIREBASE_PROJECT_ID:'browser-fixture',STUDIO_FIREBASE_AUTH_DOMAIN:'fixture.firebaseapp.com',
    STUDIO_FIREBASE_MESSAGING_SENDER_ID:'123',STUDIO_API_BASE_URL:apiOrigin}));
  const packaged=spawnSync('python3',[path.join(__dirname,'prepare_deployment.py'),'--source',source,'--output',root,'--commit','c'.repeat(40),'--public-config',config],{encoding:'utf8'});
  assert.equal(packaged.status,0,packaged.stderr);
  csp = /^  Content-Security-Policy: (.+)$/m.exec(fs.readFileSync(path.join(root,'_headers'),'utf8'))?.[1];
  assert(csp?.includes(apiOrigin),'actual package CSP permits the isolated API origin');
  const direct = async (route,{actor='owner',method='GET',body,headers={}}={}) => {
    const response=await mf.dispatchFetch('https://api.fixture'+route,{method,headers:{Authorization:`Bearer ${tokens[actor]}`,Origin:webOrigin,...(body?{'Content-Type':'application/json'}:{}),...headers},...(body?{body:JSON.stringify(body)}:{})});
    const text=await response.text();assert.equal(response.status,200,text);return JSON.parse(text);
  };
  const op=(resourceType,id,value)=>({resourceType,id,action:'create',value});
  const commit=async (aggregate,operations,actor='owner',revision=0)=>direct('/studio/v1/batches',{actor,method:'POST',body:{protocolVersion:1,aggregate,operations},headers:{'Idempotency-Key':crypto.randomUUID(),...(revision===0?{'If-None-Match':'*'}:{'If-Match':`"rev-${revision}"`})}});
  await commit({resourceType:'topic',id:'topic'},[op('topic','topic',{name:'Image fixtures'})]);
  for (const uid of ['a','b']) await commit({resourceType:'pack',id:`pack-${uid}`},[op('pack',`pack-${uid}`,{name:`Private ${uid} Pack`,topicId:'topic'})],uid);
  const browser=await chromium.launch({...(process.env.CHROME_EXECUTABLE?{executablePath:process.env.CHROME_EXECUTABLE}:{}),args:['--no-sandbox']});
  let page;
  try {
    const context=await browser.newContext({viewport:{width:1440,height:1100}});
    page=await context.newPage();
    page.on('pageerror',error=>errors.push(String(error)));
    const enableSemantics=async()=>{
      await page.locator('flt-glass-pane').waitFor({state:'attached'});
      const placeholder=page.locator('flt-semantics-placeholder');if(await placeholder.count())await placeholder.evaluate(el=>el.click());
    };
    const content=name=>page.getByText(name,{exact:true}).or(page.getByLabel(name,{exact:false})).or(page.getByText(name,{exact:false})).first();
    const stored=async()=>page.evaluate(async()=>{
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('biguess-studio-datasets');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
      try {const rows=await new Promise((resolve,reject)=>{const r=db.transaction('datasets').objectStore('datasets').getAll();r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
        return rows.map(r=>JSON.parse(r)).find(r=>r.scope.uid==='a')?.drafts.find(d=>d.resourceType==='card');
      } finally {db.close();}
    });
    await page.goto(`${webOrigin}/cards?account=a&api=${encodeURIComponent(apiOrigin)}`);
    await enableSemantics();
    await page.getByRole('button',{name:'New Card',exact:true}).waitFor();
    await page.getByRole('button',{name:'New Card',exact:true}).click();
    const selection=page.waitForEvent('filechooser');
    await page.getByRole('button',{name:'Select image',exact:true}).click();
    const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGNkqHj2n4GBgYGJAQoAIyICYTlsIJwAAAAASUVORK5CYII=','base64');
    await (await selection).setFiles({name:'Private_candidate.png',mimeType:'image/png',buffer:png});
    await page.getByRole('img',{name:'Selected image preview',exact:true}).or(page.getByLabel('Selected image preview',{exact:true})).last().waitFor();
    await page.getByRole('button',{name:'Save Card locally',exact:true}).click();
    await content('Private candidate').waitFor();
    const local=await stored();assert(local?.localImage?.preparation,'T32 normalized candidate persisted before upload');
    assert.equal((await db.prepare("SELECT count(*) n FROM studio_entities WHERE resource_type='card'").first()).n,0,'local save did not mutate Cards');
    await page.getByRole('button',{name:'Upload image privately',exact:true}).click();
    await content('Image uploaded privately — Card commit is still pending.').waitFor();
    const uploaded=await stored();
    assert.equal(uploaded.resourceId,local.resourceId);
    assert.equal(uploaded.uploadedImage.sha256,local.localImage.preparation.sha256);
    assert.equal(uploaded.value.imageReference,uploaded.uploadedImage.imageReference);
    assert.equal((await db.prepare("SELECT count(*) n FROM studio_entities WHERE resource_type='card'").first()).n,0,'upload did not implicitly Commit a Card');
    const grants=await db.prepare('SELECT object_reference FROM studio_pack_images WHERE pack_id=?').bind('pack-a').all();
    assert.equal(grants.results.length,1);
    const staged=await db.prepare('SELECT staging_key FROM studio_image_uploads WHERE pack_id=? AND object_reference=?')
      .bind('pack-a',grants.results[0].object_reference).first();
    const object=await bucket.get(staged.staging_key);assert(object,'trusted binding refers to private staged R2 bytes');
    assert.equal(await bucket.head(grants.results[0].object_reference),null,'upload does not create a canonical published-object candidate before Commit');
    assert.equal(crypto.createHash('sha256').update(Buffer.from(await object.arrayBuffer())).digest('hex'),uploaded.uploadedImage.sha256);
    const countAfterUpload=(await bucket.list()).objects.length;
    await page.reload();await enableSemantics();
    await content('Image uploaded privately — Card commit is still pending.').waitFor();
    assert.equal((await stored()).uploadedImage.imageReference,uploaded.uploadedImage.imageReference,'receipt survives browser reload');

    // Browser fetches run against the second actual origin, exercising native
    // preflight and production CORS. Each request still verifies Firebase JWTs.
    const fetchImage=async ({packId='pack-a',actor='a',hash=uploaded.uploadedImage.sha256,mime=local.localImage.mimeType,base64=local.localImage.base64,revision=1}={})=>page.evaluate(async({api,packId,actor,hash,mime,base64,revision})=>{
      const bytes=Uint8Array.from(atob(base64),c=>c.charCodeAt(0));
      try {const r=await fetch(`${api}/studio/v1/packs/${packId}/images`,{method:'POST',headers:{Authorization:`Bearer token-${actor}`,'Content-Type':mime,'X-Content-SHA256':hash,'If-Match':`"rev-${revision}"`},body:bytes});return {status:r.status,body:await r.json()};}
      catch(e){return {networkError:true};}
    },{api:apiOrigin,packId,actor,hash,mime,base64,revision});
    const retry=await fetchImage();assert.equal(retry.status,200);assert.equal(retry.body.imageReference,uploaded.uploadedImage.imageReference);
    assert.equal((await bucket.list()).objects.length,countAfterUpload,'same-content retries do not grow storage');
    dropNextUploadResponse=true;
    const interrupted=await fetchImage();assert(interrupted.networkError&&responseDropped,'lost upload response surfaced as retryable network failure');
    const recovered=await fetchImage();assert.equal(recovered.status,200);assert.equal(recovered.body.imageReference,uploaded.uploadedImage.imageReference);
    assert.equal((await bucket.list()).objects.length,countAfterUpload,'lost response retry remains deduplicated');
    const foreign=await fetchImage({packId:'pack-b'});assert.equal(foreign.status,404);assert.equal(foreign.body.error.code,'not_found');
    const other=await fetchImage({actor:'b'});assert.equal(other.status,404);
    const badHash=await fetchImage({hash:'0'.repeat(64)});assert.equal(badHash.status,422,'claimed hash is independently checked');
    const badBytes=Buffer.from('This is not an encoded image');
    const invalid=await fetchImage({base64:badBytes.toString('base64'),hash:crypto.createHash('sha256').update(badBytes).digest('hex')});
    assert.equal(invalid.status,422,'correctly hashed corrupt bytes rejected');
    assert.equal((await bucket.list()).objects.length,countAfterUpload,'rejected requests do not create objects');
    const preflight=requests.find(r=>r.method==='OPTIONS'&&r.path.endsWith('/images')&&r.status===204);
    assert(preflight,'browser issued an accepted actual cross-origin upload preflight');
    assert.equal(preflight.origin,webOrigin);

    const stranger=await context.newPage();
    await stranger.goto(originOf(badOriginServer));
    const denied=await stranger.evaluate(async({api,base64,hash})=>{
      try {await fetch(api+'/studio/v1/packs/pack-a/images',{method:'POST',headers:{Authorization:'Bearer token-a','Content-Type':'image/webp','X-Content-SHA256':hash,'If-Match':'"rev-1"'},body:Uint8Array.from(atob(base64),c=>c.charCodeAt(0))});return false;}catch(_){return true;}
    },{api:apiOrigin,base64:local.localImage.base64,hash:uploaded.uploadedImage.sha256});
    assert(denied,'unapproved origin is blocked by browser CORS');
    assert(requests.some(r=>r.method==='OPTIONS'&&r.origin===originOf(badOriginServer)&&r.status===403));
    await stranger.close();
    const unauthorized=await fetch(apiOrigin+'/studio/v1/packs/pack-a/images',{method:'POST',headers:{Origin:webOrigin,'Content-Type':local.localImage.mimeType,'X-Content-SHA256':uploaded.uploadedImage.sha256,'If-Match':'"rev-1"'},body:Buffer.from(local.localImage.base64,'base64')});
    assert.equal(unauthorized.status,401,'approved CORS origin does not authorize anonymous upload');
    for (const route of ['/'+grants.results[0].object_reference,'/'+staged.staging_key,'/content/v1/'+grants.results[0].object_reference,'/studio/v1/packs/pack-a/images']) {
      const response=await fetch(apiOrigin+route);assert([401,404].includes(response.status),'uncommitted images have no anonymous bytes route');
    }
    await page.getByRole('button',{name:'Queue Card commit',exact:true}).click();
    await content('Unsent commit — queued locally').waitFor();
    const queued=await stored();
    // A separate, explicit T24 Commit attaches the returned scoped reference.
    // Queue transport itself remains T36; no automatic mutation follows upload.
    const attached=await commit({resourceType:'pack',id:'pack-a'},[op('card',queued.resourceId,queued.value)],'a',1);
    assert.equal(attached.revision,2);
    const serverCard=(await direct('/studio/v1/cards/'+encodeURIComponent(queued.resourceId),{actor:'a'})).item;
    assert.equal(serverCard.id,queued.resourceId);
    assert.equal(serverCard.imageReference,uploaded.uploadedImage.imageReference);
    const rawCard=await db.prepare("SELECT value FROM studio_entities WHERE resource_type='card' AND id=?").bind(queued.resourceId).first();
    assert.equal(JSON.parse(rawCard.value).imageReference,grants.results[0].object_reference,'Commit resolves scoped binding to private verified object');
    const stolen=await mf.dispatchFetch('https://api.fixture/studio/v1/batches',{method:'POST',headers:{Authorization:`Bearer ${tokens.b}`,Origin:webOrigin,'Content-Type':'application/json','If-Match':'"rev-1"','Idempotency-Key':crypto.randomUUID()},body:JSON.stringify({protocolVersion:1,aggregate:{resourceType:'pack',id:'pack-b'},operations:[op('card','stolen-card',{...queued.value,packId:'pack-b'})]})});
    assert.equal(stolen.status,404,'another Collector cannot attach a foreign Pack image capability');
    const publicTopics=await mf.dispatchFetch('https://api.fixture/content/v1/catalog/topics');
    assert.equal(publicTopics.status,200);
    assert.equal((await publicTopics.json()).items.length,0,'private drafts cannot become public through ingestion or attachment');
    assert.deepEqual(errors,[],'no browser runtime errors');
    await page.screenshot({path:'/tmp/t32a-image-ingestion.png'});
    console.log(`T32A ingestion Chromium/Workerd PASS: actual cross-origin preflight, T32 normalization and UI private upload, durable receipt/reload, retry/dedup and lost-response recovery, hash/corruption/IDOR/origin/auth denials, unpublished privacy, explicit T24 Card attachment retaining ID; ${requests.filter(r=>r.method==='OPTIONS').length} preflights, ${requests.filter(r=>r.method==='POST'&&r.path.endsWith('/images')).length} upload attempts.`);
  } catch(error) {
    if(page&&!page.isClosed()) {console.error('Ingestion diagnostics:',JSON.stringify({errors,requests,body:await page.locator('body').innerText()}));await page.screenshot({path:'/tmp/t32a-ingestion-failure.png'});}
    throw error;
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(async()=>{
  if(apiServer)await close(apiServer);if(mf)await mf.dispose();await close(webServer);await close(badOriginServer);fs.rmSync(temp,{recursive:true,force:true});
});
