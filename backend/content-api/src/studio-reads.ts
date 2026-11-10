import type { Env } from './env';
import type { Principal } from './studio-auth';
import { adminImageReference } from './studio-scope';

type Kind = 'topic' | 'pack' | 'card';
type Row = {
  resource_type: Kind; id: string; parent_id: string | null; value: string | null;
  state: string; revision: number; created_by_uid: string | null; created_at: string | null;
};
type Wire = Record<string, unknown>;
type Cursor = {
  binding: string; mode: 'page' | 'resume' | 'changes'; position: string | number;
  versions?: string; high: number; expires?: number;
};
class ReadError extends Error {
  constructor(readonly status: number, readonly code: string) { super(code); }
}
const invalid = (): never => { throw new ReadError(400, 'invalid_request'); };
const expired = (): never => { throw new ReadError(409, 'cursor_expired'); };
const missing = (): never => { throw new ReadError(404, 'not_found'); };
const envelope = (value: object) => Response.json({ protocolVersion: 1, scopeVersion: 1, ...value }, {
  headers: { 'Cache-Control': 'no-store' },
});
const order = "CASE e.resource_type WHEN 'topic' THEN 0 WHEN 'pack' THEN 1 ELSE 2 END";
const columns = 'e.*, c.created_by_uid, c.created_at';
const joins = `LEFT JOIN studio_creators c ON c.resource_type = e.resource_type AND c.resource_id = e.id
  LEFT JOIN studio_entities p ON p.resource_type = 'pack' AND p.id = CASE WHEN e.resource_type = 'card' THEN e.parent_id ELSE e.id END
  LEFT JOIN studio_creators pc ON pc.resource_type = 'pack' AND pc.resource_id = p.id`;
const visible = `(e.resource_type = 'topic' OR (pc.source = 'authenticated' AND pc.created_by_uid = ?))
  AND e.state IN ('active', 'hidden') AND (e.resource_type != 'card' OR p.state IN ('active', 'hidden'))`;
