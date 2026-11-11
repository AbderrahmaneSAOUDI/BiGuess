import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { root, workerModules } from '../scripts/local.mjs';

const project = 'biguess-profile-test';
const keys = await generateKeyPair('RS256');
const jwk = { ...await exportJWK(keys.publicKey), kid: 'profile-key', alg: 'RS256', use: 'sig' };
const users = ['owner','a','b','zero'].map(uid => ({ uid, email: `${uid}@example.test`,
  role: uid === 'owner' ? 'owner_admin' : 'collector' }));
const origin = 'https://studio.saoudi.online';
const image = readFileSync(new URL('../fixtures/image.webp', import.meta.url));
const imageReference = `objects/${createHash('sha256').update(image).digest('hex')}.webp`;
const op = (resourceType,id,action,value) => ({ resourceType,id,action,...(value === undefined ? {} : {value}) });
async function signed(uid, firebaseProject = project) {
  const now = Math.floor(Date.now()/1000);
  return new SignJWT({ sub:uid,email:`${uid}@example.test`,email_verified:true,
    firebase:{sign_in_provider:'google.com'},aud:firebaseProject,iss:`https://securetoken.google.com/${firebaseProject}`,
    iat:now-10,auth_time:now-20,exp:now+3600 }).setProtectedHeader({alg:'RS256',kid:jwk.kid}).sign(keys.privateKey);
}
async function body(response,status=200,code) {
  assert.equal(response.status,status,await response.clone().text());
  assert.equal(response.headers.get('Cache-Control'),'no-store');
  const result = await response.json();
  if (code) assert.equal(result.error.code,code);
  return result;
}
async function setup(t, {firebaseProject = project, pinnedUid} = {}) {
  const tokens = Object.fromEntries(await Promise.all(users.map(async user => [user.uid,await signed(user.uid, firebaseProject)])));
  const bindings = {APP_ENV:'staging',FIREBASE_PROJECT_ID:firebaseProject, ...(pinnedUid ? {STUDIO_SUPER_ADMIN_UID:pinnedUid} : {}),STUDIO_USERS:JSON.stringify(users),STUDIO_ALLOWED_ORIGINS:JSON.stringify([origin])};
  const options = {modules:workerModules(`${root}dist/index.js`),scriptPath:`${root}dist/index.js`,compatibilityDate:'2026-11-01',bindings,
    d1Databases:{DB:'profile-database'},r2Buckets:{CONTENT:'profile-images'},outboundService:request => {
      assert.equal(request.url,'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com');
      return Response.json({keys:[jwk]});
    }};
  const mf = new Miniflare(convertV4MiniflareOptions(options)); t.after(() => mf.dispose());
  let db = await mf.getD1Database('DB');
  for (const file of readdirSync(`${root}migrations`).filter(file=>file.endsWith('.sql')).sort()) {
    await db.exec(readFileSync(`${root}migrations/${file}`,'utf8').split('\n').filter(line=>!line.trim().startsWith('--')).join(' '));
  }
  await (await mf.getR2Bucket('CONTENT')).put(imageReference,image,{httpMetadata:{contentType:'image/webp'}});
  const request = (path,{actor='a',method='GET',value,headers={}}={}) => mf.dispatchFetch(`https://api.example${path}`,{method,
    headers:{...(actor ? {Authorization:`Bearer ${tokens[actor]}`} : {}),Origin:origin,...(value ? {'Content-Type':'application/json'} : {}),...headers},
    ...(value ? {body:JSON.stringify(value)} : {})});
  const commit = (kind,id,operations,revision,{actor='owner',key=randomUUID()}={}) => request('/studio/v1/batches',{actor,method:'POST',value:{protocolVersion:1,aggregate:{resourceType:kind,id},operations},headers:{'Idempotency-Key':key,...(revision===0?{'If-None-Match':'*'}:{'If-Match':`"rev-${revision}"`})}});
  const profile = async (actor='a',query='') => body(await request(`/studio/v1/profile${query}`,{actor}));
  const raw = () => db.prepare('SELECT rowid AS sequence,* FROM studio_audit ORDER BY rowid').all().then(r=>r.results);
  const setUsers = async next => { options.bindings = {...options.bindings,STUDIO_USERS:JSON.stringify(next)}; await mf.setOptions(convertV4MiniflareOptions(options)); db = await mf.getD1Database('DB'); };
  const setPinned = async uid => { options.bindings = {...options.bindings,STUDIO_SUPER_ADMIN_UID:uid}; await mf.setOptions(convertV4MiniflareOptions(options)); db = await mf.getD1Database('DB'); };
  await body(await commit('topic','topic',[op('topic','topic','create',{name:'Shared taxonomy'})],0));
  for (const uid of ['a','b']) {
    await db.prepare('INSERT INTO studio_pack_images VALUES (?,?,?,?)').bind(`pack-${uid}`,imageReference,'owner',new Date().toISOString()).run();
    await body(await commit('pack',`pack-${uid}`,[op('pack',`pack-${uid}`,'create',{name:`Private ${uid}`,topicId:'topic'}),op('card',`card-${uid}`,'create',{name:`Private ${uid}`,packId:`pack-${uid}`,imageReference,difficulty:1})],0,{actor:uid}));
  }
  return {request,commit,profile,raw,setUsers,setPinned,db};
}
const cursorQuery = cursor => `?limit=1&cursor=${encodeURIComponent(cursor)}`;
const recognized = row => row.action !== 'batch' && ['create','update','hide','activate','softDelete','restore','permanentDelete'].includes(row.action);
const assertReconciled = (counts,rows) => {
  assert.equal(counts.totalOperations,rows.filter(recognized).length);
  assert.equal(counts.totalOperations,Object.entries(counts).filter(([key])=>key!=='totalOperations').reduce((sum,[,value])=>sum+value,0));
};

