import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, readdirSync, writeFileSync, cpSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { createHash, generateKeyPairSync, randomUUID } from 'node:crypto';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { root, workerModules } from '../scripts/local.mjs';
import { prepare } from '../scripts/prepare.mjs';

const sha = value => createHash('sha256').update(value).digest('hex');
const canonical = value => Array.isArray(value) ? `[${value.map(canonical).join(',')}]`
  : value && typeof value === 'object' ? `{${Object.keys(value).sort().map(k=>`${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`
    : JSON.stringify(value);
const temporary = mkdtempSync(join(tmpdir(),'biguess-legacy-import-'));
process.on('exit',()=>rmSync(temporary,{recursive:true,force:true}));
const fixtureDirectory = join(temporary,'source');
cpSync(new URL('../../../test/fixtures/cleared_shapes',import.meta.url),fixtureDirectory,{recursive:true});
const original = JSON.parse(readFileSync(join(fixtureDirectory,'pack.json'),'utf8'));
const topicId = 'legacy:topic:Shapes';
const packId = 'legacy:pack:Shapes:Geometric%20Shapes';
const source = structuredClone(original);
source.topic.id = topicId; source.pack.id = packId;
source.cards.forEach(card=>{
  card.id = `legacy:card:Shapes:Geometric%20Shapes:${encodeURIComponent(`assets/images/Shapes/Geometric Shapes/${card.image}`)}`;
  card.pack_id = packId; card.difficulty = 1;
});
writeFileSync(join(fixtureDirectory,'pack.json'),JSON.stringify(source));
const archive = join(temporary,'cleared-test.biguesspack');
execFileSync('python3',['../../scripts/export_pack.py','fixture',join(fixtureDirectory,'pack.json'),'--revision','1','--output',archive],{cwd:root,stdio:'pipe'});
const signer = generateKeyPairSync('ed25519').privateKey.export({type:'pkcs8',format:'pem'});
const publication = prepare(archive,signer);
const manifest = JSON.parse(Buffer.from(publication.manifest,'base64'));
const provenance = {rights_status:'unverified',permission_to_publish:false,public_test_publishable:false,
  source:'bundled_legacy_assets',license:'unverified',attribution:'Unverified / respective owners',
  quarantine_reason:'Synthetic legacy import quarantine fixture.',notes:null};
function withHash(bundle) {
  const core = {protocolVersion:bundle.protocolVersion,inventorySha256:bundle.inventorySha256,workerSha256:bundle.workerSha256,records:bundle.records};
  return {...bundle,importId:sha(canonical(core))};
}
function legacyBundle() {
  const records = [
    {resourceType:'topic',id:topicId,name:'Shapes',inventoryId:original.topic.id},
    {resourceType:'pack',id:packId,parentId:topicId,name:'Geometric Shapes',inventoryId:original.pack.id},
    ...manifest.cards.map(card=>{
      const originalCard = original.cards.find(c=>c.name===card.name);
      const object = manifest.objects.find(o=>o.key===card.imageReference);
      const input = readFileSync(join(fixtureDirectory,originalCard.image));
      return {resourceType:'card',id:card.id,parentId:packId,name:card.name,inventoryId:originalCard.id,
        difficulty:1,imageReference:card.imageReference,sourcePath:`assets/images/Shapes/Geometric Shapes/${originalCard.image}`,
        sourceSha256:sha(input),sourceBytes:input.length,preparedSha256:object.sha256,preparedBytes:object.sizeBytes,provenance:structuredClone(provenance)};
    }),
  ];
  return withHash({protocolVersion:1,inventorySha256:sha('synthetic-inventory'),workerSha256:sha('T32-worker'),records,objects:structuredClone(publication.objects)});
}
execFileSync(process.execPath,['node_modules/wrangler/bin/wrangler.js','deploy','test/legacy-import-worker.ts','--env','staging','--dry-run','--outdir',join(temporary,'worker')],{cwd:root,stdio:'pipe'});
const project = 'biguess-legacy-test';
const google = await generateKeyPair('RS256');
const jwk = {...await exportJWK(google.publicKey),kid:'legacy-google-key',alg:'RS256',use:'sig'};
const users = ['owner','a','b'].map(uid=>({uid,email:`${uid}@example.test`,role:uid==='owner'?'owner_admin':'collector'}));
const origin = 'https://studio.saoudi.online';
async function token(uid) {
  const now=Math.floor(Date.now()/1000);
  return new SignJWT({sub:uid,email:`${uid}@example.test`,email_verified:true,firebase:{sign_in_provider:'google.com'},aud:project,
    iss:`https://securetoken.google.com/${project}`,iat:now-10,auth_time:now-20,exp:now+3600}).setProtectedHeader({alg:'RS256',kid:jwk.kid}).sign(google.privateKey);
}
async function json(response,status=200,privateResponse=true) {
  assert.equal(response.status,status,await response.clone().text());
  if (privateResponse) assert.equal(response.headers.get('Cache-Control'),'no-store');
  return response.json();
}
async function setup(t,environment='local') {
  const tokens=Object.fromEntries(await Promise.all(users.map(async user=>[user.uid,await token(user.uid)])));
  const options={modules:workerModules(join(temporary,'worker/legacy-import-worker.js')),modulesRoot:join(temporary,'worker'),
    scriptPath:join(temporary,'worker/legacy-import-worker.js'),compatibilityDate:'2026-11-01',
    bindings:{APP_ENV:environment,FIREBASE_PROJECT_ID:project,STUDIO_USERS:JSON.stringify(users),STUDIO_ALLOWED_ORIGINS:JSON.stringify([origin]),PUBLICATION_KEYS:JSON.stringify(publication.trustedKeys)},
    d1Databases:{DB:'legacy-db'},r2Buckets:{CONTENT:'legacy-images'},outboundService:request=>{
      assert.equal(request.url,'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com');return Response.json({keys:[jwk]});
    }};
  const mf=new Miniflare(convertV4MiniflareOptions(options));t.after(()=>mf.dispose());
  let db=await mf.getD1Database('DB');
  const bucket=await mf.getR2Bucket('CONTENT');
  for (const file of readdirSync(`${root}migrations`).filter(file=>file.endsWith('.sql')).sort()) {
    await db.exec(readFileSync(`${root}migrations/${file}`,'utf8').split('\n').filter(line=>!line.trim().startsWith('--')).join(' '));
  }
  const request=(path,{actor='owner',method='GET',body,headers={}}={})=>mf.dispatchFetch(`https://content.example${path}`,{method,
    headers:{Origin:origin,...(actor?{Authorization:`Bearer ${tokens[actor]}`} : {}),...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},
    ...(body===undefined?{}:{body:JSON.stringify(body)})});
  const importBundle=(bundle=legacyBundle())=>request('/__legacy/import',{actor:null,method:'POST',body:bundle});
  const rollback=(importId=legacyBundle().importId)=>request('/__legacy/rollback',{actor:null,method:'POST',body:{importId}});
  const table=async name=>(await db.prepare(`SELECT * FROM ${name}`).all()).results;
  const setUsers=async next=>{
    options.bindings={...options.bindings,STUDIO_USERS:JSON.stringify(next)};
    await mf.setOptions(convertV4MiniflareOptions(options));
    db=await mf.getD1Database('DB');
  };
  return {get db(){return db;},bucket,request,importBundle,rollback,table,setUsers};
}