const rank = (kind: Kind) => ({ topic: 0, pack: 1, card: 2 })[kind];
const key = (row: Row) => `${rank(row.resource_type)}:${row.id}`;
function id(value: string, decode = true): string {
  let decoded = value;
  if (decode) {
    try { decoded = decodeURIComponent(value); } catch { return invalid(); }
  }
  if (!decoded || /[\s\p{Cc}\p{Cs}]/u.test(decoded)) return invalid();
  return decoded;
}
async function digest(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, '0')).join('');
}
async function project(row: Row, owner: boolean): Promise<Wire> {
  const record: Wire = { resourceType: row.resource_type, id: row.id, state: row.state, revision: row.revision };
  if (row.parent_id !== null) record[row.resource_type === 'pack' ? 'topicId' : 'packId'] = row.parent_id;
  if (row.value !== null) {
    const value = JSON.parse(row.value) as Record<string, unknown>;
    record.name = value.name;
    if (row.resource_type === 'card') {
      record.imageReference = await adminImageReference(row.parent_id!, String(value.imageReference));
      record.difficulty = value.difficulty;
    }
  }
  if (owner) { record.createdByUid = row.created_by_uid; record.createdAt = row.created_at; }
  return record;
}
function b64(bytes: Uint8Array): string {
  return btoa(Array.from(bytes, b => String.fromCharCode(b)).join('')).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
async function cursorKey(hex: string): Promise<CryptoKey> {
  if (!/^[a-fA-F0-9]{64}$/.test(hex)) throw new Error('Invalid cursor key');
  const bytes = new Uint8Array(hex.match(/../g)!.map(part => parseInt(part, 16)));
  return crypto.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
}
async function seal(value: Cursor, hex: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  // Fixed-size buckets conceal counter digit lengths and foreign sequence gaps.
  // IDs can be long under the existing batch contract, so larger own-ID tokens
  // use additional buckets without disclosing any other account's metadata.
  // Numeric counters have fixed width even at a bucket boundary chosen through
  // a long own ID; foreign writes therefore cannot change ciphertext size.
  const wire = { ...value, high: String(value.high).padStart(16, '0'),
    position: typeof value.position === 'number' ? String(value.position).padStart(16, '0') : value.position };
  const plain = new TextEncoder().encode(JSON.stringify(wire));
  const padded = new Uint8Array(Math.ceil(plain.length / 2048) * 2048).fill(32);
  padded.set(plain);
  const data = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await cursorKey(hex), padded);
  const all = new Uint8Array(iv.length + data.byteLength); all.set(iv); all.set(new Uint8Array(data), iv.length);
  return b64(all);
}
async function unseal(value: string, hex: string, binding: string): Promise<Cursor> {
  try {
    if (value.length > 524288 || !/^[A-Za-z0-9_-]+$/.test(value)) return expired();
    const base = value.replace(/-/g, '+').replace(/_/g, '/');
    const bytes = Uint8Array.from(atob(base + '='.repeat((4 - base.length % 4) % 4)), c => c.charCodeAt(0));
    if (bytes.length < 29) return expired();
    const data = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12) }, await cursorKey(hex), bytes.slice(12));
    const wire = JSON.parse(new TextDecoder().decode(data)) as Record<string, unknown>;
    if (typeof wire.high !== 'string' || !/^[0-9]{16}$/.test(wire.high)) return expired();
    if (wire.mode !== 'page' && (typeof wire.position !== 'string' || !/^[0-9]{16}$/.test(wire.position))) return expired();
    const decoded = { ...wire, high: Number(wire.high),
      position: wire.mode === 'page' ? wire.position : Number(wire.position) } as Cursor;
    if (decoded.binding !== binding || !['page', 'resume', 'changes'].includes(decoded.mode)
      || !Number.isSafeInteger(decoded.high) || decoded.high < 0
      || (decoded.expires !== undefined && (!Number.isFinite(decoded.expires) || decoded.expires < Date.now()))) return expired();
    return decoded;
  } catch { return expired(); }
}
type Meta = { cursor_key: string; bootstrap_sequence: number };
function versions(rows: Record<string, unknown>[]): string {
  return JSON.stringify(rows.map(row => [row.scope_key, row.version]));
}
function common(env: Env, principal: Principal): D1PreparedStatement[] {
  return [
    env.DB.prepare('SELECT m.*, g.generation FROM studio_read_meta m CROSS JOIN studio_generation g WHERE m.id = 1 AND g.id = 1'),
    env.DB.prepare('SELECT scope_key, version FROM studio_scope_versions WHERE scope_key IN (?, ?) ORDER BY scope_key')
      .bind(principal.role === 'owner_admin' ? 'owner' : 'taxonomy', principal.role === 'owner_admin' ? 'owner' : `uid:${principal.uid}`),
    env.DB.prepare('SELECT COALESCE(MAX(sequence), 0) AS high FROM studio_read_changes'),
  ];
}

