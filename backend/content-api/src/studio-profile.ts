import type { Env } from './env';
import { defaultSuperAdminEmail, type Principal, type Role } from './studio-auth';

type Counts = {
  totalOperations: number; topicsCreated: number; topicsRemoved: number;
  packsCreated: number; packsRemoved: number; cardsAdded: number; cardsRemoved: number;
  edits: number; hides: number; restores: number; permanentDeletes: number; activations: number;
};
type Aggregate = { actor_id: string; resource_type: string; action: string; count: number };
type Audit = { sequence: number; batch_id: string; actor_id: string; actor_role: Role;
  resource_type: string; resource_id: string; action: string; revision: number; committed_at: string };
type Cursor = { binding: string; high: string; before: string; asOf: string; expires: number };
class ProfileError extends Error {
  constructor(readonly status: number, readonly code: string) { super(code); }
}
const actions = "'create','update','hide','activate','softDelete','restore','permanentDelete'";
const zero = (): Counts => ({ totalOperations: 0, topicsCreated: 0, topicsRemoved: 0,
  packsCreated: 0, packsRemoved: 0, cardsAdded: 0, cardsRemoved: 0,
  edits: 0, hides: 0, restores: 0, permanentDeletes: 0, activations: 0 });
const expired = (): never => { throw new ProfileError(409, 'cursor_expired'); };
const invalid = (): never => { throw new ProfileError(400, 'invalid_request'); };
const countFields: Record<string, keyof Counts> = {
  'topic:create': 'topicsCreated', 'topic:softDelete': 'topicsRemoved',
  'pack:create': 'packsCreated', 'pack:softDelete': 'packsRemoved',
  'card:create': 'cardsAdded', 'card:softDelete': 'cardsRemoved',
};
function count(rows: Aggregate[]): Counts {
  const result = zero();
  const byAction: Record<string, keyof Counts> = { update: 'edits', hide: 'hides', restore: 'restores',
    permanentDelete: 'permanentDeletes', activate: 'activations' };
  for (const row of rows) {
    result.totalOperations += row.count;
    const field = countFields[`${row.resource_type}:${row.action}`] ?? byAction[row.action];
    if (field) result[field] += row.count;
  }
  return result;
}
async function digest(value: unknown): Promise<string> {
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(value)));
  return Array.from(new Uint8Array(hash), b => b.toString(16).padStart(2, '0')).join('');
}
async function key(hex: string): Promise<CryptoKey> {
  if (!/^[a-fA-F0-9]{64}$/.test(hex)) throw new Error('Invalid profile cursor key');
  return crypto.subtle.importKey('raw', Uint8Array.from(hex.match(/../g)!, value => parseInt(value, 16)),
    'AES-GCM', false, ['encrypt', 'decrypt']);
}
async function seal(value: Cursor, hex: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  const padded = new Uint8Array(Math.ceil(bytes.length / 2048) * 2048).fill(32);
  padded.set(bytes);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await key(hex), padded));
  const combined = new Uint8Array(iv.length + cipher.length);
  combined.set(iv); combined.set(cipher, iv.length);
  return btoa(Array.from(combined, b => String.fromCharCode(b)).join(''))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
async function unseal(value: string, hex: string, binding: string): Promise<Cursor> {
  try {
    if (value.length > 8192 || !/^[A-Za-z0-9_-]+$/.test(value)) return expired();
    const base = value.replace(/-/g, '+').replace(/_/g, '/');
    const bytes = Uint8Array.from(atob(base + '='.repeat((4 - base.length % 4) % 4)), b => b.charCodeAt(0));
    const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12) },
      await key(hex), bytes.slice(12));
    const cursor = JSON.parse(new TextDecoder().decode(plain)) as Cursor;
    if (cursor.binding !== binding || !/^[0-9]{16}$/.test(cursor.high)
      || !/^[0-9]{16}$/.test(cursor.before) || !Number.isSafeInteger(Number(cursor.high))
      || !Number.isSafeInteger(Number(cursor.before)) || Number(cursor.before) < 1
      || Number(cursor.before) > Number(cursor.high) || typeof cursor.asOf !== 'string'
      || !Number.isFinite(Date.parse(cursor.asOf)) || !Number.isFinite(cursor.expires)
      || cursor.expires < Date.now()) return expired();
    return cursor;
  } catch { return expired(); }
}

/** Authenticated, actor-scoped audit projections. Never use current entity state
 * or a client counter to decide historical contribution credit. */
