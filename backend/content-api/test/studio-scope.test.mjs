import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { root } from '../scripts/local.mjs';

// Real Workerd routing, RS256 verification, D1 and R2. Only Google JWKS is mocked.
const project = 'biguess-scope-test';
const keys = await generateKeyPair('RS256');
const jwk = { ...await exportJWK(keys.publicKey), kid: 'scope-google-key', alg: 'RS256', use: 'sig' };
const users = ['owner', 'a', 'b'].map(uid => ({ uid, email: `${uid}@example.test`,
  role: uid === 'owner' ? 'owner_admin' : 'collector' }));
const origin = 'https://studio.saoudi.online';
const image = readFileSync(new URL('../fixtures/image.webp', import.meta.url));
const imageReference = `objects/${createHash('sha256').update(image).digest('hex')}.webp`;
const operation = (resourceType, id, action, value) => ({ resourceType, id, action,
  ...(value === undefined ? {} : { value }) });
const newPack = id => operation('pack', id, 'create', { name: `Private ${id}`, topicId: 'topic' });
const newCard = (id, packId) => operation('card', id, 'create', { name: `Private ${id}`,
  packId, imageReference, difficulty: 1 });
const editPack = (id, name = `Changed ${id}`) => operation('pack', id, 'update', { name, topicId: 'topic' });
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
async function setup(t, { legacy = true } = {}) {
  const tokens = Object.fromEntries(await Promise.all(users.map(async user => [user.uid, await signed(user.uid)])));
  const bindings = { APP_ENV: 'staging', FIREBASE_PROJECT_ID: project, STUDIO_USERS: JSON.stringify(users),
    STUDIO_ALLOWED_ORIGINS: JSON.stringify([origin]) };
  const options = { modules: true, scriptPath: `${root}dist/index.js`, compatibilityDate: '2026-11-01', bindings,
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
  for (const file of migrations.filter(file => file < '0006')) await migrate(file);
  if (legacy) {
    await db.prepare('INSERT INTO studio_entities VALUES (?, ?, ?, ?, ?, ?)')
      .bind('topic', 'legacy-topic', null, JSON.stringify({ name: 'Legacy taxonomy' }), 'active', 1).run();
    await db.prepare('INSERT INTO studio_entities VALUES (?, ?, ?, ?, ?, ?)')
      .bind('pack', 'legacy-pack', 'legacy-topic', JSON.stringify({ name: 'Legacy secret', topicId: 'legacy-topic' }), 'hidden', 7).run();
    await db.prepare('INSERT INTO studio_entities VALUES (?, ?, ?, ?, ?, ?)')
      .bind('pack', 'purged-legacy', 'legacy-topic', null, 'purged', 8).run();
  }
  const preMigration = (await db.prepare('SELECT * FROM studio_entities ORDER BY resource_type, id').all()).results;
  const oldTables = {};
  const oldNames = (await db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT GLOB '_cf_*'").all()).results;
  for (const { name } of oldNames) oldTables[name] = (await db.prepare(`SELECT * FROM "${name}"`).all()).results;
  for (const file of migrations.filter(file => file >= '0006')) await migrate(file);
  const bucket = await mf.getR2Bucket('CONTENT');
  await bucket.put(imageReference, image, { httpMetadata: { contentType: 'image/webp' } });
  const request = (path, { actor = 'a', jwt, method = 'GET', body, headers = {} } = {}) =>
    mf.dispatchFetch(`https://api.example${path}`, { method,
      headers: { ...(actor ? { Authorization: `Bearer ${jwt ?? tokens[actor]}` } : {}), Origin: origin,
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...headers },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  const commit = (type, id, operations, revision, { actor = 'owner', key = randomUUID(), path = '/studio/v1/batches', method = 'POST', ...other } = {}) =>
    request(path, { actor, method, body: { protocolVersion: 1, aggregate: { resourceType: type, id }, operations },
      headers: { 'Idempotency-Key': key, ...(revision === undefined ? {} : revision === 0
        ? { 'If-None-Match': '*' } : { 'If-Match': `"rev-${revision}"` }) }, ...other });
  const row = (type, id) => db.prepare('SELECT * FROM studio_entities WHERE resource_type = ? AND id = ?').bind(type, id).first();
  const bindImage = packId => db.prepare('INSERT INTO studio_pack_images (pack_id, object_reference, established_by_uid, created_at) VALUES (?, ?, ?, ?)')
    .bind(packId, imageReference, 'owner', new Date().toISOString()).run();
  async function seed() {
    await expect(await commit('topic', 'topic', [operation('topic', 'topic', 'create', { name: 'Shared taxonomy' })], 0));
    for (const uid of ['a', 'b']) {
      await bindImage(`pack-${uid}`);
      await expect(await commit('pack', `pack-${uid}`, [newPack(`pack-${uid}`), newCard(`card-${uid}`, `pack-${uid}`)], 0, { actor: uid }));
    }
  }
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
  return { mf, db, request, commit, row, seed, bindImage, snapshot, pages, setUsers, preMigration, oldTables };
}
const ids = items => items.map(row => row.id).sort();
const cursorPath = (endpoint, cursor, extra = '') => `/studio/v1/${endpoint}?cursor=${encodeURIComponent(cursor)}${extra}`;

// Minimal taxonomy remains globally visible, without making its Pack children public.
test('Owner sees all drafts; each Collector sees only own Packs/Cards and minimal shared taxonomy', async t => {
  const s = await setup(t); await s.seed();
  assert.deepEqual(ids((await s.pages('/studio/v1/packs?limit=1')).items), ['pack-a']);
  assert.deepEqual(ids((await s.pages('/studio/v1/packs?limit=1', 'b')).items), ['pack-b']);
  assert.deepEqual(ids((await s.pages('/studio/v1/packs?limit=1', 'owner')).items), ['legacy-pack', 'pack-a', 'pack-b']);
  const topics = (await s.pages('/studio/v1/topics?limit=1')).items;
  assert.deepEqual(ids(topics), ['legacy-topic', 'topic']);
  for (const topic of topics) assert.deepEqual(Object.keys(topic).sort(), ['id', 'name', 'resourceType', 'revision', 'state']);
  const own = await expect(await s.request('/studio/v1/packs/pack-a'));
  assert.equal(own.item.id, 'pack-a'); assert.equal(own.item.createdByUid, undefined);
  assert.deepEqual(ids((await s.pages('/studio/v1/packs/pack-a/cards?limit=1')).items), ['card-a']);
  const owner = await expect(await s.request('/studio/v1/packs/pack-a', { actor: 'owner' }));
  assert.equal(owner.item.createdByUid, 'a');
  assert.deepEqual((await s.pages('/studio/v1/packs?q=pack-b')).items, []);
  assert.deepEqual(ids((await s.pages('/studio/v1/packs?q=PACK-A')).items), ['pack-a']);
  for (const path of ['/studio/v1/packs/pack-b', '/studio/v1/packs/legacy-pack', '/studio/v1/cards/card-b',
    '/studio/v1/packs/pack-b/cards', '/studio/v1/packs/no-such-pack']) {
    const failure = await expect(await s.request(path), 404, 'not_found');
    assert.doesNotMatch(JSON.stringify(failure), /Private|Legacy secret|card-b|pack-b|"revision":/);
  }
  await expect(await s.request('/studio/v1/audit?packId=pack-b'), 403, 'forbidden');
  await expect(await s.request('/studio/v1/audit?packId=pack-b', { actor: 'owner' }));
  await expect(await s.request('/content/v1/studio/packs'), 404, 'not_found');
});

test('every mutation route checks stored ownership before foreign revision or image data, atomically', async t => {
  const s = await setup(t); await s.seed();
  const before = await s.snapshot();
  const rejected = [
    () => s.commit('pack', 'pack-b', [editPack('pack-b')], 1, { actor: 'a' }),
    () => s.commit('pack', 'pack-b', [operation('pack', 'pack-b', 'hide')], 999, { actor: 'a' }),
    () => s.commit('pack', 'legacy-pack', [operation('pack', 'legacy-pack', 'hide')], 7, { actor: 'a' }),
    () => s.commit('pack', 'pack-a', [operation('card', 'card-b', 'hide')], 1, { actor: 'a' }),
    () => s.commit('pack', 'pack-a', [operation('pack', 'pack-a', 'hide'), operation('card', 'card-b', 'hide')], 1, { actor: 'a' }),
    () => s.commit('pack', 'pack-b', [editPack('pack-b')], 1, { actor: 'a', path: '/content/v1/studio/packs/pack-b', method: 'PATCH' }),
    () => s.commit('pack', 'pack-b', [newPack('pack-b')], 0, { actor: 'a' }),
  ];
  for (const send of rejected) {
    await expect(await send(), 404, 'not_found');
    assert.deepEqual(await s.snapshot(), before, 'denied request must not write any table');
  }
  await expect(await s.commit('pack', 'pack-a', [operation('pack', 'pack-a', 'update',
    { name: 'Spoof', topicId: 'topic', createdByUid: 'b' })], 1, { actor: 'a' }), 422, 'validation_failed');
  assert.deepEqual(await s.snapshot(), before);
  for (const action of ['softDelete', 'restore', 'permanentDelete']) {
    await expect(await s.commit('pack', 'pack-a', [operation('pack', 'pack-a', action)], 1, { actor: 'a' }), 403, 'forbidden');
  }
  assert.deepEqual(await s.snapshot(), before);
});

test('creator attribution is immutable, inherited by Cards, and retained through Owner lifecycle changes', async t => {
  const s = await setup(t); await s.seed();
  await expect(await s.commit('pack', 'pack-a', [newCard('owner-card', 'pack-a')], 1));
  const creator = (type, id) => s.db.prepare('SELECT * FROM studio_creators WHERE resource_type = ? AND resource_id = ?').bind(type, id).first();
  assert.equal((await creator('pack', 'pack-a')).created_by_uid, 'a');
  assert.equal((await creator('card', 'owner-card')).created_by_uid, 'owner');
  await expect(await s.request('/studio/v1/cards/owner-card'));
  await expect(await s.request('/studio/v1/cards/owner-card', { actor: 'b' }), 404, 'not_found');
  await assert.rejects(s.db.prepare("UPDATE studio_creators SET created_by_uid = 'b' WHERE resource_type = 'pack' AND resource_id = 'pack-a'").run(), /immutable|creator/i);
  await assert.rejects(s.db.prepare("DELETE FROM studio_creators WHERE resource_type = 'pack' AND resource_id = 'pack-a'").run(), /immutable|creator/i);
  await expect(await s.commit('pack', 'pack-a', [editPack('pack-a', 'Owner edit')], 2));
  await expect(await s.commit('pack', 'pack-a', [operation('pack', 'pack-a', 'softDelete')], 3));
  await expect(await s.request('/studio/v1/packs/pack-a'), 404, 'not_found');
  await expect(await s.commit('pack', 'pack-a', [operation('pack', 'pack-a', 'restore')], 4));
  const restored = await expect(await s.request('/studio/v1/packs/pack-a'));
  assert.equal(restored.item.state, 'hidden');
  assert.equal((await creator('pack', 'pack-a')).created_by_uid, 'a');
  assert.equal((await s.row('card', 'owner-card')).state, 'deleted');
  await expect(await s.commit('pack', 'pack-a', [operation('card', 'owner-card', 'restore')], 5));
  await expect(await s.request('/studio/v1/cards/owner-card'));
});

test('idempotency replay preserves original result and denies formerly privileged foreign commits after downgrade', async t => {
  const s = await setup(t); await s.seed();
  const key = 'owner-edits-b'; const operationB = [editPack('pack-b')];
  const first = await expect(await s.commit('pack', 'pack-b', operationB, 1, { key }));
  const saved = await s.snapshot();
  assert.deepEqual(await expect(await s.commit('pack', 'pack-b', operationB, 1, { key })), first);
  assert.deepEqual(await s.snapshot(), saved);
  await s.setUsers(users.map(user => user.uid === 'owner' ? { ...user, role: 'collector' } : user));
  const beforeDenied = await s.snapshot();
  await expect(await s.commit('pack', 'pack-b', operationB, 1, { key }), 404, 'not_found');
  await expect(await s.commit('pack', 'pack-b', [editPack('pack-b', 'Different')], 1, { key }), 404, 'not_found');
  assert.deepEqual(await s.snapshot(), beforeDenied);
  // Create retries authorize against the now-persisted creator before stale preconditions.
  const keyA = 'a-creates-new'; const newA = [newPack('new-a')];
  const created = await expect(await s.commit('pack', 'new-a', newA, 0, { actor: 'a', key: keyA }));
  assert.deepEqual(await expect(await s.commit('pack', 'new-a', newA, 0, { actor: 'a', key: keyA })), created);
  await expect(await s.commit('pack', 'new-a', [newPack('other')], 0, { actor: 'a', key: keyA }), 409, 'idempotency_conflict');
});

test('initial sync is paginated, account-scoped and version-bound without leaking foreign-only activity', async t => {
  const s = await setup(t); await s.seed();
  const initial = await s.pages('/studio/v1/sync/initial?limit=1', 'a', { sync: true });
  assert.deepEqual(ids(initial.items), ['card-a', 'legacy-topic', 'pack-a', 'topic']);
  assert.ok(initial.resumeCursor); assert.ok(initial.cursors.length >= 2);
  assert.equal(new Set(initial.items.map(row => `${row.resourceType}:${row.id}`)).size, initial.items.length);
  const first = await expect(await s.request('/studio/v1/sync/initial?limit=1'));
  assert.equal(first.resumeCursor, null); assert.ok(first.nextCursor);
  const next = cursorPath('sync/initial', first.nextCursor, '&limit=1');
  await expect(await s.request(next, { actor: 'b' }), 409, 'cursor_expired');
  const tampered = first.nextCursor.slice(0, -3) + 'xyz';
  await expect(await s.request(cursorPath('sync/initial', tampered, '&limit=1')), 409, 'cursor_expired');
  await expect(await s.request(cursorPath('sync/initial', first.nextCursor, '&limit=2')), 409, 'cursor_expired');
  await expect(await s.request(cursorPath('packs', first.nextCursor, '&limit=1')), 409, 'cursor_expired');
  await expect(await s.commit('pack', 'pack-b', [editPack('pack-b')], 1, { actor: 'b' }));
  await expect(await s.request(next));
  await expect(await s.commit('pack', 'pack-a', [editPack('pack-a')], 1, { actor: 'a' }));
  await expect(await s.request(next), 409, 'cursor_expired');
});

test('change feeds keep foreign upserts/removals private and expose owned deletion only as minimal tombstones', async t => {
  const s = await setup(t); await s.seed();
  const initialA = await s.pages('/studio/v1/sync/initial?limit=1', 'a', { sync: true });
  const initialB = await s.pages('/studio/v1/sync/initial?limit=1', 'b', { sync: true });
  await expect(await s.commit('pack', 'pack-a', [editPack('pack-a', 'Only a knows')], 1, { actor: 'a' }));
  await expect(await s.commit('pack', 'pack-b', [editPack('pack-b', 'Only b knows')], 1, { actor: 'b' }));
  const changesA = await s.pages(cursorPath('sync/changes', initialA.resumeCursor, '&limit=1'), 'a', { sync: true });
  assert.ok(changesA.items.some(event => event.kind === 'upsert' && event.record.id === 'pack-a'));
  assert.doesNotMatch(JSON.stringify(changesA.items), /Only b knows|pack-b|card-b|createdByUid|sequence|generation/);
  await expect(await s.commit('pack', 'pack-a', [operation('pack', 'pack-a', 'softDelete')], 2));
  const removalsA = await s.pages(cursorPath('sync/changes', changesA.resumeCursor, '&limit=1'), 'a', { sync: true });
  assert.deepEqual(removalsA.items.map(event => event.id).sort(), ['card-a', 'pack-a']);
  for (const event of removalsA.items) {
    assert.equal(event.kind, 'remove');
    assert.deepEqual(Object.keys(event).sort(), ['id', 'kind', 'resourceType', 'revision']);
  }
  const changesB = await s.pages(cursorPath('sync/changes', initialB.resumeCursor, '&limit=1'), 'b', { sync: true });
  assert.doesNotMatch(JSON.stringify(changesB.items), /pack-a|card-a|Only a knows/);
  // Replaying old historical upserts after deletion must not resurrect their private fields.
  const oldA = await s.pages(cursorPath('sync/changes', initialA.resumeCursor, '&limit=1'), 'a', { sync: true });
  assert.ok(oldA.items.every(event => event.kind === 'remove'));
  await expect(await s.request(cursorPath('sync/changes', initialA.resumeCursor, '&limit=1'), { actor: 'b' }), 409, 'cursor_expired');
});

test('expired/revoked identity and role changes fail before dataset or cursor access', async t => {
  const s = await setup(t); await s.seed();
  const initial = await s.pages('/studio/v1/sync/initial', 'a', { sync: true });
  const path = cursorPath('sync/changes', initial.resumeCursor);
  await expect(await s.request(path, { jwt: await signed('a', { exp: Math.floor(Date.now() / 1000) - 1 }) }), 401, 'unauthenticated');
  await expect(await s.request('/studio/v1/sync/initial', { actor: null }), 401, 'unauthenticated');
  await expect(await s.request('/studio/v1/sync/initial', { jwt: await signed('outsider') }), 403, 'forbidden');
  await s.setUsers(users.filter(user => user.uid !== 'a'));
  await expect(await s.request(path), 403, 'forbidden');
  await expect(await s.request('/studio/v1/sync/initial'), 403, 'forbidden');
});

test('image authorization is object-to-Pack bound and disabled image routes disclose nothing', async t => {
  const s = await setup(t); await s.seed();
  await expect(await s.commit('pack', 'empty-a', [newPack('empty-a')], 0, { actor: 'a' }));
  const before = await s.snapshot();
  await expect(await s.commit('pack', 'empty-a', [newCard('steal-image', 'empty-a')], 1, { actor: 'a' }), 404, 'not_found');
  assert.deepEqual(await s.snapshot(), before);
  await expect(await s.request('/studio/v1/packs/pack-b/images/guess'), 404, 'not_found');
  await expect(await s.request('/studio/v1/packs/pack-a/images/guess'), 404, 'not_found');
  assert.deepEqual(await s.snapshot(), before);
});

test('migration preserves old entities, backfills legacy and purge fences without granting ownership', async t => {
  const s = await setup(t);
  for (const [name, rows] of Object.entries(s.oldTables)) {
    assert.deepEqual((await s.db.prepare(`SELECT * FROM "${name}"`).all()).results, rows, `migration must preserve ${name}`);
  }
  assert.deepEqual((await s.db.prepare('SELECT * FROM studio_entities ORDER BY resource_type, id').all()).results, s.preMigration);
  const creators = (await s.db.prepare('SELECT * FROM studio_creators ORDER BY resource_type, resource_id').all()).results;
  assert.equal(creators.length, s.preMigration.length);
  assert.ok(creators.every(row => row.created_by_uid === null && row.created_at === null && row.source === 'legacy'));
  assert.equal(await s.db.prepare('SELECT count(*) AS n FROM studio_read_changes').first('n'), 0);
  assert.equal((await expect(await s.request('/studio/v1/packs/legacy-pack', { actor: 'owner' }))).item.createdByUid, null);
  await expect(await s.request('/studio/v1/packs/legacy-pack'), 404, 'not_found');
  await expect(await s.commit('pack', 'legacy-pack', [operation('pack', 'legacy-pack', 'hide')], 7, { actor: 'a' }), 404, 'not_found');
  await s.seed();
  const afterNewWrites = await s.snapshot();
  const additive = readdirSync(`${root}migrations`).filter(file => file.startsWith('0006') && file.endsWith('.sql'));
  assert.equal(additive.length, 1);
  await s.db.exec(readFileSync(`${root}migrations/${additive[0]}`, 'utf8')
    .split('\n').filter(line => !line.trim().startsWith('--')).join(' '));
  assert.deepEqual(await s.snapshot(), afterNewWrites, 'reapplying additive migration preserves new creator evidence, cursor keys and versions');
});

test('anonymous catalog remains published-only; private reads reject broad CORS and query ambiguity', async t => {
  const s = await setup(t); await s.seed();
  const anonymous = await s.request('/content/v1/catalog/topics', { actor: null, headers: { Origin: 'https://any.example' } });
  assert.equal(anonymous.status, 200);
  assert.deepEqual((await anonymous.json()).items, []);
  for (const query of ['limit=0', 'limit=101', 'limit=1&limit=2', 'owner=a', 'q=%20trim%20', 'q=' + 'x'.repeat(101), 'state=unknown']) {
    await expect(await s.request('/studio/v1/packs?' + query), 400, 'invalid_request');
  }
  await expect(await s.request('/studio/v1/packs?state=deleted'), 403, 'forbidden');
  const cors = await s.request('/studio/v1/packs', { headers: { Origin: 'https://studio.saoudi.online.attacker.invalid' } });
  await expect(cors, 403, 'forbidden'); assert.equal(cors.headers.get('Access-Control-Allow-Origin'), null);
  const accepted = await s.request('/studio/v1/packs');
  assert.equal(accepted.headers.get('Access-Control-Allow-Origin'), origin);
  assert.match(accepted.headers.get('Vary'), /Origin/);
});

test('failed change capture rolls back creator, revision, feed, scope counters and idempotency; retry remains safe', async t => {
  const s = await setup(t); await s.seed();
  await s.db.exec("CREATE TRIGGER reject_scope_change BEFORE INSERT ON studio_read_changes BEGIN SELECT RAISE(ABORT, 'fixture_change_failure'); END;");
  const before = await s.snapshot();
  const key = 'create-after-change-storage-recovers';
  await expect(await s.commit('pack', 'recover-a', [newPack('recover-a')], 0, { actor: 'a', key }), 503, 'internal_error');
  assert.deepEqual(await s.snapshot(), before);
  assert.equal(await s.row('pack', 'recover-a'), null);
  await s.db.exec('DROP TRIGGER reject_scope_change');
  const first = await expect(await s.commit('pack', 'recover-a', [newPack('recover-a')], 0, { actor: 'a', key }));
  const committed = await s.snapshot();
  assert.deepEqual(await expect(await s.commit('pack', 'recover-a', [newPack('recover-a')], 0, { actor: 'a', key })), first);
  assert.deepEqual(await s.snapshot(), committed);
});

test('owned revisions retain T24 optimistic conflict behavior and create collisions never leak foreign ownership', async t => {
  const s = await setup(t); await s.seed();
  const replies = await Promise.all([
    s.commit('pack', 'pack-a', [editPack('pack-a', 'Winner one')], 1, { actor: 'a' }),
    s.commit('pack', 'pack-a', [editPack('pack-a', 'Winner two')], 1, { actor: 'a' }),
  ]);
  assert.deepEqual(replies.map(reply => reply.status).sort(), [200, 412]);
  const conflict = await expect(replies.find(reply => reply.status === 412), 412, 'revision_conflict');
  assert.equal(conflict.error.currentRevision, 2);
  assert.equal((await s.row('pack', 'pack-a')).revision, 2);
  const before = await s.snapshot();
  await expect(await s.commit('pack', 'new-with-foreign-card', [newPack('new-with-foreign-card'),
    newCard('card-b', 'new-with-foreign-card')], 0, { actor: 'a' }), 404, 'not_found');
  assert.deepEqual(await s.snapshot(), before);
});

test('Unicode name search is case insensitive within scope before paging', async t => {
  const s = await setup(t); await s.seed();
  for (const actor of ['a', 'b']) await expect(await s.commit('pack', `pack-${actor}`,
    [editPack(`pack-${actor}`, 'Éléphant')], 1, { actor }));
  await expect(await s.commit('pack', 'second-a', [operation('pack', 'second-a', 'create',
    { name: 'ÉLÉPHANT second', topicId: 'topic' })], 0, { actor: 'a' }));
  const matches = await s.pages('/studio/v1/packs?q=' + encodeURIComponent('élé') + '&limit=1');
  assert.deepEqual(ids(matches.items), ['pack-a', 'second-a']);
  assert.ok(matches.cursors.length);
  assert.equal(matches.items.some(row => row.id === 'pack-b'), false);
});

test('administrative image identifiers roundtrip without disclosing raw shared R2 keys', async t => {
  const s = await setup(t); await s.seed();
  const wire = (await expect(await s.request('/studio/v1/cards/card-a'))).item;
  assert.notEqual(wire.imageReference, imageReference);
  const before = await s.snapshot();
  await expect(await s.commit('pack', 'pack-b', [operation('card', 'card-b', 'update',
    { name: 'Stolen reference', packId: 'pack-b', imageReference: wire.imageReference, difficulty: 1 })], 1, { actor: 'b' }), 404, 'not_found');
  assert.deepEqual(await s.snapshot(), before);
  await expect(await s.commit('pack', 'pack-a', [operation('card', 'card-a', 'update',
    { name: 'Roundtrip', packId: 'pack-a', imageReference: wire.imageReference, difficulty: 2 })], 1, { actor: 'a' }));
  const updated = (await expect(await s.request('/studio/v1/cards/card-a'))).item;
  assert.equal(updated.imageReference, wire.imageReference); assert.equal(updated.difficulty, 2);
});


test('authenticated attribution rejects orphan entities and wrong typed or unattributed parents', async t => {
  const s = await setup(t); await s.seed();
  const before = await s.snapshot();
  const creator = (type, id) => s.db.prepare('INSERT INTO studio_creators VALUES (?, ?, ?, ?, ?)')
    .bind(type, id, 'a', new Date().toISOString(), 'authenticated');
  await assert.rejects(creator('pack', 'missing-entity').run(), /invalid_creator_entity/);
  // Each invalid creation rolls back both its fence and attribution.
  for (const [type, id, parent] of [['pack', 'bad-pack', 'pack-a'], ['card', 'bad-card', 'topic'],
    ['card', 'missing-parent', 'not-a-pack']]) {
    await assert.rejects(s.db.batch([
      s.db.prepare('INSERT INTO studio_entities VALUES (?, ?, ?, ?, ?, ?)')
        .bind(type, id, parent, JSON.stringify({ name: 'Invalid fixture' }), 'active', 1),
      creator(type, id),
    ]), /invalid_creator_entity/);
  }
  assert.deepEqual(await s.snapshot(), before);
});

test('concurrent Owner parent deletion cannot let a Collector resurrect descendants', async t => {
  const s = await setup(t); await s.seed();
  const key = 'collector-racing-parent-deletion';
  const [edit, deletion] = await Promise.all([
    s.commit('pack', 'pack-a', [operation('card', 'card-a', 'update',
      { name: 'Concurrent edit', packId: 'pack-a', imageReference, difficulty: 2 })], 1, { actor: 'a', key }),
    s.commit('topic', 'topic', [operation('topic', 'topic', 'softDelete')], 1),
  ]);
  // Either writer may win validation. If the edit commits first, the cascade
  // deletes its result; otherwise the edit must fail without partial writes.
  if (deletion.status === 412) {
    // A winning Pack edit changed the shared generation, not the Topic revision.
    await expect(deletion, 412, 'revision_conflict');
    await expect(await s.commit('topic', 'topic', [operation('topic', 'topic', 'softDelete')], 1));
  } else await expect(deletion);
  assert.ok([200, 404, 412].includes(edit.status), await edit.clone().text());
  if (edit.status !== 200) {
    await expect(edit, edit.status, edit.status === 404 ? 'not_found' : 'revision_conflict');
    assert.equal(await s.db.prepare('SELECT count(*) AS n FROM studio_commits WHERE actor_id=? AND idempotency_key=?')
      .bind('a', key).first('n'), 0);
  }
  assert.equal((await s.row('topic', 'topic')).state, 'deleted');
  assert.equal((await s.row('pack', 'pack-a')).state, 'deleted');
  assert.equal((await s.row('card', 'card-a')).state, 'deleted');
  await expect(await s.request('/studio/v1/cards/card-a'), 404, 'not_found');
  assert.equal(await s.db.prepare("SELECT created_by_uid FROM studio_creators WHERE resource_type='pack' AND resource_id='pack-a'").first('created_by_uid'), 'a');
});
