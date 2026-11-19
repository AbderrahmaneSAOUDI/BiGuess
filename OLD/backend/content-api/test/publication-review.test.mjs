import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, readdirSync, mkdtempSync, rmSync, cpSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { root, workerModules } from '../scripts/local.mjs';
import { prepare } from '../scripts/prepare.mjs';

const project = 'biguess-review-test';
const google = await generateKeyPair('RS256');
const jwk = { ...await exportJWK(google.publicKey), kid: 'review-google', alg: 'RS256', use: 'sig' };
const users = ['owner','a','b'].map(uid => ({ uid, email: `${uid}@example.test`, role: uid === 'owner' ? 'owner_admin' : 'collector' }));
const operatorToken = 'test-only-independent-operator-credential-123456789';
const origin = 'https://studio.saoudi.online';
const temporary = mkdtempSync(join(tmpdir(),'biguess-review-'));
process.on('exit',() => rmSync(temporary,{ recursive:true, force:true }));
const signer = generateKeyPairSync('ed25519').privateKey.export({ type:'pkcs8', format:'pem' });
const bundles = new Map();
for (const revision of [1,2,3,4]) {
  const file = join(temporary,`${revision}.biguesspack`);
  execFileSync('python3',['../../scripts/export_pack.py','fixture','../../test/fixtures/cleared_shapes/pack.json','--revision',String(revision),'--output',file],{ cwd:root });
  bundles.set(revision,prepare(file,signer));
}
// A real routine product edit, prepared from a fully validated archive.
cpSync(new URL('../../../test/fixtures/cleared_shapes/',import.meta.url),join(temporary,'edited'),{ recursive:true });
const editedSourcePath = join(temporary,'edited/pack.json');
const editedSource = JSON.parse(readFileSync(editedSourcePath,'utf8'));
editedSource.pack.name = 'Geometric Shapes Updated';
writeFileSync(editedSourcePath,JSON.stringify(editedSource));
const editedArchive = join(temporary,'edited-2.biguesspack');
execFileSync('python3',['../../scripts/export_pack.py','fixture',editedSourcePath,'--revision','2','--output',editedArchive],{ cwd:root });
const editedBundle = prepare(editedArchive,signer);
const manifest = JSON.parse(Buffer.from(bundles.get(1).manifest,'base64'));
const packId = manifest.pack.id;
const topicId = manifest.topic.id;
const packPath = `/studio/v1/packs/${packId}/publication`;
const topicPath = `/studio/v1/topics/${topicId}/publication`;
const publicBase = `/content/v1/packs/${packId}`;
execFileSync(process.execPath,['node_modules/wrangler/bin/wrangler.js','deploy','test/publication-review-worker.ts','--env','staging','--dry-run','--outdir',join(temporary,'worker')],{ cwd:root, stdio:'pipe' });
async function token(uid) {
  const now = Math.floor(Date.now()/1000);
  return new SignJWT({ sub:uid,email:`${uid}@example.test`,email_verified:true,firebase:{ sign_in_provider:'google.com' },
    aud:project,iss:`https://securetoken.google.com/${project}`,iat:now-10,auth_time:now-20,exp:now+3600 })
    .setProtectedHeader({ alg:'RS256',kid:jwk.kid }).sign(google.privateKey);
}
async function ok(response,status=200) {
  assert.equal(response.status,status,await response.clone().text());
  return response.headers.get('Content-Type')?.includes('application/json') ? response.json() : response;
}
async function setup(t) {
  const tokens = Object.fromEntries(await Promise.all(users.map(async u => [u.uid,await token(u.uid)])));
  const options = { modules:workerModules(join(temporary,'worker/publication-review-worker.js')),
    modulesRoot:join(temporary,'worker'),scriptPath:join(temporary,'worker/publication-review-worker.js'),compatibilityDate:'2026-11-01',
    bindings:{ APP_ENV:'staging',FIREBASE_PROJECT_ID:project,STUDIO_USERS:JSON.stringify(users),STUDIO_ALLOWED_ORIGINS:JSON.stringify([origin]),
      PUBLICATION_KEYS:JSON.stringify(bundles.get(1).trustedKeys),PUBLICATION_OPERATOR_TOKEN:operatorToken },
    d1Databases:{ DB:'review-db' },r2Buckets:{ CONTENT:'review-images' },
    outboundService: request => { assert.equal(request.url,'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com'); return Response.json({ keys:[jwk] }); }};
  const mf = new Miniflare(convertV4MiniflareOptions(options));
  t.after(() => mf.dispose());
  let db = await mf.getD1Database('DB'); let bucket = await mf.getR2Bucket('CONTENT');
  for (const file of readdirSync(`${root}migrations`).filter(f => f.endsWith('.sql')).sort()) {
    await db.exec(readFileSync(`${root}migrations/${file}`,'utf8').split('\n').filter(l => !l.trim().startsWith('--')).join(' '));
  }
  const entity = (type,id,parent,value) => db.prepare('INSERT INTO studio_entities VALUES (?,?,?,?,?,?)').bind(type,id,parent,JSON.stringify(value),'active',1).run();
  const creator = (type,id,uid) => db.prepare("INSERT INTO studio_creators VALUES (?,?,?,?,'authenticated')").bind(type,id,uid,new Date().toISOString()).run();
  await entity('topic',topicId,null,{ name:manifest.topic.name }); await creator('topic',topicId,'owner');
  await entity('pack',packId,topicId,{ name:manifest.pack.name,topicId }); await creator('pack',packId,'a');
  for (const c of manifest.cards) { const { id,...value } = c; await entity('card',id,packId,value); await creator('card',id,'a'); }
  for (const o of manifest.objects) {
    await bucket.put(o.key,Buffer.from(bundles.get(1).objects[o.key],'base64'),{ httpMetadata:{ contentType:o.mediaType } });
    await db.prepare('INSERT INTO studio_pack_images VALUES (?,?,?,?)').bind(packId,o.key,'a',new Date().toISOString()).run();
  }
  const request = (path,{ actor='owner',method='GET',body,headers={} }={}) => mf.dispatchFetch(`https://content.example${path}`,{ method,
    headers:{ Origin:origin,...(actor ? { Authorization:`Bearer ${tokens[actor]}` } : {}),...(body === undefined ? {} : { 'Content-Type':'application/json' }),...headers },
    ...(body === undefined ? {} : { body:JSON.stringify(body) }) });
  const preview = (path=packPath,actor='owner') => request(path,{ actor }).then(ok);
  const action = async (name,{ actor='owner',path=packPath,review,extra={} }={}) => {
    const r = review ?? await preview(path,actor);
    return request(`${path}/${name}`,{ actor,method:'POST',body:{ revision:r.revision,fingerprint:r.fingerprint,...extra } });
  };
  const release = (id,revision=1,{ auth=operatorToken,headers={},bundle=bundles.get(revision) }={}) => request(`/__operator/${id}`,{ actor:null,method:'POST',body:bundle,
    headers:{ ...(auth === null ? {} : { Authorization:`Bearer ${auth}` }),...headers } });
  const catalog = async () => {
    const response = await request(`/content/v1/catalog/packs?topicId=${topicId}`,{ actor:null });
    if ([403,404].includes(response.status)) { assert.equal((await response.json()).error.code,response.status === 403 ? 'unavailable' : 'not_found'); return []; }
    return (await ok(response)).items;
  };
  const approvePack = async () => { await ok(await action('approve-rights',{ extra:{ evidence:'private-rights-record:cleared-shapes' } })); await ok(await action('approve')); };
  const publishTopic = async () => { await ok(await action('approve',{ path:topicPath })); await ok(await action('publish',{ path:topicPath })); };
  const initial = async ({ topic=true }={}) => {
    if (topic) await publishTopic(); await approvePack(); const queued = await ok(await action('publish'));
    assert.equal(queued.status,'pending_operator'); await ok(await release(queued.requestId)); return queued.requestId;
  };
  const edit = async (revision,operations,actor='a') => request('/studio/v1/batches',{ actor,method:'POST',headers:{ 'If-Match':`"rev-${revision}"`,'Idempotency-Key':randomUUID() },
    body:{ protocolVersion:1,aggregate:{ resourceType:'pack',id:packId },operations } });
  const setUsers = async next => { options.bindings = { ...options.bindings,STUDIO_USERS:JSON.stringify(next) }; await mf.setOptions(convertV4MiniflareOptions(options)); db = await mf.getD1Database('DB'); bucket = await mf.getR2Bucket('CONTENT'); };
  return { mf,get db() { return db; },get bucket() { return bucket; },request,preview,action,release,catalog,approvePack,publishTopic,initial,edit,setUsers };
}