async function emptyPublic(s) {
  assert.deepEqual((await json(await s.request('/content/v1/catalog/topics',{actor:null}),200,false)).items,[]);
  await json(await s.request(`/content/v1/catalog/packs?topicId=${encodeURIComponent(topicId)}`,{actor:null}),404);
  for (const suffix of ['download','revisions/1/signature','revisions/1/manifest','revisions/1/archive.biguesspack']) await json(await s.request(`/content/v1/packs/${encodeURIComponent(packId)}/${suffix}`,{actor:null}),404);
  for (const ref of Object.keys(legacyBundle().objects)) {
    await json(await s.request(`/content/v1/${ref}`,{actor:null}),404);
    await json(await s.request(`/content/v1/packs/${encodeURIComponent(packId)}/revisions/1/${ref}`,{actor:null}),404);
  }
  for (const table of ['catalog_topics','catalog_packs','publication_heads','publication_revisions','studio_rights_approvals','studio_audit']) assert.equal((await s.table(table)).length,0,table);
}

test('legacy import is hidden, Owner-only, repeatable and preserves immutable source evidence without contributor credit',async t=>{
  const s=await setup(t),bundle=legacyBundle();
  const beforeA=await json(await s.request('/studio/v1/sync/initial?limit=100',{actor:'a'}));
  const beforeB=await json(await s.request('/studio/v1/sync/initial?limit=100',{actor:'b'}));
  const imported=await json(await s.importBundle(bundle));
  assert.equal(imported.recordCount,6);assert.equal(imported.sourceCount,4);assert.equal(imported.objectCount,4);assert.equal(imported.state,'quarantined');
  const rows=await s.table('studio_entities');
  assert(rows.every(row=>row.state==='hidden'&&row.revision===1));
  assert((await s.table('studio_creators')).every(row=>row.source==='legacy'&&row.created_by_uid===null&&row.created_at===null));
  assert.equal((await s.table('studio_legacy_records')).length,6);
  const sources=(await s.table('studio_legacy_records')).filter(row=>row.resource_type==='card').map(row=>JSON.parse(row.record_json));
  assert.deepEqual(sources.map(row=>row.sourceSha256).sort(),bundle.records.filter(row=>row.resourceType==='card').map(row=>row.sourceSha256).sort());
  assert(sources.every(row=>row.provenance.permission_to_publish===false));
  const snapshot=await s.table('studio_entities');
  const replay=await json(await s.importBundle(bundle));assert.equal(replay.replayed,true);assert.deepEqual(await s.table('studio_entities'),snapshot);
  assert.equal((await s.table('studio_commits')).length,1);
  const owner=await json(await s.request('/studio/v1/sync/initial?limit=100'));
  assert.equal(owner.items.length,6);assert(owner.items.every(row=>row.createdByUid===null));
  for (const [actor,before] of [['a',beforeA],['b',beforeB]]) {
    assert.deepEqual((await json(await s.request('/studio/v1/sync/initial?limit=100',{actor}))).items,[]);
    assert.deepEqual((await json(await s.request('/studio/v1/topics',{actor}))).items,[]);
    assert.deepEqual((await json(await s.request(`/studio/v1/sync/changes?limit=100&cursor=${encodeURIComponent(before.resumeCursor)}`,{actor}))).items,[]);
    assert.equal((await json(await s.request('/studio/v1/profile',{actor}))).counts.totalOperations,0);
    for (const row of bundle.records) {
      await json(await s.request(`/studio/v1/${row.resourceType}s/${encodeURIComponent(row.id)}`,{actor}),404);
      await json(await s.request(`/content/v1/studio/${row.resourceType}s/${encodeURIComponent(row.id)}`,{actor}),404);
    }
    await json(await s.request('/studio/v1/batches',{actor,method:'POST',headers:{'If-None-Match':'*','Idempotency-Key':randomUUID()},body:{protocolVersion:1,
      aggregate:{resourceType:'pack',id:`guessed-${actor}`},operations:[{resourceType:'pack',id:`guessed-${actor}`,action:'create',value:{name:'Forbidden parent',topicId}}]}}),404);
  }
  await emptyPublic(s);
  await assert.rejects(s.db.prepare("UPDATE studio_legacy_records SET record_json='{}'").run(),/immutable_legacy_import/);
});

