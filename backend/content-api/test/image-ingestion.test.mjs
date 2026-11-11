import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { deflateSync } from 'node:zlib';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { root, workerModules } from '../scripts/local.mjs';

const temporary = mkdtempSync(join(tmpdir(), 'biguess-ingestion-'));
process.on('exit', () => rmSync(temporary, { recursive: true, force: true }));
execFileSync(process.execPath, ['node_modules/wrangler/bin/wrangler.js', 'deploy', 'test/image-ingestion-worker.ts',
  '--env', 'staging', '--dry-run', '--outdir', join(temporary, 'worker')], { cwd: root, stdio: 'pipe' });
const project = 'biguess-image-ingestion-test';
const pair = await generateKeyPair('RS256');
const jwk = { ...await exportJWK(pair.publicKey), kid: 'ingestion-google-key', alg: 'RS256', use: 'sig' };
const users = ['owner', 'a', 'b'].map(uid => ({ uid, email: `${uid}@example.test`, role: uid === 'owner' ? 'owner_admin' : 'collector' }));
const origin = 'https://studio.saoudi.online';
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGNkqHj2n4GBgYGJAQoAIyICYTlsIJwAAAAASUVORK5CYII=', 'base64');
const webp = readFileSync(`${root}fixtures/image.webp`);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const be = value => { const bytes = Buffer.alloc(4); bytes.writeUInt32BE(value); return bytes; };
const crc32 = bytes => {
  let crc = 0xffffffff;
  for (const byte of bytes) { crc ^= byte; for (let i = 0; i < 8; i++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1; }
  return (crc ^ 0xffffffff) >>> 0;
};
const chunk = (kind, payload) => { const data = Buffer.concat([Buffer.from(kind), payload]); return Buffer.concat([be(payload.length), data, be(crc32(data))]); };
const pngFixture = ({ width = 1, height = 1, metadata = false, badData = false } = {}) => {
  const header = Buffer.concat([be(width), be(height), Buffer.from([8, 6, 0, 0, 0])]);
  return Buffer.concat([png.subarray(0, 8), chunk('IHDR', header),
    ...(metadata ? [chunk('tEXt', Buffer.from('Author\0PRIVATE_AUTHOR'))] : []),
    chunk('IDAT', badData ? Buffer.from([0, 1, 2, 3, 4]) : deflateSync(Buffer.from([0, 255, 0, 0, 64]))), chunk('IEND', Buffer.alloc(0))]);
};
const operation = (resourceType, id, action, value) => ({ resourceType, id, action, ...(value === undefined ? {} : { value }) });
async function expect(response, status = 200, code) {
  assert.equal(response.status, status, await response.clone().text());
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  const body = await response.json();
  if (code) assert.equal(body.error.code, code);
  return body;
}
async function setup(t) {
  const tokens = {};
  for (const user of users) {
    const time = Math.floor(Date.now() / 1000);
    tokens[user.uid] = await new SignJWT({ sub: user.uid, email: user.email, email_verified: true,
      firebase: { sign_in_provider: 'google.com' }, aud: project, iss: `https://securetoken.google.com/${project}`,
      iat: time - 10, auth_time: time - 20, exp: time + 3600 })
      .setProtectedHeader({ alg: 'RS256', kid: jwk.kid }).sign(pair.privateKey);
  }
  const options = { modules: workerModules(join(temporary, 'worker/image-ingestion-worker.js')),
    modulesRoot: join(temporary, 'worker'), scriptPath: join(temporary, 'worker/image-ingestion-worker.js'),
    compatibilityDate: '2026-11-01',
    bindings: { APP_ENV: 'staging', FIREBASE_PROJECT_ID: project, STUDIO_USERS: JSON.stringify(users), STUDIO_ALLOWED_ORIGINS: JSON.stringify([origin]) },
    d1Databases: { DB: 'ingestion-test' }, r2Buckets: { CONTENT: 'ingestion-test' },
    outboundService: request => {
      assert.equal(request.url, 'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com');
      return Response.json({ keys: [jwk] });
    } };
  const mf = new Miniflare(convertV4MiniflareOptions(options)); t.after(() => mf.dispose());
  let db = await mf.getD1Database('DB');
  for (const file of readdirSync(`${root}migrations`).filter(f => f.endsWith('.sql')).sort()) {
    await db.exec(readFileSync(`${root}migrations/${file}`, 'utf8').split('\n').filter(line => !line.trim().startsWith('--')).join(' '));
  }
  const bucket = await mf.getR2Bucket('CONTENT');
  const request = (path, { actor = 'a', headers = {}, ...rest } = {}) => mf.dispatchFetch(`https://api.example${path}`, {
    ...rest, headers: { Origin: origin, ...(actor ? { Authorization: `Bearer ${tokens[actor]}` } : {}), ...headers } });
  const commit = (kind, id, operations, revision, { actor = 'a', headers = {}, ...rest } = {}) => request('/studio/v1/batches', {
    method: 'POST', actor, headers: { 'Content-Type': 'application/json', 'Idempotency-Key': randomUUID(),
      ...(revision === 0 ? { 'If-None-Match': '*' } : { 'If-Match': `"rev-${revision}"` }), ...headers },
    body: JSON.stringify({ protocolVersion: 1, aggregate: { resourceType: kind, id }, operations }), ...rest });
  await expect(await commit('topic', 'topic', [operation('topic', 'topic', 'create', { name: 'Shared taxonomy' })], 0, { actor: 'owner' }));
  for (const uid of ['a', 'b']) await expect(await commit('pack', `pack-${uid}`, [operation('pack', `pack-${uid}`, 'create', { name: `Private ${uid}`, topicId: 'topic' })], 0, { actor: uid }));
  const upload = (packId = 'pack-a', bytes = png, type = 'image/png', { headers = {}, ...rest } = {}) => request(`/studio/v1/packs/${packId}/images`, {
    method: 'POST', body: bytes, headers: { 'Content-Type': type, 'X-Content-SHA256': digest(bytes), 'If-Match': '"rev-1"', ...headers }, ...rest });
  const rows = () => db.prepare('SELECT * FROM studio_image_uploads ORDER BY pack_id,object_reference').all();
  const cleanup = async (time = Math.floor(Date.now() / 1000) + 90000) => {
    const result = await mf.dispatchFetch('https://api.example/__cleanup', { method: 'POST', body: JSON.stringify({ time }) });
    assert.equal(result.status, 200, await result.clone().text()); return result.json();
  };
  const setUsers = async next => { options.bindings.STUDIO_USERS = JSON.stringify(next); await mf.setOptions(convertV4MiniflareOptions(options)); db = await mf.getD1Database('DB'); };
  return { mf, db, bucket, request, commit, upload, rows, cleanup, setUsers };
}

test('independent Workerd/WASM decodes PNG/WebP, private staging dedup and explicit canonical attachment', async t => {
  const s = await setup(t);
  for (const [bytes, type] of [[png, 'image/png'], [webp, 'image/webp'], [pngFixture(), 'image/png']]) {
    const result = await expect(await s.upload('pack-a', bytes, type));
    assert.equal(result.protocolVersion, 1); assert.equal(result.imageIngestionVersion, 1);
    assert.equal(result.packId, 'pack-a'); assert.equal(result.sha256, digest(bytes));
    assert.equal(result.byteLength, bytes.length); assert.equal(result.contentType, type);
    assert(result.width >= 1 && result.width <= 1024); assert(result.height >= 1 && result.height <= 1024);
    assert.match(result.imageReference, /^objects\/[a-f0-9]{64}\.(png|webp)$/);
    assert.notEqual(result.imageReference, `objects/${digest(bytes)}.${type.split('/')[1]}`);
    assert.deepEqual(await expect(await s.upload('pack-a', bytes, type)), result);
  }
  const rows = (await s.rows()).results; assert.equal(rows.length, 3);
  for (const row of rows) {
    assert.equal(row.state, 'ready');
    assert.equal(await s.bucket.head(row.object_reference), null, 'upload does not write canonical published keys');
    assert.equal((await s.bucket.head(row.staging_key)).httpMetadata.cacheControl, 'private, no-store');
    const stored = Buffer.from(await (await s.bucket.get(row.staging_key)).arrayBuffer());
    assert.equal(digest(stored), row.object_reference.slice(8, 72), 'transparent/source bytes are retained exactly');
  }
  assert.equal((await s.db.prepare("SELECT count(*) AS n FROM studio_entities WHERE resource_type='card'").first()).n, 0);
  assert.equal((await s.db.prepare("SELECT revision FROM studio_entities WHERE resource_type='pack' AND id='pack-a'").first()).revision, 1);
  const receipt = await expect(await s.upload());
  const result = await expect(await s.commit('pack', 'pack-a', [operation('card', 'card-a', 'create', {
    name: 'Prepared identity', packId: 'pack-a', imageReference: receipt.imageReference, difficulty: 2 })], 1));
  assert.equal(result.revision, 2);
  const attached = (await s.rows()).results.find(r => r.object_reference.endsWith('.png'));
  assert.equal(attached.state, 'attached'); assert(await s.bucket.head(attached.object_reference));
  const value = JSON.parse((await s.db.prepare("SELECT value FROM studio_entities WHERE resource_type='card' AND id='card-a'").first()).value);
  assert.equal(value.imageReference, attached.object_reference);
  await expect(await s.request('/content/v1/packs/pack-a/download'), 404, 'not_found');
});

test('CORS preflight is exact-origin; authorization and ownership independently reject IDOR', async t => {
  const s = await setup(t);
  const preflight = await s.request('/studio/v1/packs/pack-a/images', { actor: null, method: 'OPTIONS', headers: {
    'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'authorization,content-type,x-content-sha256,if-match' } });
  assert.equal(preflight.status, 204); assert.equal(preflight.headers.get('Access-Control-Allow-Origin'), origin);
  assert.match(preflight.headers.get('Access-Control-Allow-Headers'), /x-content-sha256/);
  for (const bad of ['https://evil.example', 'https://studio.saoudi.online.evil.example', 'null']) {
    const response = await s.upload('pack-a', png, 'image/png', { headers: { Origin: bad } });
    await expect(response, 403, 'forbidden'); assert.equal(response.headers.get('Access-Control-Allow-Origin'), null);
  }
  await expect(await s.upload('pack-a', png, 'image/png', { actor: null }), 401, 'unauthenticated');
  await expect(await s.upload('pack-b'), 404, 'not_found');
  await expect(await s.upload('missing'), 404, 'not_found');
  await expect(await s.upload('pack-b', png, 'image/png', { headers: { 'If-Match': '"rev-999"', 'X-Content-SHA256': 'bad' } }), 404, 'not_found');
  assert.deepEqual((await s.rows()).results, []); assert.deepEqual((await s.bucket.list()).objects, []);
  const receipt = await expect(await s.upload());
  await expect(await s.commit('pack', 'pack-b', [operation('card', 'foreign-image', 'create', {
    name: 'No foreign bytes', packId: 'pack-b', imageReference: receipt.imageReference, difficulty: 1 })], 1, { actor: 'b' }), 404, 'not_found');
  await expect(await s.upload('pack-b', png, 'image/png', { actor: 'owner' }));
  await s.setUsers(users.filter(u => u.uid !== 'a'));
  await expect(await s.upload(), 403, 'forbidden');
});

test('server rejects malicious hash, format, corruption, metadata, dimensions and stale/invalid preconditions before persistence', async t => {
  const s = await setup(t);
  await expect(await s.upload('pack-a', png, 'image/png', { headers: { 'X-Content-SHA256': '0'.repeat(64) } }), 422, 'validation_failed');
  await expect(await s.upload('pack-a', png, 'image/webp'), 422, 'validation_failed');
  await expect(await s.upload('pack-a', Buffer.from('<svg onload="evil()"/>'), 'image/svg+xml'), 422, 'validation_failed');
  await expect(await s.upload('pack-a', Buffer.from('broken'), 'image/png'), 422, 'validation_failed');
  const broken = Buffer.from(png); broken[broken.length - 1] ^= 1;
  await expect(await s.upload('pack-a', broken), 422, 'validation_failed');
  const brokenWebp = Buffer.from(webp); brokenWebp.fill(0, 25);
  await expect(await s.upload('pack-a', brokenWebp, 'image/webp'), 422, 'validation_failed');
  for (const bytes of [pngFixture({ badData: true }), pngFixture({ metadata: true }), pngFixture({ width: 1025 })]) {
    await expect(await s.upload('pack-a', bytes), 422, 'validation_failed');
  }
  const exif = Buffer.from('PRIVATE_AUTHOR'), tail = Buffer.concat([Buffer.from('EXIF'), Buffer.alloc(4), exif,
    ...(exif.length % 2 ? [Buffer.alloc(1)] : [])]);
  tail.writeUInt32LE(exif.length, 4);
  const metadataWebp = Buffer.concat([webp, tail]); metadataWebp.writeUInt32LE(metadataWebp.length - 8, 4);
  await expect(await s.upload('pack-a', metadataWebp, 'image/webp'), 422, 'validation_failed');
  await expect(await s.upload('pack-a', png, 'image/png', { headers: { 'X-Test-Truncate-Body': '1' } }), 400, 'upload_interrupted');
  await expect(await s.upload('pack-a', png, 'image/png', { headers: { 'X-Test-Broken-Stream': '1' } }), 400, 'upload_interrupted');
  await expect(await s.upload('pack-a', png, 'image/png', { headers: { 'If-Match': '"rev-999"' } }), 412, 'revision_conflict');
  await expect(await s.upload('pack-a', png, 'image/png', { headers: { 'If-Match': '' } }), 428, 'precondition_required');
  await expect(await s.upload('pack-a', Buffer.alloc(5 * 1024 * 1024 + 1)), 413, 'image_too_large');
  assert.deepEqual((await s.rows()).results, []); assert.deepEqual((await s.bucket.list()).objects, []);
});

test('interrupted storage reservation cleans privately; retry/dedup retains stable receipt and quotas', async t => {
  const s = await setup(t);
  await expect(await s.upload('pack-a', png, 'image/png', { headers: { 'X-Test-Fail-Stage': '1' } }), 503, 'storage_unavailable');
  assert.equal((await s.rows()).results[0].state, 'reserved');
  await expect(await s.upload(), 409, 'upload_in_progress');
  const canonical = `objects/${digest(png)}.png`;
  await s.bucket.put(canonical, png, { httpMetadata: { contentType: 'image/png' } });
  const before = await s.bucket.head(canonical);
  assert.equal((await s.cleanup()).removed, 1); assert.deepEqual((await s.rows()).results, []);
  assert.equal((await s.bucket.head(canonical)).etag, before.etag, 'cleanup never deletes canonical objects');
  const first = await expect(await s.upload()); const again = await expect(await s.upload());
  assert.deepEqual(first, again); assert.equal((await s.rows()).results.length, 1);
  assert.equal((await s.db.prepare('SELECT count(*) AS n FROM studio_pack_images').first()).n, 1);
});

test('atomic quota reservation admits one concurrent upload at the remaining Pack budget', async t => {
  const s = await setup(t), time = Math.floor(Date.now() / 1000);
  const capacity = 100 * 1024 * 1024, unit = 5 * 1024 * 1024;
  for (let i = 0; i < 20; i++) {
    const length = i === 19 ? unit - png.length : unit;
    await s.db.prepare(`INSERT INTO studio_image_uploads
      (pack_id,object_reference,actor_uid,request_uid,request_role,pack_revision,staging_key,byte_length,content_type,width,height,state,lease_token,lease_expires_at,expires_at,created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,'attached',?,?,?,?)`)
      .bind('pack-a', `objects/${String(i).padStart(64, '0')}.png`, 'a', 'a', 'collector', 1, null,
        length, 'image/png', 1, 1, randomUUID(), time + 300, time + 86400, time).run();
  }
  const replies = await Promise.all([s.upload(), s.upload('pack-a', webp, 'image/webp')]);
  assert.deepEqual(replies.map(r => r.status).sort(), [200, 429]);
  const total = await s.db.prepare("SELECT sum(byte_length) AS total FROM studio_image_uploads WHERE pack_id='pack-a'").first();
  assert(total.total <= capacity);
  const success = replies.find(r => r.status === 200); assert(success);
  await expect(replies.find(r => r.status === 429), 429, 'quota_exceeded');
});

test('orphan cleanup races cannot attach an expired binding; attached staging cleanup preserves canonical history', async t => {
  const s = await setup(t);
  const image = await expect(await s.upload());
  const canonical = `objects/${digest(png)}.png`;
  // An operator-owned canonical object predates this upload; cleanup can expire
  // the unused staging grant but must not alter that object.
  await s.bucket.put(canonical, png, { httpMetadata: { contentType: 'image/png' } });
  await expect(await s.commit('pack', 'pack-a', [operation('card', 'raced-card', 'create', {
    name: 'Race', packId: 'pack-a', imageReference: image.imageReference, difficulty: 1 })], 1,
    { headers: { 'X-Test-Cleanup-On-Canonical-Head': '1' } }), 422, 'validation_failed');
  assert.equal(await s.db.prepare("SELECT 1 FROM studio_entities WHERE resource_type='card' AND id='raced-card'").first(), null);
  assert(await s.bucket.head(canonical), 'canonical copies are immutable even on failed Commit');
  const retry = await expect(await s.upload());
  await expect(await s.commit('pack', 'pack-a', [operation('card', 'attached-card', 'create', {
    name: 'Safe', packId: 'pack-a', imageReference: retry.imageReference, difficulty: 1 })], 1));
  const row = (await s.rows()).results[0]; const key = row.staging_key;
  assert.equal(row.state, 'attached'); await s.cleanup();
  assert.equal(await s.bucket.head(key), null);
  assert(await s.bucket.head(canonical));
  assert.equal((await s.rows()).results[0].state, 'attached');
  assert.equal((await s.db.prepare('SELECT count(*) AS n FROM studio_pack_images').first()).n, 1);
  await expect(await s.request('/studio/v1/packs/pack-a/images', { method: 'DELETE' }), 404, 'not_found');
});

test('dedup renewal rechecks the current Pack revision after unrelated edits and preserves the receipt', async t => {
  const s = await setup(t);
  const first = await expect(await s.upload());
  await expect(await s.commit('pack', 'pack-a', [operation('pack', 'pack-a', 'update', { name: 'Edited Pack', topicId: 'topic' })], 1));
  const renewed = await expect(await s.upload('pack-a', png, 'image/png', { headers: { 'If-Match': '"rev-2"' } }));
  assert.deepEqual(renewed, first);
  const row = (await s.rows()).results[0]; assert.equal(row.pack_revision, 2); assert.equal(row.state, 'ready');
});

test('bounded operator scans continue beyond retained staging entries instead of starving old orphans', async t => {
  const s = await setup(t), time = Math.floor(Date.now() / 1000);
  await expect(await s.upload());
  const row = (await s.rows()).results[0];
  await s.bucket.put('studio-staging/v1/a-bound', png);
  await s.bucket.delete(row.staging_key);
  await s.db.prepare('UPDATE studio_image_uploads SET staging_key=?,expires_at=?').bind('studio-staging/v1/a-bound', time + 1000000).run();
  await s.bucket.put('studio-staging/v1/z-orphan', png);
  const clean = async () => {
    const result = await s.mf.dispatchFetch('https://api.example/__cleanup', { method: 'POST', body: JSON.stringify({ time: time + 90000, limit: 1 }) });
    assert.equal(result.status, 200, await result.clone().text()); return result.json();
  };
  assert.equal((await clean()).removed, 0);
  assert.equal((await clean()).removed, 1);
  assert(await s.bucket.head('studio-staging/v1/a-bound'));
  assert.equal(await s.bucket.head('studio-staging/v1/z-orphan'), null);
  assert.equal((await s.rows()).results.length, 1);
});

test('reference-count and per-UID byte quotas are enforced independently from a Pack byte quota', async t => {
  const s = await setup(t), time = Math.floor(Date.now() / 1000);
  const prefix = `INSERT INTO studio_image_uploads
    (pack_id,object_reference,actor_uid,request_uid,request_role,pack_revision,staging_key,byte_length,content_type,width,height,state,lease_token,lease_expires_at,expires_at,created_at)`;
  await s.db.prepare(`${prefix} WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<1000)
    SELECT 'pack-a','objects/' || printf('%064x',i) || '.png','a','a','collector',1,NULL,1,'image/png',1,1,'attached',printf('%064x',i),?,?,? FROM n`)
    .bind(time + 300, time + 86400, time).run();
  await expect(await s.upload(), 429, 'quota_exceeded');
  // Synthetic trusted quota fixtures: D1 guards count declared retained bytes;
  // no large allocations, network transfers or production objects are needed.
  await s.db.prepare('DELETE FROM studio_image_uploads').run();
  for (let i = 0; i < 5; i++) {
    const packId = `quota-${i}`;
    await expect(await s.commit('pack', packId, [operation('pack', packId, 'create', { name: packId, topicId: 'topic' })], 0));
    await s.db.prepare(`${prefix} WITH RECURSIVE n(j) AS (SELECT 1 UNION ALL SELECT j+1 FROM n WHERE j<20)
      SELECT ?,'objects/' || printf('%064x',j) || '.png','a','a','collector',1,NULL,5242880,'image/png',1,1,'attached',printf('%064x',j),?,?,? FROM n`)
      .bind(packId, time + 300, time + 86400, time).run();
  }
  await expect(await s.upload(), 429, 'quota_exceeded');
  assert.equal((await s.db.prepare("SELECT sum(byte_length) AS n FROM studio_image_uploads WHERE actor_uid='a'").first()).n, 500 * 1024 * 1024);
});

test('two bounded active transfers reject a third body and release capacity after completion', async t => {
  const s = await setup(t);
  const first = s.upload('pack-a', png, 'image/png', { headers: { 'X-Test-Hold-Body': 'first' } });
  const second = s.upload('pack-b', png, 'image/png', { actor: 'b', headers: { 'X-Test-Hold-Body': 'second' } });
  for (let i = 0; i < 50; i++) {
    const held = await (await s.mf.dispatchFetch('https://api.example/__held')).json();
    if (held.count === 2) break;
    if (i === 49) assert.fail('both body streams must reach the handler');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  try {
    await expect(await s.upload(), 429, 'rate_limited');
    await expect(await s.upload('missing'), 404, 'not_found', 'scope still precedes memory guard');
  } finally { await s.mf.dispatchFetch('https://api.example/__release'); }
  await expect(await first); await expect(await second);
  await expect(await s.upload());
});

test('failed Commits retain canonical storage charges through cleanup and permit safe retry', async t => {
  const s = await setup(t);
  const image = await expect(await s.upload());
  // First image is promoted, then a later operation fails validation. No Card
  // mutation is committed, but its immutable bytes must remain quota-charged.
  await expect(await s.commit('pack', 'pack-a', [operation('card', 'failed-card', 'create', {
    name: 'Candidate', packId: 'pack-a', imageReference: image.imageReference, difficulty: 1 }),
  operation('card', 'missing-card', 'update', { name: 'Missing', packId: 'pack-a', imageReference: image.imageReference, difficulty: 1 })], 1), 404, 'not_found');
  const before = (await s.rows()).results[0]; assert.equal(before.canonical_reserved, 1);
  assert.equal(before.state, 'ready');
  assert(await s.bucket.head(before.object_reference));
  await s.cleanup();
  const retained = (await s.rows()).results[0]; assert.equal(retained.canonical_reserved, 1);
  assert.equal(retained.byte_length, png.length); assert.equal(retained.staging_key, null);
  assert.equal((await s.db.prepare('SELECT sum(byte_length) AS n FROM studio_image_uploads').first()).n, png.length);
  assert.equal((await s.db.prepare("SELECT count(*) AS n FROM studio_entities WHERE resource_type='card'").first()).n, 0);
  assert.deepEqual(await expect(await s.upload()), image);
  await expect(await s.commit('pack', 'pack-a', [operation('card', 'retried-card', 'create', {
    name: 'Retry', packId: 'pack-a', imageReference: image.imageReference, difficulty: 1 })], 1));
});

test('cleanup during canonical promotion preserves its charge and a valid subsequent attachment', async t => {
  const s = await setup(t);
  const image = await expect(await s.upload());
  await expect(await s.commit('pack', 'pack-a', [operation('card', 'race-safe', 'create', {
    name: 'Safe race', packId: 'pack-a', imageReference: image.imageReference, difficulty: 1 })], 1,
    { headers: { 'X-Test-Cleanup-On-Promote': '1' } }));
  const row = (await s.rows()).results[0]; assert.equal(row.canonical_reserved, 1); assert.equal(row.state, 'attached');
  assert(await s.bucket.head(row.object_reference)); assert.equal(row.byte_length, png.length);
});

test('bounded cleanup prioritizes expired orphans over more retained recovery rows than its limit', async t => {
  const s = await setup(t), time = Math.floor(Date.now() / 1000);
  await expect(await s.upload());
  const unused = (await s.rows()).results[0];
  await s.db.prepare('UPDATE studio_image_uploads SET expires_at=2 WHERE pack_id=? AND object_reference=?')
    .bind(unused.pack_id, unused.object_reference).run();
  for (let i = 0; i < 2; i++) {
    await s.db.prepare(`INSERT INTO studio_image_uploads
      (pack_id,object_reference,actor_uid,request_uid,request_role,pack_revision,staging_key,byte_length,content_type,width,height,state,lease_token,lease_expires_at,expires_at,created_at,canonical_reserved)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,'ready',?,?,?,?,1)`)
      .bind('pack-a', `objects/${String(i).padStart(64, '0')}.png`, 'a', 'a', 'collector', 1,
        `studio-staging/v1/recover-${i}`, 1, 'image/png', 1, 1, randomUUID(), 1, 1, time).run();
  }
  const result = await s.mf.dispatchFetch('https://api.example/__cleanup', { method: 'POST', body: JSON.stringify({ time, limit: 1 }) });
  assert.equal(result.status, 200, await result.clone().text()); assert.equal((await result.json()).removed, 1);
  assert.equal(await s.bucket.head(unused.staging_key), null);
  const retained = (await s.rows()).results; assert.equal(retained.length, 2);
  assert(retained.every(row => row.canonical_reserved === 1));
  assert.equal(retained.reduce((n, row) => n + row.byte_length, 0), 2, 'recovery bytes remain permanently charged');
});