test('publication routes enforce Firebase authorization, ownership, Owner initial approval and no independent Cards',async t => {
  const s = await setup(t);
  await ok(await s.request(packPath,{ actor:null }),401); await ok(await s.request(packPath,{ actor:'b' }),404);
  for (const name of ['validate','approve','approve-rights','publish','unpublish']) await ok(await s.request(`${packPath}/${name}`,{ actor:'b',method:'POST',body:{ revision:1,fingerprint:'0'.repeat(64) } }),404);
  await ok(await s.action('approve',{ actor:'a' }),403);
  await ok(await s.action('approve-rights',{ actor:'a',extra:{ evidence:'forged' } }),403);
  await ok(await s.request(`/studio/v1/cards/${manifest.cards[0].id}/publication`),404);
  await ok(await s.action('publish'),422);
  await ok(await s.action('approve-rights',{ extra:{ evidence:'private-rights-record:fixture' } }));
  await ok(await s.action('publish',{ actor:'a' }),403); await ok(await s.action('publish'),422);
  assert.deepEqual(await s.catalog(),[]); assert.equal((await s.db.prepare('SELECT count(*) n FROM publication_heads').first()).n,0);
});

test('invalid cards, missing/corrupt images and rights-unapproved drafts fail before approval or release',async t => {
  const s = await setup(t); assert.equal((await s.preview()).rightsApproved,false); await ok(await s.action('approve'),422);
  await s.db.prepare("UPDATE studio_entities SET state='hidden' WHERE resource_type='card' AND id!=?").bind(manifest.cards[0].id).run();
  assert((await s.preview()).errors.some(e => e.includes('two eligible'))); await ok(await s.action('approve-rights',{ extra:{ evidence:'record' } }),422);
  await s.db.prepare("UPDATE studio_entities SET state='active' WHERE resource_type='card'").run(); await s.bucket.delete(manifest.objects[0].key);
  assert((await s.preview()).errors.some(e => e.startsWith('Unverified image'))); await ok(await s.action('approve-rights',{ extra:{ evidence:'record' } }),422);
  await s.bucket.put(manifest.objects[0].key,Buffer.from('wrong bytes'),{ httpMetadata:{ contentType:'image/webp' } });
  assert((await s.preview()).errors.some(e => e.startsWith('Unverified image'))); assert.deepEqual(await s.catalog(),[]);
});