test('profile identity and statistics are actor-scoped for two Collectors; Owner sees all and zero contributors',async t=>{
  const s=await setup(t); const raw=await s.raw();
  for (const actor of ['a','b']) {
    const p=await s.profile(actor);
    assert.deepEqual(p.principal,users.find(user=>user.uid===actor));
    assert.equal(p.contributorUid,null); assert.deepEqual(p.contributors,[]);
    assert.equal(p.counts.packsCreated,1); assert.equal(p.counts.cardsAdded,1); assert.equal(p.counts.topicsCreated,0);
    assertReconciled(p.counts,raw.filter(row=>row.actor_id===actor));
    assert(p.activity.every(row=>row.actorId===actor && row.resourceId.endsWith(actor)));
    for (const row of p.activity) assert.deepEqual(Object.keys(row).sort(),['batchId','actorId','actorRole','resourceType','resourceId','action','revision','committedAt'].sort());
    assert(!JSON.stringify(p).includes(`pack-${actor==='a'?'b':'a'}`));
    assert.equal(p.nextCursor,null); assert(Number.isFinite(Date.parse(p.asOf)));
  }
  const owner=await s.profile('owner');
  assertReconciled(owner.counts,raw); assert.equal(owner.counts.totalOperations,5);
  assert.deepEqual(owner.contributors.map(c=>c.uid),['a','b','owner','zero']);
  for (const contributor of owner.contributors) assertReconciled(contributor.counts,raw.filter(row=>row.actor_id===contributor.uid));
  assert.equal(owner.contributors.find(c=>c.uid==='zero').counts.totalOperations,0);
  const filtered=await s.profile('owner','?contributorUid=b');
  assert.equal(filtered.contributorUid,'b'); assert.equal(filtered.counts.totalOperations,2);
  assert(filtered.activity.every(row=>row.actorId==='b')); assert.equal(filtered.contributors.length,4);
  const alias=await body(await s.request('/content/v1/studio/profile',{actor:'b'}));
  assert.deepEqual(alias.counts,(await s.profile('b')).counts);
});

test('only validated audit operations count; retries do not inflate and later deletion/purge preserves creation credit',async t=>{
  const s=await setup(t); const key=randomUUID();
  const update=[op('pack','pack-a','update',{name:'Changed a',topicId:'topic'})];
  await body(await s.commit('pack','pack-a',update,1,{actor:'a',key}));
  await body(await s.commit('pack','pack-a',update,1,{actor:'a',key}));
  await body(await s.commit('pack','pack-a',update,1,{actor:'a'}),412,'revision_conflict');
  await body(await s.commit('pack','pack-a',update,2,{actor:'b'}),404,'not_found');
  await body(await s.commit('pack','pack-a',[op('card','card-a','hide')],2,{actor:'a'}));
  await body(await s.commit('pack','pack-a',[op('pack','pack-a','softDelete')],3));
  await body(await s.commit('pack','pack-a',[op('card','card-a','permanentDelete')],4));
  await body(await s.commit('pack','pack-a',[op('pack','pack-a','permanentDelete')],5));
  const raw=await s.raw(); assert(raw.some(row=>row.action==='batch'),'fixture exercises synthetic Pack rollup');
  const a=await s.profile(); assert.equal(a.counts.totalOperations,4); assert.equal(a.counts.cardsAdded,1); assert.equal(a.counts.packsCreated,1);
  assert.equal(a.counts.edits,1); assert.equal(a.counts.hides,1); assert.equal(a.counts.packsRemoved,0);
  const owner=await s.profile('owner'); assertReconciled(owner.counts,raw);
  assert.equal(owner.counts.packsRemoved,1); assert.equal(owner.counts.cardsRemoved,1); assert.equal(owner.counts.permanentDeletes,2);
  const b=await s.profile('b'); assert.equal(b.counts.totalOperations,2); assert.equal(b.counts.cardsRemoved,0);
  await assert.rejects(s.db.prepare("UPDATE studio_audit SET action='create'").run(),/immutable_audit/);
  await assert.rejects(s.db.prepare('DELETE FROM studio_audit').run(),/immutable_audit/);
});