test('quarantine rejects generic Owner approval/publishing and signed operator publication; cleared fixtures remain publishable elsewhere',async t=>{
  const s=await setup(t);await json(await s.importBundle());
  const path=`/studio/v1/packs/${encodeURIComponent(packId)}/publication`;
  const review=await json(await s.request(path));
  assert(review.errors.some(error=>error.includes('quarantined')));
  for (const action of ['approve-rights','approve','publish']) await json(await s.request(`${path}/${action}`,{method:'POST',body:{revision:review.revision,fingerprint:review.fingerprint,evidence:'fixture-only-clearance-claim'}}),422);
  const topicPath=`/studio/v1/topics/${encodeURIComponent(topicId)}/publication`;
  const topicReview=await json(await s.request(topicPath));
  await json(await s.request(`${topicPath}/publish`,{method:'POST',body:{revision:topicReview.revision,fingerprint:topicReview.fingerprint}}),422);
  await json(await s.request('/__legacy/publish',{actor:null,method:'POST',body:{bundle:publication,expectedRevision:0}}),409);
  // Final SQL guards also close a publication/approval race whose validation
  // began before the quarantine marker was committed.
  await assert.rejects(s.db.prepare('INSERT INTO catalog_topics(id,name,revision,published) VALUES (?,?,1,1)').bind(topicId,'Quarantined').run(),/legacy_quarantine/);
  await assert.rejects(s.db.prepare('INSERT INTO catalog_packs(id,topic_id,name,revision,card_count,manifest_sha256,published) VALUES (?,?,?,1,4,?,1)').bind(packId,topicId,'Quarantined','0'.repeat(64)).run(),/legacy_quarantine/);
  await assert.rejects(s.db.prepare('INSERT INTO studio_rights_approvals VALUES (?,?,?,?,?)').bind(packId,'pack','unverified-claim','owner',new Date().toISOString()).run(),/legacy_quarantine/);
  await assert.rejects(s.db.prepare('INSERT INTO studio_publication_approvals VALUES (?,?,?,?,?)').bind('pack',packId,'0'.repeat(64),'owner',new Date().toISOString()).run(),/legacy_quarantine/);
  await emptyPublic(s);
  const cleared=await setup(t);
  await json(await cleared.request('/__legacy/publish',{actor:null,method:'POST',body:{bundle:publication,expectedRevision:0}}));
  assert.equal((await cleared.table('publication_heads')).length,1);
});