test('approvals queue privately; operator authentication, signed activation and Topic approval stay separate',async t => {
  const s = await setup(t); await s.approvePack(); const queued = await ok(await s.action('publish'));
  assert.equal(queued.status,'pending_operator'); assert.equal(queued.published,false); assert.deepEqual(await s.catalog(),[]);
  await ok(await s.release(queued.requestId,1,{ auth:null }),403); await ok(await s.release(queued.requestId,1,{ auth:'wrong' }),403);
  const tampered = structuredClone(bundles.get(1)); tampered.receipt.signature = Buffer.alloc(64).toString('base64');
  assert.notEqual((await s.release(queued.requestId,1,{ bundle:tampered })).status,200);
  assert.equal((await s.db.prepare('SELECT count(*) n FROM publication_heads').first()).n,0);
  await ok(await s.release(queued.requestId)); assert.equal((await s.db.prepare('SELECT published FROM catalog_topics WHERE id=?').bind(topicId).first()).published,0);
  assert.deepEqual(await s.catalog(),[]); await ok(await s.request(`${publicBase}/download`,{ actor:null }),403);
  await s.publishTopic(); assert.equal((await s.catalog())[0].revision,1);
  await ok(await s.request(`${publicBase}/revisions/1/manifest`,{ actor:null })); await ok(await s.release(queued.requestId),409);
  await ok(await s.request(`/releases/${queued.requestId}`,{ actor:null,method:'POST',body:bundles.get(1),headers:{ Authorization:`Bearer ${operatorToken}` } }),405);
});

test('owned routine revisions validate without Owner approval and failed writes retain the prior public revision',async t => {
  const s = await setup(t); await s.initial();
  await ok(await s.edit(1,[{ resourceType:'pack',id:packId,action:'update',value:{ name:editedSource.pack.name,topicId } }]));
  assert.equal((await s.catalog())[0].revision,1); const review = await s.preview(packPath,'a');
  assert.equal(review.initialApproved,false); assert.equal(review.rightsApproved,true); assert.deepEqual(review.errors,[]);
  const queued = await ok(await s.action('publish',{ actor:'a',review }));
  for (const failAfter of [1,2,3,4,5,6]) {
    assert.notEqual((await s.release(queued.requestId,2,{ bundle:editedBundle,headers:{ 'X-Test-Fail-After':String(failAfter) } })).status,200);
    assert.equal((await s.catalog())[0].revision,1); await ok(await s.request(`${publicBase}/revisions/2/manifest`,{ actor:null }),404);
    assert.equal((await s.db.prepare('SELECT status FROM studio_release_requests WHERE id=?').bind(queued.requestId).first()).status,'pending_operator');
  }
  await ok(await s.release(queued.requestId,2,{ bundle:editedBundle })); assert.equal((await s.catalog())[0].revision,2);
  await ok(await s.request(`${publicBase}/revisions/1/manifest`,{ actor:null })); await ok(await s.request(`${publicBase}/revisions/2/manifest`,{ actor:null }));
  assert.deepEqual(await s.db.prepare('SELECT revision,previous_revision FROM publication_heads WHERE pack_id=?').bind(packId).first(),{ revision:2,previous_revision:1 });
});

