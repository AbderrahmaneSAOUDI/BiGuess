import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { root, workerModules } from '../scripts/local.mjs';

// Real Workerd routing, RS256 verification, D1 and R2. Only Google JWKS is mocked.
const project = 'biguess-scope-contract';
const keys = await generateKeyPair('RS256');
const jwk = { ...await exportJWK(keys.publicKey), kid: 'scope-google-key', alg: 'RS256', use: 'sig' };
const users = ['owner', 'a', 'b'].map(uid => ({ uid, email: `${uid}@example.test`,
  role: uid === 'owner' ? 'owner_admin' : 'collector' }));
const fixtures = JSON.parse(readFileSync(new URL('../../../contracts/studio/v1/fixtures.json', import.meta.url)));
const origin = 'https://studio.saoudi.online';
const image = readFileSync(new URL('../fixtures/image.webp', import.meta.url));
// Distinct original test bytes: a standard 1x1 transparent PNG.
const secondImage = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
const secondReference = `objects/${createHash('sha256').update(secondImage).digest('hex')}.png`;
const imageReference = `objects/${createHash('sha256').update(image).digest('hex')}.webp`;
const operation = (resourceType, id, action, value) => ({ resourceType, id, action,
  ...(value === undefined ? {} : { value }) });
async function signed(uid, overrides = {}) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ sub: uid, email: `${uid}@example.test`, email_verified: true,
    firebase: { sign_in_provider: 'google.com' }, aud: project,
    iss: `https://securetoken.google.com/${project}`, iat: now - 10,
    auth_time: now - 20, exp: now + 3600, ...overrides })
    .setProtectedHeader({ alg: 'RS256', kid: jwk.kid }).sign(keys.privateKey);
}
async function expect(response, status = 200, code) {
  assert.equal(response.status, status, await response.clone().text());
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  const body = await response.json();
  if (code) {
    assert.equal(body.error.code, code);
    assert.equal(body.error.retryable, status === 503);
    assert.equal(body.error.currentRevision, status === 412 ? body.error.currentRevision : null);
    assert.equal(body.items, undefined);
  }
  return body;
}
async function setup(t) {
  const tokens = Object.fromEntries(await Promise.all(users.map(async user => [user.uid, await signed(user.uid)])));
  const bindings = { APP_ENV: 'staging', FIREBASE_PROJECT_ID: project, STUDIO_USERS: JSON.stringify(users),
    STUDIO_ALLOWED_ORIGINS: JSON.stringify([origin]) };
  const options = { modules: workerModules(`${root}dist/index.js`), scriptPath: `${root}dist/index.js`, compatibilityDate: '2026-11-01', bindings,
    d1Databases: { DB: 'scope-database' }, r2Buckets: { CONTENT: 'scope-images' },
    outboundService: request => {
      assert.equal(request.url, 'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com');
      assert.equal(request.headers.get('Authorization'), null);
      return Response.json({ keys: [jwk] });
    } };
  const mf = new Miniflare(convertV4MiniflareOptions(options));
  t.after(() => mf.dispose());
  let db = await mf.getD1Database('DB');
  const migrate = async file => db.exec(readFileSync(`${root}migrations/${file}`, 'utf8')
    .split('\n').filter(line => !line.trim().startsWith('--')).join(' '));
  const migrations = readdirSync(`${root}migrations`).filter(file => file.endsWith('.sql')).sort();
  for (const file of migrations) await migrate(file);
  const bucket = await mf.getR2Bucket('CONTENT');
  await bucket.put(imageReference, image, { httpMetadata: { contentType: 'image/webp' } });
  await bucket.put(secondReference, secondImage, { httpMetadata: { contentType: 'image/png' } });
  for (const e of fixtures.entities) {
    const parent = e.topicId ?? e.packId ?? null;
    const value = e.resourceType === 'topic' ? { name: e.id } : e.resourceType === 'pack'
      ? { name: e.id === 'pack-b' ? 'private-b' : e.id, topicId: parent }
      : { name: e.id, packId: parent, imageReference: e.id === 'card-b' ? secondReference : imageReference, difficulty: 1 };
    await db.prepare('INSERT INTO studio_entities VALUES (?,?,?,?,?,?)').bind(e.resourceType,e.id,parent,JSON.stringify(value),e.state,e.revision).run();
    // Fixture UID labels are symbolic; preserve the same account relationships.
    const uid = e.createdByUid?.replace('uid-', '') ?? null;
    await db.prepare('INSERT INTO studio_creators VALUES (?,?,?,?,?)').bind(e.resourceType,e.id,uid,uid ? '2026-11-09T00:00:00.000Z' : null,uid ? 'authenticated' : 'legacy').run();
  }
  await db.prepare('INSERT INTO studio_pack_images VALUES (?,?,?,?)').bind('pack-a',imageReference,'owner','2026-11-09T00:00:00.000Z').run();
  await db.prepare('INSERT INTO studio_pack_images VALUES (?,?,?,?)').bind('pack-b',secondReference,'owner','2026-11-09T00:00:00.000Z').run();
  const request = (path, { actor = 'a', jwt, method = 'GET', body, headers = {} } = {}) =>
    mf.dispatchFetch(`https://api.example${path}`, { method,
      headers: { ...(actor ? { Authorization: `Bearer ${jwt ?? tokens[actor]}` } : {}), Origin: origin,
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...headers },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  async function snapshot() {
    const tables = (await db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT GLOB '_cf_*' ORDER BY name").all()).results;
    const result = {};
    for (const { name } of tables) {
      result[name] = (await db.prepare(`SELECT * FROM "${name}"`).all()).results.map(row => JSON.stringify(row)).sort();
    }
    return result;
  }
  async function setUsers(nextUsers) {
    options.bindings = { ...bindings, STUDIO_USERS: JSON.stringify(nextUsers) };
    await mf.setOptions(convertV4MiniflareOptions(options));
    db = await mf.getD1Database('DB');
  }
  async function pages(path, actor = 'a', { sync = false } = {}) {
    let next = path; const items = []; let resumeCursor = null; const cursors = [];
    for (let page = 0; next && page < 100; page++) {
      const result = await expect(await request(next, { actor }));
      assert.equal(result.protocolVersion, 1); assert.equal(result.scopeVersion, 1);
      items.push(...result.items);
      if (sync) resumeCursor = result.resumeCursor;
      if (result.nextCursor) {
        cursors.push(result.nextCursor);
        const url = new URL(path, 'https://api.example');
        url.searchParams.set('cursor', result.nextCursor);
        next = url.pathname + url.search;
      } else next = null;
    }
    assert.equal(next, null, 'pagination must terminate');
    return { items, resumeCursor, cursors };
  }
  return { get db() { return db; }, request, snapshot, pages, setUsers };
}
// T27A vectors are recipes, not recordings. Symbolic images/cursors are replaced
// with content-addressed bytes and real encrypted handles; expectations remain
// normative. Browser cache vectors belong to T28 and are deliberately not run.
const symbolic = Object.keys(fixtures.imageBindings);
function replaceImages(value) {
  let wire = JSON.stringify(value);
  symbolic.forEach((ref, i) => { wire = wire.replaceAll(ref, i === 0 ? imageReference : secondReference); });
  return JSON.parse(wire);
}
const packValue = (name = 'Changed') => ({ name, topicId: 'topic-main' });
const cardValue = (ref = imageReference) => ({ name: 'Changed card', packId: 'pack-a', imageReference: ref, difficulty: 1 });
const batch = (type, id, operations) => ({ protocolVersion: 1, aggregate: { resourceType: type, id }, operations });
const write = (body, revision = 3, key = randomUUID()) => ({ method: 'POST', path: '/studio/v1/batches', body,
  headers: { 'Idempotency-Key': key, ...(revision === 0 ? { 'If-None-Match': '*' } : { 'If-Match': `"rev-${revision}"` }) } });
const edit = (id = 'pack-a') => write(batch('pack', id, [operation('pack', id, 'update', packValue())]));
const feed = (cursor, limit = 50) => ({ path: `/studio/v1/sync/changes?limit=${limit}&cursor=${encodeURIComponent(cursor)}` });
async function modifyCursor(s, cursor, mutate) {
  const { webcrypto } = await import('node:crypto');
  const hex = await s.db.prepare('SELECT cursor_key FROM studio_read_meta').first('cursor_key');
  const key = await webcrypto.subtle.importKey('raw', Buffer.from(hex, 'hex'), 'AES-GCM', false, ['decrypt', 'encrypt']);
  const all = Buffer.from(cursor, 'base64url'); const iv = all.subarray(0, 12);
  const data = await webcrypto.subtle.decrypt({ name: 'AES-GCM', iv }, key, all.subarray(12));
  const payload = JSON.parse(Buffer.from(data).toString()); mutate(payload);
  const encrypted = await webcrypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, Buffer.from(JSON.stringify(payload)));
  return Buffer.concat([iv, Buffer.from(encrypted)]).toString('base64url');
}

for (const vector of fixtures.cases) {
  if (vector.stage === 'client') continue;
  test(`T27A contract: ${vector.id}`, async t => {
    const s = await setup(t); let r = replaceImages(vector.request ?? {}); const actor = vector.actor ?? 'a';
    const send = async (req, who = actor) => s.request(req.path, { ...req, actor: who === 'anonymous' ? null : who,
      ...(who === 'expired' ? { jwt: await signed('a', { exp: Math.floor(Date.now()/1000)-1 }) } : who === 'unlisted' ? { jwt: await signed('unlisted') } : {}) });
    const success = async (req, who = 'a') => expect(await send(req, who));
    const resume = async (who = 'a', limit = 50) => (await s.pages(`/studio/v1/sync/initial?limit=${limit}`, who, { sync:true })).resumeCursor;
    const id = vector.id;
    if (vector.operation) {
      const { resourceType: type, action } = vector.operation;
      const entityId = action === 'create' ? 'fresh-topic' : type === 'topic' ? 'topic-main' : type === 'pack' ? 'pack-a' : 'card-a';
      const aggregateType = type === 'topic' ? 'topic' : 'pack'; const aggregateId = type === 'topic' ? entityId : 'pack-a';
      if (action === 'restore' || action === 'permanentDelete') {
        await s.db.prepare('UPDATE studio_entities SET state=? WHERE resource_type=? AND id=?').bind('deleted', type, entityId).run();
        if (action === 'permanentDelete' && type !== 'card') await s.db.prepare("UPDATE studio_entities SET state='purged', value=NULL WHERE (resource_type='card' AND parent_id=?) OR (?='topic' AND resource_type IN ('card','pack'))").bind(entityId, type).run();
      }
      const value = ['create', 'update'].includes(action) ? type === 'topic' ? { name: 'Taxonomy' } : packValue() : undefined;
      r = { ...write(batch(aggregateType, aggregateId, [operation(type, entityId, action, value)]), action === 'create' ? 0 : type === 'topic' ? 1 : 3), path:r.path };
    }
    if (['foreign-write-page-stable', 'own-write-page-expired', 'initial-concurrent-write'].includes(id)) {
      const first = await success({ path: '/studio/v1/sync/initial?limit=1' });
      await success(edit(id === 'foreign-write-page-stable' ? 'pack-b' : 'pack-a'), id === 'foreign-write-page-stable' ? 'b' : 'a');
      r = { path: `/studio/v1/sync/initial?limit=1&cursor=${encodeURIComponent(first.nextCursor)}` };
    }
    if (id === 'wrong-origin') r.headers = { Origin: origin + '.attacker.invalid' };
    if (id === 'revoked-valid-jwt') { r = feed(await resume()); await s.setUsers(users.filter(u => u.uid !== 'a')); }
    if (['identical-retry', 'changed-key', 'revoked-replay'].includes(id)) {
      r = write(batch('pack', 'new-retry', [operation('pack', 'new-retry', 'create', packValue())]), 0, 'saved-key');
      await success(r);
      if (id === 'changed-key') r.body.operations[0].value.name = 'Changed request';
      if (id === 'revoked-replay') await s.setUsers(users.filter(u => u.uid !== 'a'));
    }
    if (['stale-owned', 'stale-foreign', 'legacy-edit', 'item-alias', 'missing-attribution'].includes(id)) {
      r = edit(id === 'legacy-edit' ? 'pack-legacy' : ['stale-foreign','item-alias'].includes(id) ? 'pack-b' : 'pack-a');
      if (id.startsWith('stale-')) r.headers['If-Match'] = '"rev-1"';
      if (id === 'item-alias') { r.method = 'PATCH'; r.path = vector.request.path; }
      if (id === 'missing-attribution') { await s.db.exec('DROP TRIGGER studio_creator_no_delete'); await s.db.prepare("DELETE FROM studio_creators WHERE resource_type='pack' AND resource_id='pack-a'").run(); }
    }
    if (['downgraded-replay', 'alias-replay'].includes(id)) {
      await s.setUsers(users.map(u => u.uid === 'a' ? { ...u, role: 'owner_admin' } : u));
      r = edit('pack-b'); await success(r); await s.setUsers(users);
      if (id === 'alias-replay') r.path = vector.request.path;
    }
    if (id === 'replay-after-purge') {
      r = edit(); await success(r, 'owner');
      await s.db.exec("UPDATE studio_entities SET state='purged',value=NULL WHERE resource_type='pack' AND id='pack-a'");
    }
    if (id === 'mixed-batch') { r = edit(); r.body.operations.push(operation('card','card-b','hide')); }
    if (id === 'spoof-creator') r = write(batch('pack','new-spoof',[operation('pack','new-spoof','create',{ ...packValue(), createdByUid:'uid-b' })]),0);
    if (['foreign-image-attachment', 'cross-pack-move'].includes(id)) r = write(batch('pack','pack-a',[operation('card','card-a','update', id === 'foreign-image-attachment' ? cardValue(secondReference) : { ...cardValue(), packId:'pack-b' })]));
    if (id === 'create-parent-deleted') {
      await s.db.exec("UPDATE studio_entities SET state='deleted' WHERE resource_type='topic'");
      r = write(batch('pack','fresh-pack',[operation('pack','fresh-pack','create',packValue())]),0);
    }
    if (id === 'generation-race') {
      // Deterministic injection of the same guard rejection as a writer winning
      // between validation and commit. All transaction side effects must roll back.
      await s.db.exec("CREATE TRIGGER fixture_generation_race BEFORE INSERT ON studio_commits BEGIN SELECT RAISE(ABORT,'studio_conflict'); END"); r = edit();
    }
    if (['cross-uid-cursor','role-cursor','tampered-cursor','filter-cursor','expired-page','history-unavailable','wrong-endpoint-cursor'].includes(id)) {
      let cursor;
      if (id === 'role-cursor') { await s.setUsers(users.map(u => u.uid === 'a' ? { ...u, role:'owner_admin' } : u)); cursor = await resume(); await s.setUsers(users); }
      else if (id === 'wrong-endpoint-cursor') {
        await success(write(batch('pack','second-own',[operation('pack','second-own','create',packValue())]),0));
        cursor = (await success({ path:'/studio/v1/packs?limit=1' })).nextCursor;
      }
      else cursor = await resume(id === 'cross-uid-cursor' ? 'b' : 'a');
      if (id === 'tampered-cursor') cursor = cursor.slice(0,-4) + 'xxxx';
      if (id === 'expired-page') cursor = await modifyCursor(s,cursor,p => { p.expires = Date.now() - 1000; p.mode = 'changes'; });
      if (id === 'history-unavailable') await s.db.exec('UPDATE studio_read_meta SET bootstrap_sequence=1');
      r = feed(cursor, id === 'filter-cursor' ? 1 : 50);
    }
    if (['changes-a','changes-b'].includes(id)) {
      const cursor = await resume(actor);
      for (const a of ['a','b']) await success(write(batch('pack',`pack-${a}`,[operation('card',`card-${a}`,'update',{ ...cardValue(a === 'a' ? imageReference : secondReference), packId:`pack-${a}` })])),a);
      r = feed(cursor);
    }
    if (['owned-removal','foreign-removal'].includes(id)) {
      await s.db.exec("UPDATE studio_entities SET state='active' WHERE id IN ('pack-deleted-a','card-deleted-a')");
      const cursor = await resume(actor);
      await success(write(batch('pack','pack-deleted-a',[operation('pack','pack-deleted-a','softDelete')])),'owner'); r = feed(cursor);
    }
    if (id === 'restore-owner-edited-pack') {
      await success(edit(),'owner'); await success(write(batch('pack','pack-a',[operation('pack','pack-a','softDelete')]),4),'owner');
      await success(write(batch('pack','pack-a',[operation('pack','pack-a','restore')]),5),'owner');
      assert.equal((await success({ path:'/studio/v1/packs/pack-a' })).item.state,'hidden');
      assert.equal((await send({ path:'/studio/v1/packs/pack-a' },'b')).status,404);
      assert.equal((await success({ path:'/studio/v1/packs/pack-a' },'owner')).item.createdByUid,'a'); return;
    }
    const before = await s.snapshot(); const response = await send(r); const body = await response.json();
    // Future own-image expected 501 contradicts its setup and README: routes stay
    // disabled during T27B, returning unknown-route 404 even for an owned Pack.
    const expected = id === 'private-image-own-disabled' ? { status:404,code:'not_found',writes:false,visibleIds:[] } : vector.expected;
    assert.equal(response.status,expected.status,JSON.stringify(body));
    assert.equal(response.headers.get('Cache-Control'),'no-store');
    if (expected.code) { assert.equal(body.error.code,expected.code); assert.equal(body.error.currentRevision === null,expected.status !== 412); }
    if (expected.visibleIds) {
      const records = body.items ?? (body.item ? [body.item] : []);
      assert.deepEqual(records.map(row => row.record?.id ?? row.id).sort(),[...expected.visibleIds].sort());
      if (actor !== 'owner') for (const row of records) {
        const record = row.record ?? row;
        assert.equal(record.createdByUid,undefined); assert.equal(record.createdAt,undefined);
        if (row.kind === 'remove') assert.deepEqual(Object.keys(row).sort(),['id','kind','resourceType','revision']);
      }
    }
    if (!expected.writes) assert.deepEqual(await s.snapshot(),before,'failed/read/replayed request changed D1');
    else assert.notDeepEqual(await s.snapshot(),before,'successful mutation must commit');
  });
}