test('malformed, tampered, colliding or falsely cleared imports never overwrite local state',async t=>{
  const s=await setup(t);
  for (const edit of [
    b=>{b.records[2].provenance.permission_to_publish=true;},
    b=>{b.records[2].provenance.rights_status='cleared';},
    b=>{b.records.push(structuredClone(b.records[2]));},
    b=>{delete b.objects[Object.keys(b.objects)[0]];},
    b=>{b.objects[Object.keys(b.objects)[0]]=Buffer.from('damaged').toString('base64');},
    b=>{b.records[2].parentId='missing-parent';},
    b=>{b.records[2].createdByUid='a';},
  ]) {
    const bundle=legacyBundle();edit(bundle);await json(await s.importBundle(withHash(bundle)),422);
    assert.equal((await s.table('studio_entities')).length,0);assert.equal((await s.table('studio_legacy_imports')).length,0);
  }
  const checksum=legacyBundle();checksum.importId='0'.repeat(64);await json(await s.importBundle(checksum),422);
  await s.db.prepare('INSERT INTO studio_entities VALUES (?,?,?,?,?,?)').bind('topic',topicId,null,JSON.stringify({name:'Existing unrelated topic'}),'active',8).run();
  await json(await s.importBundle(),409);
  assert.equal((await s.table('studio_entities'))[0].revision,8);assert.equal((await s.table('studio_entities'))[0].value,JSON.stringify({name:'Existing unrelated topic'}));
  assert.equal((await s.table('studio_legacy_imports')).length,0);
});