/** Canonical authenticated administrative reads. Never called by public routing. */
export async function studioRead(request: Request, env: Env, principal: Principal): Promise<Response | undefined> {
  const url = new URL(request.url);
  const path = url.pathname;
  const list = /^\/studio\/v1\/(topics|packs)$/.exec(path);
  const detail = /^\/studio\/v1\/(topics|packs|cards)\/([^/]+)$/.exec(path);
  const cards = /^\/studio\/v1\/packs\/([^/]+)\/cards$/.exec(path);
  const initial = path === '/studio/v1/sync/initial';
  const changes = path === '/studio/v1/sync/changes';
  const audit = path === '/studio/v1/audit';
  if (request.method !== 'GET' || !(list || detail || cards || initial || changes || audit)) return;
  try {
    const owner = principal.role === 'owner_admin';
    if (audit && !owner) throw new ReadError(403, 'forbidden');
    const allowed = new Set(detail ? [] : ['cursor', 'limit']);
    if (list?.[1] === 'packs') ['topicId', 'q', 'state'].forEach(field => allowed.add(field));
    if (cards) ['q', 'state'].forEach(field => allowed.add(field));
    if (list?.[1] === 'topics') allowed.add('state');
    if (audit) allowed.add('packId');
    const query: Record<string, string> = {};
    for (const [name, value] of url.searchParams) {
      if (!allowed.has(name) || name in query) return invalid();
      query[name] = value;
    }
    const limit = query.limit === undefined ? 50 : Number(query.limit);
    if ((query.limit !== undefined && !/^[1-9][0-9]*$/.test(query.limit)) || !Number.isInteger(limit) || limit > 100) return invalid();
    if (query.q !== undefined && (!query.q || query.q.trim() !== query.q || query.q.length > 100)) return invalid();
    if (query.state !== undefined && !['active', 'hidden', 'deleted', 'purged'].includes(query.state)) return invalid();
    if (!owner && ['deleted', 'purged'].includes(query.state)) throw new ReadError(403, 'forbidden');
    if (query.topicId !== undefined) query.topicId = id(query.topicId, false);
    if (audit && query.packId === undefined) return invalid();
    if (query.packId !== undefined) query.packId = id(query.packId, false);
    const filter = Object.fromEntries(Object.entries(query).filter(([k]) => k !== 'cursor').sort(([a], [b]) => a.localeCompare(b)));
    // Default and explicit limit bind identically; no request-controlled scope.
    filter.limit = String(limit);
    const entry = (JSON.parse(env.STUDIO_USERS ?? '[]') as Principal[]).find(user => user.uid === principal.uid && user.email.toLowerCase() === principal.email.toLowerCase());
    const identity = await digest(JSON.stringify([env.FIREBASE_PROJECT_ID, principal.uid, principal.role, 1, entry]));
    const bindingFor = (endpoint: string, fields: Record<string, string>) => digest(JSON.stringify([identity, endpoint, fields]));
    const binding = await bindingFor(path, filter);

    if (changes) {
      if (!query.cursor) return invalid();
      // Cursor metadata and its current fence are one D1 snapshot. Decrypt then
      // query events in a second snapshot, checking the fence there as well.
      const preliminary = await env.DB.prepare('SELECT * FROM studio_read_meta WHERE id = 1').first<Meta>();
      if (!preliminary) throw new Error('Read metadata missing');
      const cursor = await unseal(query.cursor, preliminary.cursor_key, binding);
      if (!['resume', 'changes'].includes(cursor.mode) || typeof cursor.position !== 'number'
        || !Number.isSafeInteger(cursor.position) || cursor.position < preliminary.bootstrap_sequence) return expired();
      const scope = owner ? '1' : `(ch.resource_type = 'topic' OR (ch.pack_creator_uid = ? AND pc.source = 'authenticated' AND pc.created_by_uid = ?))`;
      const params: (string | number)[] = owner ? [] : [principal.uid, principal.uid];
      const results = await env.DB.batch<Record<string, unknown>>([
        ...common(env, principal),
        env.DB.prepare(`SELECT ch.*, current.state AS current_state, current.revision AS current_revision,
          p.state AS parent_state, p.revision AS parent_revision FROM studio_read_changes ch
          LEFT JOIN studio_entities current ON current.resource_type = ch.resource_type AND current.id = ch.resource_id
          LEFT JOIN studio_entities p ON p.resource_type = 'pack' AND p.id = ch.pack_id
          LEFT JOIN studio_creators pc ON pc.resource_type = 'pack' AND pc.resource_id = ch.pack_id
          WHERE ${scope} AND ch.sequence > ? AND ch.sequence <= CASE WHEN ? = 'resume'
            THEN (SELECT COALESCE(MAX(sequence),0) FROM studio_read_changes) ELSE ? END
          ORDER BY ch.sequence LIMIT ?`).bind(...params, cursor.position, cursor.mode, cursor.high, limit + 1),
      ]);
      const meta = results[0].results[0] as Meta | undefined;
      const high = Number(results[2].results[0].high);
      if (!meta || cursor.position < meta.bootstrap_sequence || cursor.position > high || cursor.high > high || cursor.high < cursor.position) return expired();
      const windowHigh = cursor.mode === 'resume' ? high : cursor.high;
      const rows = results[3].results;
      const more = rows.length > limit;
      const selected = rows.slice(0, limit);
      const items = await Promise.all(selected.map(async row => {
        const record = JSON.parse(String(row.projection_json)) as Wire;
        const unavailable = row.current_state === undefined || row.current_state === null
          || ['deleted', 'purged'].includes(String(row.current_state))
          || (row.resource_type === 'card' && ['deleted', 'purged'].includes(String(row.parent_state)));
        if (row.kind === 'remove' || unavailable) return { kind: 'remove', resourceType: row.resource_type,
          id: row.resource_id, revision: Math.max(Number(record.revision), Number(row.current_revision ?? 0),
            row.resource_type === 'card' && ['deleted', 'purged'].includes(String(row.parent_state)) ? Number(row.parent_revision ?? 0) : 0) };
        if (!owner) { delete record.createdByUid; delete record.createdAt; }
        if (record.resourceType === 'card' && typeof record.imageReference === 'string') {
          record.imageReference = await adminImageReference(String(record.packId), record.imageReference);
        }
        return { kind: 'upsert', record };
      }));
      const nextCursor = more ? await seal({ binding, mode: 'changes', position: Number(selected.at(-1)!.sequence), high: windowHigh,
        expires: Date.now() + 15 * 60_000 }, meta.cursor_key) : null;
      const resumeCursor = more ? null : await seal({ binding, mode: 'resume', position: windowHigh, high: windowHigh }, meta.cursor_key);
      return envelope({ items, nextCursor, resumeCursor });
    }

    const where: string[] = [];
    const parameters: (string | number)[] = [];
    if (!owner) { where.push(visible); parameters.push(principal.uid); }
    if (list) { where.push('e.resource_type = ?'); parameters.push(list[1] === 'topics' ? 'topic' : 'pack'); }
    if (detail) { where.push('e.resource_type = ? AND e.id = ?'); parameters.push(detail[1].slice(0, -1), id(detail[2])); }
    if (cards) { where.push("e.resource_type = 'card' AND e.parent_id = ?"); parameters.push(id(cards[1])); }
    if (query.topicId !== undefined) { where.push('e.parent_id = ?'); parameters.push(query.topicId); }
    if (query.state !== undefined) { where.push('e.state = ?'); parameters.push(query.state); }
    else if (owner && !initial && !detail) where.push("e.state IN ('active','hidden')");

    const meta = await env.DB.prepare('SELECT * FROM studio_read_meta WHERE id = 1').first<Meta>();
    if (!meta) throw new Error('Read metadata missing');
    const cursor = query.cursor ? await unseal(query.cursor, meta.cursor_key, binding) : undefined;
    if (cursor && (cursor.mode !== 'page' || typeof cursor.position !== 'string')) return expired();
    if (cursor && !audit) {
      const position = /^(0|1|2):(.*)$/su.exec(String(cursor.position));
      if (!position) return expired();
      where.push(`(${order} > ? OR (${order} = ? AND CAST(e.id AS BLOB) > CAST(? AS BLOB)))`);
      parameters.push(Number(position[1]), Number(position[1]), position[2]);
    }
    const selects: D1PreparedStatement[] = common(env, principal);
    if (audit) {
      const after = cursor?.position ?? '';
      selects.push(env.DB.prepare(`SELECT a.* FROM studio_audit a WHERE
        ((a.resource_type = 'pack' AND a.resource_id = ?) OR (a.resource_type = 'card' AND a.resource_id IN
          (SELECT id FROM studio_entities WHERE resource_type = 'card' AND parent_id = ?)))
        AND (a.batch_id || ':' || a.resource_type || ':' || a.resource_id) > ?
        ORDER BY a.batch_id || ':' || a.resource_type || ':' || a.resource_id LIMIT ?`)
        .bind(query.packId, query.packId, after, limit + 1));
    } else selects.push(env.DB.prepare(`SELECT ${columns} FROM studio_entities e ${joins}
      ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY ${order}, CAST(e.id AS BLOB) ${query.q === undefined ? 'LIMIT ?' : ''}`)
      .bind(...parameters, ...(query.q === undefined ? [detail ? 1 : limit + 1] : [])));
    if (cards) selects.push(env.DB.prepare(`SELECT ${columns} FROM studio_entities e ${joins}
      WHERE e.resource_type = 'pack' AND e.id = ? ${owner ? '' : 'AND ' + visible}`)
      .bind(id(cards[1]), ...(!owner ? [principal.uid] : [])));
    const results = await env.DB.batch<Record<string, unknown>>(selects);
    const currentMeta = results[0].results[0] as Meta | undefined;
    const viewVersions = versions(results[1].results);
    const high = Number(results[2].results[0].high);
    if (!currentMeta) throw new Error('Read metadata missing');
    if (cursor && (cursor.versions !== viewVersions || cursor.high > high || cursor.high < currentMeta.bootstrap_sequence)) return expired();
    if (cards && results[4].results.length === 0) return missing();
    // SQLite lower() folds ASCII only. Unicode search overfetches this account's
    // SQL-authorized rows in the SAME snapshot, then matches before pagination;
    // no foreign rows are fetched or filtered in the browser. A folded-name
    // projection can replace the overfetch if authoring datasets grow large.
    const rows = query.q === undefined ? results[3].results : results[3].results.filter(row => {
      const value = row.value === null ? null : JSON.parse(String(row.value)) as { name?: string };
      return typeof value?.name === 'string' && value.name.toLowerCase().includes(query.q.toLowerCase());
    });
    if (detail) {
      if (!rows.length) return missing();
      return envelope({ item: await project(rows[0] as Row, owner) });
    }
    const more = rows.length > limit;
    const selected = rows.slice(0, limit);
    const items = audit ? selected : await Promise.all(selected.map(row => project(row as Row, owner)));
    const last = selected.at(-1);
    const position = last ? audit ? `${last.batch_id}:${last.resource_type}:${last.resource_id}` : key(last as Row) : '';
    const nextCursor = more ? await seal({ binding, mode: 'page', position, versions: viewVersions,
      high: cursor?.high ?? high, expires: Date.now() + 15 * 60_000 }, currentMeta.cursor_key) : null;
    if (initial) {
      const changesBinding = await bindingFor('/studio/v1/sync/changes', { limit: String(limit) });
      const resumeCursor = more ? null : await seal({ binding: changesBinding, mode: 'resume', position: cursor?.high ?? high,
        high: cursor?.high ?? high }, currentMeta.cursor_key);
      return envelope({ items, nextCursor, resumeCursor });
    }
    return envelope({ items, nextCursor });
  } catch (error) {
    const e = error instanceof ReadError ? error : new ReadError(503, 'internal_error');
    return Response.json({ protocolVersion: 1, error: { code: e.code,
      message: e.status === 404 ? 'Resource not found.' : e.status === 409 ? 'Restart synchronization.'
        : e.status === 400 ? 'Invalid request.' : e.status === 403 ? 'Studio access is forbidden.' : 'Studio is temporarily unavailable.',
      requestId: crypto.randomUUID(), retryable: e.status === 503, currentRevision: null } },
    { status: e.status, headers: { 'Cache-Control': 'no-store' } });
  }
}