export async function studioProfile(request: Request, env: Env, principal: Principal,
  canonicalPath: string): Promise<Response | undefined> {
  if (request.method !== 'GET' || canonicalPath !== '/studio/v1/profile') return;
  try {
    const query = new Map<string, string>();
    for (const [name, value] of new URL(request.url).searchParams) {
      if (!['cursor', 'limit', 'contributorUid'].includes(name) || query.has(name)) return invalid();
      query.set(name, value);
    }
    const owner = principal.role === 'owner_admin';
    if (!owner && query.has('contributorUid')) throw new ProfileError(403, 'forbidden');
    const requested = query.get('contributorUid');
    if (requested !== undefined && (!requested || requested.length > 128)) return invalid();
    const contributorUid = owner ? requested ?? null : principal.uid;
    const rawLimit = query.get('limit') ?? '50';
    if (!/^[1-9][0-9]*$/.test(rawLimit) || Number(rawLimit) > 100) return invalid();
    const limit = Number(rawLimit);
    const roster = JSON.parse(env.STUDIO_USERS ?? '[]') as Principal[];
    // Collector cursors bind only their authorization entry, never expose a
    // foreign counter or expire merely because another contributor edits.
    const authorization = owner ? roster : roster.filter(user => user.uid === principal.uid);
    const binding = await digest([env.FIREBASE_PROJECT_ID, principal, authorization,
      owner ? env.STUDIO_SUPER_ADMIN_UID ?? null : env.STUDIO_SUPER_ADMIN_UID === principal.uid,
      contributorUid, limit, 'profile-v1']);
    const preliminary = await env.DB.prepare('SELECT cursor_key FROM studio_read_meta WHERE id=1')
      .first<{ cursor_key: string }>();
    if (!preliminary) throw new Error('Profile metadata unavailable');
    const token = query.get('cursor');
    if (token === '') return expired();
    const cursor = token ? await unseal(token, preliminary.cursor_key, binding) : undefined;
    const highExpression = cursor ? '?' : '(SELECT COALESCE(MAX(rowid),0) FROM studio_audit)';
    const highParameters = cursor ? [Number(cursor.high)] : [];
    const actorClause = contributorUid === null ? '' : ' AND actor_id=?';
    const actorParameters = contributorUid === null ? [] : [contributorUid];
    // The counts, page and high watermark share one D1 snapshot. Continuations
    // freeze that watermark; newer validated operations appear after Refresh.
    const results = await env.DB.batch([
      env.DB.prepare('SELECT cursor_key,(SELECT COALESCE(MAX(rowid),0) FROM studio_audit) AS high FROM studio_read_meta WHERE id=1'),
      env.DB.prepare(`SELECT actor_id,resource_type,action,COUNT(*) AS count FROM studio_audit
        WHERE rowid<=${highExpression} AND resource_type IN ('topic','pack','card') AND action IN (${actions})
        ${owner ? '' : 'AND actor_id=?'} GROUP BY actor_id,resource_type,action`)
        .bind(...highParameters, ...(!owner ? [principal.uid] : [])),
      env.DB.prepare(`SELECT rowid AS sequence,* FROM studio_audit WHERE rowid<=${highExpression}
        AND resource_type IN ('topic','pack','card') AND action IN (${actions}) ${actorClause}
        ${cursor ? 'AND rowid<?' : ''} ORDER BY rowid DESC LIMIT ?`)
        .bind(...highParameters, ...actorParameters, ...(cursor ? [Number(cursor.before)] : []), limit + 1),
    ]);
    const meta = results[0].results[0] as { cursor_key: string; high: number } | undefined;
    if (!meta || meta.cursor_key !== preliminary.cursor_key) return expired();
    if (cursor && Number(cursor.high) > meta.high) return expired();
    const high = cursor ? Number(cursor.high) : meta.high;
    const asOf = cursor?.asOf ?? new Date().toISOString();
    const grouped = results[1].results as Aggregate[];
    const counts = count(grouped.filter(row => contributorUid === null || row.actor_id === contributorUid));
    const contributors: { uid: string; email: string | null; role: Role | null; counts: Counts }[] = [];
    if (owner) {
      const identities = new Map<string, { email: string | null; role: Role | null }>();
      for (const user of roster) identities.set(user.uid, { email: user.email.toLowerCase(), role: user.role });
      if (env.FIREBASE_PROJECT_ID === 'biguess-firebase' && env.STUDIO_SUPER_ADMIN_UID) {
        identities.set(env.STUDIO_SUPER_ADMIN_UID, { email: defaultSuperAdminEmail, role: 'owner_admin' });
      }
      identities.set(principal.uid, { email: principal.email, role: principal.role });
      for (const row of grouped) if (!identities.has(row.actor_id)) identities.set(row.actor_id, { email: null, role: null });
      for (const [uid, identity] of identities) contributors.push({ uid, ...identity,
        counts: count(grouped.filter(row => row.actor_id === uid)) });
      contributors.sort((a, b) => a.uid < b.uid ? -1 : a.uid > b.uid ? 1 : 0);
    }
    const rows = results[2].results as Audit[];
    const page = rows.slice(0, limit);
    const nextCursor = rows.length > limit ? await seal({ binding,
      high: String(high).padStart(16, '0'), before: String(page.at(-1)!.sequence).padStart(16, '0'),
      asOf, expires: cursor?.expires ?? Date.now() + 15 * 60_000 }, meta.cursor_key) : null;
    return Response.json({ protocolVersion: 1, scopeVersion: 1, principal, contributorUid: owner ? contributorUid : null,
      counts, contributors, activity: page.map(row => ({ batchId: row.batch_id,
        actorId: row.actor_id, actorRole: row.actor_role, resourceType: row.resource_type,
        resourceId: row.resource_id, action: row.action, revision: row.revision, committedAt: row.committed_at })),
      nextCursor, asOf }, { headers: { 'Cache-Control': 'no-store' } });
  } catch (error) {
    const e = error instanceof ProfileError ? error : new ProfileError(503, 'internal_error');
    return Response.json({ protocolVersion: 1, error: { code: e.code,
      message: e.status === 403 ? 'Studio access is forbidden.' : e.status === 409 ? 'Refresh this profile.'
        : e.status === 400 ? 'Invalid request.' : 'Profile statistics are temporarily unavailable.',
      requestId: crypto.randomUUID(), retryable: e.status === 503, currentRevision: null } },
    { status: e.status, headers: { 'Cache-Control': 'no-store' } });
  }
}