test('rollback is repeatable, preserves provenance/objects/fences, and refuses changed imported records',async t=>{
  const s=await setup(t),bundle=legacyBundle();await json(await s.importBundle(bundle));
  const records=await s.table('studio_legacy_records');
  const report=await json(await s.rollback());assert.equal(report.state,'rolled_back');
  assert((await s.table('studio_entities')).every(row=>row.state==='deleted'&&row.revision===2));
  assert.equal((await s.table('studio_tombstones')).length,6);assert.deepEqual(await s.table('studio_legacy_records'),records);
  for (const ref of Object.keys(bundle.objects)) assert(await s.bucket.get(ref));
  assert.equal((await json(await s.rollback())).replayed,true);
  assert.equal((await json(await s.importBundle(bundle))).state,'rolled_back');
  assert.equal((await s.table('studio_entities')).length,6);await emptyPublic(s);
  const changed=await setup(t);await json(await changed.importBundle());
  await changed.db.prepare("UPDATE studio_entities SET revision=2,value=? WHERE resource_type='pack'").bind(JSON.stringify({name:'Owner edit',topicId})).run();
  await json(await changed.rollback(),409);
  assert.equal((await changed.table('studio_legacy_rollbacks')).length,0);assert.equal((await changed.table('studio_tombstones')).length,0);
});

for (const environment of ['staging','production']) test(`${environment} cannot import or roll back legacy records`,async t=>{
  const s=await setup(t,environment);
  assert.equal((await json(await s.importBundle(),403)).error.code,'local_only');
  assert.equal((await json(await s.rollback(),403)).error.code,'local_only');
  assert.equal((await s.table('studio_entities')).length,0);
});