test('stale snapshots, subsequently hidden Packs and revoked actors cannot activate queued requests',async t => {
  const s = await setup(t); await s.initial();
  await ok(await s.edit(1,[{ resourceType:'pack',id:packId,action:'update',value:{ name:manifest.pack.name,topicId } }]));
  const old = await s.preview(packPath,'a'); const queued = await ok(await s.action('publish',{ actor:'a',review:old }));
  await s.setUsers(users.filter(u => u.uid !== 'a')); await ok(await s.release(queued.requestId,2),403); await s.setUsers(users);
  await ok(await s.action('unpublish',{ actor:'a' })); await ok(await s.release(queued.requestId,2),422);
  await ok(await s.action('publish',{ actor:'a',review:old }),412); await ok(await s.action('publish',{ actor:'a' }),403);
  assert.deepEqual(await s.catalog(),[]); assert.equal((await s.db.prepare('SELECT revision FROM publication_heads WHERE pack_id=?').bind(packId).first()).revision,1);
});

test('new Card image pairs need rights approval; signed mismatched routine content cannot release',async t => {
  const s = await setup(t); await s.initial();
  const c = manifest.cards[0]; const replacement = manifest.cards.find(v => v.imageReference !== c.imageReference).imageReference;
  await ok(await s.edit(1,[{ resourceType:'card',id:c.id,action:'update',value:{ name:c.name,packId,difficulty:c.difficulty,imageReference:replacement } }]));
  assert.equal((await s.preview(packPath,'a')).rightsApproved,false); await ok(await s.action('publish',{ actor:'a' }),422);
  assert.equal((await s.db.prepare('SELECT revision FROM publication_heads WHERE pack_id=?').bind(packId).first()).revision,1);
  await ok(await s.action('approve-rights',{ extra:{ evidence:'new-private-rights-record' } })); assert.equal((await s.preview(packPath,'a')).rightsApproved,true);
  const queued = await ok(await s.action('publish',{ actor:'a' })); await ok(await s.release(queued.requestId,2),422);
  assert.equal((await s.db.prepare('SELECT revision FROM publication_heads WHERE pack_id=?').bind(packId).first()).revision,1);
});


test('concurrent hide during operator R2 staging fences the whole activation transaction',async t => {
  const s = await setup(t); await s.initial();
  await ok(await s.edit(1,[{ resourceType:'pack',id:packId,action:'update',value:{ name:manifest.pack.name,topicId } }]));
  const queued = await ok(await s.action('publish',{ actor:'a' }));
  assert.notEqual((await s.release(queued.requestId,2,{ headers:{ 'X-Test-Hide-On-Write':'1' } })).status,200);
  assert.deepEqual(await s.catalog(),[]);
  assert.equal((await s.db.prepare('SELECT revision FROM publication_heads WHERE pack_id=?').bind(packId).first()).revision,1);
  assert.equal((await s.db.prepare('SELECT count(*) n FROM publication_revisions WHERE revision=2').first()).n,0);
  assert.equal((await s.db.prepare('SELECT status FROM studio_release_requests WHERE id=?').bind(queued.requestId).first()).status,'pending_operator');
});


test('review generation guard rejects an intervening write even when T22 takes a newer valid snapshot',async t => {
  const s = await setup(t); await s.initial();
  await ok(await s.edit(1,[{ resourceType:'pack',id:packId,action:'update',value:{ name:manifest.pack.name,topicId } }]));
  const queued = await ok(await s.action('publish',{ actor:'a' }));
  await ok(await s.release(queued.requestId,2,{ headers:{ 'X-Test-Generation-On-Write':'1' } }),412);
  assert.equal((await s.catalog())[0].revision,1);
  assert.equal((await s.db.prepare('SELECT count(*) n FROM publication_revisions WHERE revision=2').first()).n,0);
  assert.equal((await s.db.prepare('SELECT status FROM studio_release_requests WHERE id=?').bind(queued.requestId).first()).status,'pending_operator');
});

test('malformed operator allowlist fails closed even for a previously approved release actor',async t => {
  const s = await setup(t);
  await s.approvePack();
  const queued = await ok(await s.action('publish'));
  await s.setUsers([{ uid:'owner',role:'owner_admin' }]);
  await ok(await s.release(queued.requestId),503);
  assert.equal((await s.db.prepare('SELECT count(*) n FROM publication_heads').first()).n,0);
});