test('encrypted pagination freezes counts and activity; cursors cannot cross accounts, roles or selectors',async t=>{
  const s=await setup(t); const first=await s.profile('a','?limit=1');
  assert(first.nextCursor); assert.equal(first.activity.length,1);
  assert(!first.nextCursor.includes('pack-a'));
  await body(await s.commit('pack','pack-a',[op('pack','pack-a','update',{name:'After snapshot',topicId:'topic'})],1,{actor:'a'}));
  const next=await s.profile('a',cursorQuery(first.nextCursor));
  assert.equal(next.counts.totalOperations,2); assert.equal(next.asOf,first.asOf); assert.equal(next.nextCursor,null);
  assert.notDeepEqual(next.activity,first.activity); assert.equal(next.activity[0].action,'create');
  assert.equal((await s.profile('a')).counts.totalOperations,3);
  await body(await s.request(`/studio/v1/profile${cursorQuery(first.nextCursor)}`,{actor:'b'}),409,'cursor_expired');
  const owner=await s.profile('owner','?limit=1');
  await body(await s.request(`/studio/v1/profile${cursorQuery(owner.nextCursor)}&contributorUid=a`,{actor:'owner'}),409,'cursor_expired');
  await s.setUsers(users.map(u=>u.uid==='a'?{...u,role:'owner_admin'}:u));
  await body(await s.request(`/studio/v1/profile${cursorQuery(first.nextCursor)}`),409,'cursor_expired');
  await s.setUsers(users.filter(u=>u.uid!=='a'));
  await body(await s.request(`/studio/v1/profile${cursorQuery(first.nextCursor)}`),403,'forbidden');
});

test('private routing rejects anonymous, forged selectors, malformed inputs and public aliases without leaking records',async t=>{
  const s=await setup(t);
  for (const path of ['/studio/v1/profile','/content/v1/studio/profile']) {
    await body(await s.request(path,{actor:null}),401,'unauthenticated');
    for (const query of ['?contributorUid=b','?contributorUid=a']) {
      const denied=await body(await s.request(path+query),403,'forbidden');
      assert.equal(denied.activity,undefined); assert.equal(denied.counts,undefined);
    }
    await body(await s.request(path,{headers:{Origin:'https://foreign.example'}}),403,'forbidden');
    for (const query of ['?actorId=b','?role=owner_admin','?limit=0','?limit=101','?limit=1&limit=2','?unknown=x']) {
      await body(await s.request(path+query),400,'invalid_request');
    }
    await body(await s.request(path+'?cursor=invalid'),409,'cursor_expired');
  }
  assert.equal((await s.request('/content/v1/profile',{actor:null})).status,404);
  assert.equal((await s.request('/studio/v1/profile',{method:'POST',value:{contributorUid:'b'}})).status,404);
});

test('Owner retains historical contributor credit after allowlist removal without inventing a current role',async t=>{
  const s=await setup(t); await s.setUsers(users.filter(u=>u.uid!=='b'));
  const owner=await s.profile('owner'); const departed=owner.contributors.find(c=>c.uid==='b');
  assert.equal(departed.email,null); assert.equal(departed.role,null); assert.equal(departed.counts.totalOperations,2);
  const historical=await s.profile('owner','?contributorUid=b'); assert.equal(historical.activity.length,2);
  const a=await s.profile('a'); assert.deepEqual(a.contributors,[]); assert(a.activity.every(row=>row.actorId==='a'));
  await body(await s.request('/studio/v1/profile',{actor:'b'}),403,'forbidden');
});


test('another Owner sees pinned superadmin authority outside the allowlist and pin changes invalidate Owner cursors', async t => {
  const s = await setup(t, {firebaseProject:'biguess-firebase',pinnedUid:'pinned-owner'});
  const owner = await s.profile('owner','?limit=1');
  const pinned = owner.contributors.find(c => c.uid === 'pinned-owner');
  assert.equal(pinned.email,'abderrahmane.saoudi.26@gmail.com');
  assert.equal(pinned.role,'owner_admin');
  assert.equal(pinned.counts.totalOperations,0);
  await s.setPinned('new-pinned-owner');
  await body(await s.request(`/studio/v1/profile${cursorQuery(owner.nextCursor)}`,{actor:'owner'}),409,'cursor_expired');
  const refreshed = await s.profile('owner');
  assert.equal(refreshed.contributors.find(c=>c.uid==='new-pinned-owner').role,'owner_admin');
  assert.equal(refreshed.contributors.find(c=>c.uid==='pinned-owner'),undefined);
});


test('Owner contributor filters preserve opaque Firebase UIDs rather than applying content-ID rules', async t => {
  const s=await setup(t);
  const uid='opaque contributor uid/with punctuation';
  const result=await s.profile('owner','?contributorUid='+encodeURIComponent(uid));
  assert.equal(result.contributorUid,uid);
  assert.equal(result.counts.totalOperations,0);
  assert.deepEqual(result.activity,[]);
  await body(await s.request('/studio/v1/profile?contributorUid=',{actor:'owner'}),400,'invalid_request');
  await body(await s.request('/studio/v1/profile?contributorUid='+ 'x'.repeat(129),{actor:'owner'}),400,'invalid_request');
});