test('Owner-created children inherit Topic quarantine after role downgrade; unrelated typed-ID collisions remain visible',async t=>{
  const s=await setup(t);await json(await s.importBundle());
  const downgraded=users.map(user=>({...user,role:user.uid==='a'?'owner_admin':'collector'}));
  await s.setUsers(downgraded);
  const before=await json(await s.request('/studio/v1/sync/initial?limit=100'));
  assert.deepEqual(before.items,[]);
  // Restore Owner authority only while explicitly authoring new private children.
  // Returning to the same Collector configuration makes the old Collector cursor
  // valid, so its feed must also filter the intervening historical creation rows.
  await s.setUsers(downgraded.map(user=>user.uid==='owner'?{...user,role:'owner_admin'}:user));
  const childPack='owner-private-child',childCard='owner-private-card';
  const imageReference=Object.keys(legacyBundle().objects)[0];
  await s.db.prepare('INSERT INTO studio_pack_images VALUES (?,?,?,?)').bind(childPack,imageReference,'owner',new Date().toISOString()).run();
  await json(await s.request('/studio/v1/batches',{method:'POST',headers:{'If-None-Match':'*','Idempotency-Key':randomUUID()},body:{
    protocolVersion:1,aggregate:{resourceType:'pack',id:childPack},operations:[
      {resourceType:'pack',id:childPack,action:'create',value:{name:'Private child Pack',topicId}},
      {resourceType:'card',id:childCard,action:'create',value:{name:'Private child Card',packId:childPack,imageReference,difficulty:1}},
    ],
  }}));
  // Resource IDs are typed, so this unrelated shared Topic may legitimately use
  // the same ID as a private Pack. Ancestor checks must not follow the Pack join
  // for Topic rows and accidentally hide the unrelated taxonomy entry.
  await json(await s.request('/studio/v1/batches',{method:'POST',headers:{'If-None-Match':'*','Idempotency-Key':randomUUID()},body:{
    protocolVersion:1,aggregate:{resourceType:'topic',id:childPack},operations:[
      {resourceType:'topic',id:childPack,action:'create',value:{name:'Unrelated shared taxonomy'}},
    ],
  }}));
  await json(await s.request(`/studio/v1/packs/${childPack}`));
  await json(await s.request(`/studio/v1/cards/${childCard}`));
  await s.setUsers(downgraded);
  for (const actor of ['owner','b']) {
    const initial=await json(await s.request('/studio/v1/sync/initial?limit=100',{actor}));
    assert.deepEqual(initial.items.map(row=>[row.resourceType,row.id]),[['topic',childPack]]);
    assert.deepEqual((await json(await s.request('/studio/v1/packs',{actor}))).items,[]);
    const topics=await json(await s.request('/studio/v1/topics',{actor}));
    assert.deepEqual(topics.items.map(row=>row.id),[childPack]);
    await json(await s.request(`/studio/v1/topics/${childPack}`,{actor}));
    for (const path of [`/studio/v1/packs/${childPack}`,`/studio/v1/cards/${childCard}`,
      `/studio/v1/packs/${childPack}/cards`,`/studio/v1/topics/${encodeURIComponent(topicId)}`,
      `/content/v1/studio/packs/${childPack}`,`/content/v1/studio/cards/${childCard}`]) {
      await json(await s.request(path,{actor}),404);
    }
  }
  const changes=await json(await s.request(`/studio/v1/sync/changes?limit=100&cursor=${encodeURIComponent(before.resumeCursor)}`));
  assert.deepEqual(changes.items.map(event=>[event.kind,event.record?.resourceType,event.record?.id]),[['upsert','topic',childPack]]);
  // Another Owner's later updates must not leak through the downgraded creator's
  // feed either, despite Pack ownership matching that Collector's exact UID.
  await json(await s.request('/studio/v1/batches',{actor:'a',method:'POST',headers:{'If-Match':'"rev-1"','Idempotency-Key':randomUUID()},body:{
    protocolVersion:1,aggregate:{resourceType:'pack',id:childPack},operations:[
      {resourceType:'pack',id:childPack,action:'update',value:{name:'Still private child',topicId}},
      {resourceType:'card',id:childCard,action:'update',value:{name:'Still private Card',packId:childPack,imageReference,difficulty:2}},
    ],
  }}));
  const later=await json(await s.request(`/studio/v1/sync/changes?limit=100&cursor=${encodeURIComponent(changes.resumeCursor)}`));
  assert.deepEqual(later.items,[]);
  await json(await s.rollback(),409);
});


test('an identical import replay fails closed on missing, corrupt or mislabeled persisted images without repair',async t=>{
  const s=await setup(t),bundle=legacyBundle();
  await json(await s.importBundle(bundle));
  const rows=await s.table('studio_entities');
  const key=Object.keys(bundle.objects)[0];
  const originalBytes=Buffer.from(bundle.objects[key],'base64');
  const type=key.endsWith('.webp')?'image/webp':'image/png';
  await s.bucket.delete(key);
  await json(await s.importBundle(bundle),409);
  assert.equal(await s.bucket.get(key),null,'replay must not silently repair a missing image');
  assert.deepEqual(await s.table('studio_entities'),rows);
  await s.bucket.put(key,Buffer.from('corrupted private bytes'),{httpMetadata:{contentType:type}});
  await json(await s.importBundle(bundle),409);
  assert.equal(await (await s.bucket.get(key)).text(),'corrupted private bytes','replay must not overwrite corrupted data');
  await s.bucket.put(key,originalBytes,{httpMetadata:{contentType:'application/octet-stream'}});
  await json(await s.importBundle(bundle),409);
  assert.equal((await s.bucket.get(key)).httpMetadata.contentType,'application/octet-stream');
  await s.bucket.put(key,originalBytes,{httpMetadata:{contentType:type}});
  assert.equal((await json(await s.importBundle(bundle))).replayed,true);
  assert.deepEqual(await s.table('studio_entities'),rows);
  assert.equal((await s.table('studio_commits')).length,1);
});
