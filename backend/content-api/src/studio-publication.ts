import type { Env } from './env';
import { StudioError, type Principal } from './studio-auth';
import { adminImageReference, captureChange } from './studio-scope';
import { decode, hash, publish, type Bundle, type Manifest } from './publication';
import { validatePreparedImage } from './image-validation';

type Kind = 'topic' | 'pack';
interface Entity { resource_type: string; id: string; parent_id: string | null; value: string | null; state: string; revision: number }
interface Release { id: string; pack_id: string; fingerprint: string; revision: number; expected_revision: number; actor_uid: string; actor_role: 'owner_admin' | 'collector'; status: string }
class ReviewError extends StudioError {
  constructor(status: number, code: string, readonly detail: string) { super(status, code); }
}
const fail = (message: string): never => { throw new ReviewError(422, 'validation_failed', message); };
const json = (value: unknown, status = 200) => Response.json(value, { status, headers: { 'Cache-Control': 'no-store' } });
const live = (e?: Entity) => !!e && ['active', 'hidden'].includes(e.state);
const product = (e: Entity) => ({ id: e.id, ...JSON.parse(e.value!) });
const canonical = (value: unknown): string => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical((value as Record<string, unknown>)[k])}`).join(',')}}`;
  return JSON.stringify(value);
};
const subject = (card: Record<string, unknown>) => canonical([card.id, card.imageReference]);

/** One database snapshot plus bounded sequential byte verification. Every write
 * subsequently fences this generation; review cannot approve a racing edit. */
export async function review(env: Env, principal: Principal, kind: Kind, id: string) {
  const reads = await env.DB.batch<Record<string, unknown>>([
    env.DB.prepare('SELECT generation FROM studio_generation WHERE id=1'),
    env.DB.prepare(`SELECT * FROM studio_entities WHERE (resource_type=? AND id=?)
      OR (?='pack' AND resource_type='topic' AND id=(SELECT parent_id FROM studio_entities WHERE resource_type='pack' AND id=?))
      OR (?='pack' AND resource_type='card' AND parent_id=? AND id IN (
        SELECT id FROM studio_entities WHERE resource_type='card' AND parent_id=? AND state='active' ORDER BY id LIMIT 1001))
      ORDER BY resource_type,id`).bind(kind,id,kind,id,kind,id,id),
    env.DB.prepare("SELECT * FROM studio_creators WHERE resource_type='pack' AND resource_id=?").bind(id),
    env.DB.prepare(`SELECT published,revision FROM ${kind === 'pack' ? 'catalog_packs' : 'catalog_topics'} WHERE id=?`).bind(id),
    env.DB.prepare('SELECT revision FROM publication_heads WHERE pack_id=?').bind(id),
    env.DB.prepare('SELECT subject FROM studio_rights_approvals WHERE pack_id=?').bind(id),
    env.DB.prepare('SELECT fingerprint FROM studio_publication_approvals WHERE resource_type=? AND resource_id=?').bind(kind,id),
    env.DB.prepare("SELECT * FROM studio_release_requests WHERE pack_id=? AND status='pending_operator'").bind(id),
    env.DB.prepare('SELECT object_reference FROM studio_pack_images WHERE pack_id=?').bind(id),
    env.DB.prepare('SELECT resume_published FROM publication_suppression WHERE pack_id=?').bind(id),
    env.DB.prepare("SELECT published FROM catalog_topics WHERE id=(SELECT parent_id FROM studio_entities WHERE resource_type='pack' AND id=?)").bind(id),
  ]);
  const entities = reads[1].results as unknown as Entity[];
  const entity = entities.find(e => e.resource_type === kind && e.id === id);
  const creator = reads[2].results[0] as { source: string; created_by_uid: string } | undefined;
  if (!entity || !live(entity) || principal.role !== 'owner_admin' && (kind !== 'pack'
    || creator?.source !== 'authenticated' || creator.created_by_uid !== principal.uid)) throw new StudioError(404, 'not_found');
  const topic = kind === 'topic' ? entity : entities.find(e => e.resource_type === 'topic');
  const cards = entities.filter(e => e.resource_type === 'card' && e.state === 'active').map(product);
  const fingerprint = await hash(new TextEncoder().encode(canonical({ entity, topic, cards })));
  const errors: string[] = [];
  if (!live(topic)) errors.push('Parent Topic is unavailable.');
  const images = new Set(reads[8].results.map(r => r.object_reference));
  const verified = new Set<string>();
  if (kind === 'pack') {
    if (cards.length < 2) errors.push('At least two eligible Cards are required.');
    if (cards.length > 1000) errors.push('Review supports at most 1000 eligible Cards.');
    let totalBytes = 0;
    for (const card of cards.slice(0, 1000)) {
      if (typeof card.name !== 'string' || !card.name.trim() || ![1,2,3].includes(card.difficulty as number)) errors.push(`Invalid Card: ${card.id}`);
      const reference = card.imageReference as string;
      if (!images.has(reference) || !/^objects\/[a-f0-9]{64}\.(png|webp)$/.test(reference)) { errors.push(`Unverified image: ${card.id}`); continue; }
      if (verified.has(reference)) continue;
      try {
        const object = await env.CONTENT.get(reference);
        if (!object || object.size > 5242880 || (totalBytes += object.size) > 104857600) throw new Error('image_budget');
        const bytes = new Uint8Array(await object.arrayBuffer());
        const type = reference.endsWith('.png') ? 'image/png' : 'image/webp';
        if (object.httpMetadata?.contentType !== type || await hash(bytes) !== reference.slice(8,72)) throw new Error('image_hash');
        await validatePreparedImage(bytes, type);
        verified.add(reference);
      } catch { errors.push(`Unverified image: ${card.id}`); }
    }
  }
  const rights = new Set(reads[5].results.map(r => r.subject));
  const rightsApproved = kind === 'topic' || rights.has('pack') && cards.every(c => rights.has(subject(c)));
  if (!rightsApproved) errors.push('Owner rights approval is required for the Pack and every Card image.');
  const catalog = reads[3].results[0] as { published: number; revision: number } | undefined;
  const head = reads[4].results[0] as { revision: number } | undefined;
  const initialApproved = reads[6].results.some(r => r.fingerprint === fingerprint);
  const pending = (reads[7].results as unknown as Release[]).find(r => r.fingerprint === fingerprint);
  return { generation: reads[0].results[0].generation as number, entity, topic, cards,
    rightsApproved, initialApproved, head: kind === 'pack' ? head?.revision ?? 0 : catalog?.revision ?? 0,
    resume: reads[9].results[0]?.resume_published === 1, topicPublished: reads[10].results[0]?.published === 1,
    preview: { protocolVersion: 1, resourceType: kind, id, revision: entity.revision, fingerprint,
      state: entity.state, published: catalog?.published === 1, publishedRevision: kind === 'topic' ? catalog?.revision ?? null : head?.revision ?? null,
      eligibleCardCount: cards.length, cards: await Promise.all(cards.map(async c => ({ ...c,
        imageReference: await adminImageReference(id, c.imageReference as string) }))), errors,
      rightsApproved, initialApproved, pendingRequestId: pending?.id ?? null } };
}
type Review = Awaited<ReturnType<typeof review>>;
const event = (env: Env, principal: Principal, r: Review, action: string) => env.DB.prepare(
  'INSERT INTO studio_publication_events VALUES (?,?,?,?,?,?,?,?)').bind(crypto.randomUUID(),r.entity.resource_type,r.entity.id,
    action,principal.uid,r.preview.fingerprint,r.generation,new Date().toISOString());

async function body(request: Request): Promise<{ revision: number; fingerprint: string; evidence?: string }> {
  if (Number(request.headers.get('Content-Length') ?? 0) > 8192) throw new StudioError(400,'invalid_request');
  const reader = request.body?.getReader();
  if (!reader) throw new StudioError(400,'invalid_request');
  const buffer = new Uint8Array(8192); let size = 0;
  try {
    while (true) {
      const part = await reader.read(); if (part.done) break;
      if (size + part.value.length > buffer.length) { void reader.cancel(); throw new StudioError(400,'invalid_request'); }
      buffer.set(part.value,size); size += part.value.length;
    }
  } finally { reader.releaseLock(); }
  const text = new TextDecoder().decode(buffer.subarray(0,size));
  let value;
  try { value = JSON.parse(text); } catch { throw new StudioError(400,'invalid_request'); }
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || Object.keys(value).some(k => !['revision','fingerprint','evidence'].includes(k))
    || !Number.isSafeInteger(value.revision) || typeof value.fingerprint !== 'string'
    || !/^[a-f0-9]{64}$/.test(value.fingerprint)
    || value.evidence !== undefined && (typeof value.evidence !== 'string' || !value.evidence.trim() || value.evidence.length > 2000)) throw new StudioError(400,'invalid_request');
  return value;
}
export async function studioPublication(request: Request, env: Env, principal: Principal, path: string): Promise<Response | undefined> {
  const match = /^\/studio\/v1\/(topics|packs)\/([^/]+)\/publication(?:\/(validate|approve-rights|approve|publish|unpublish))?$/.exec(path);
  if (!match) return;
  try {
    if (new URL(request.url).search || (match[3] ? request.method !== 'POST' : request.method !== 'GET')) throw new StudioError(400,'invalid_request');
    let id: string; try { id = decodeURIComponent(match[2]); } catch { throw new StudioError(400,'invalid_request'); }
    const kind: Kind = match[1] === 'topics' ? 'topic' : 'pack';
    const action = match[3];
    const r = await review(env,principal,kind,id);
    if (!action) return json(r.preview);
    if (principal.role !== 'owner_admin' && (kind === 'topic' || ['approve-rights','approve'].includes(action))) throw new StudioError(403,'forbidden');
    const input = await body(request);
    if (input.revision !== r.entity.revision || input.fingerprint !== r.preview.fingerprint) throw new ReviewError(412,'revision_conflict','Content changed. Refresh the publication review.');
    if (action === 'validate') return json(r.preview);
    const writes = [event(env,principal,r,action)];
    let status = 'reviewed'; let requestId: string | undefined;
    if (action === 'approve-rights') {
      if (kind !== 'pack' || !input.evidence) fail('A private rights evidence reference is required.');
      if (r.preview.errors.some(e => !e.startsWith('Owner rights'))) fail('Correct the content and images before approving rights.');
      for (const key of ['pack', ...r.cards.map(subject)]) writes.push(env.DB.prepare('INSERT OR IGNORE INTO studio_rights_approvals VALUES (?,?,?,?,?)')
        .bind(id,key,input.evidence!,principal.uid,new Date().toISOString()));
    } else if (action === 'approve') {
      if (r.preview.errors.length) fail(r.preview.errors.join(' '));
      writes.push(env.DB.prepare('INSERT OR IGNORE INTO studio_publication_approvals VALUES (?,?,?,?,?)')
        .bind(kind,id,r.preview.fingerprint,principal.uid,new Date().toISOString()));
    } else if (action === 'publish') {
      if (r.preview.errors.length) fail(r.preview.errors.join(' '));
      if (kind === 'topic') {
        if (!r.initialApproved) fail('Owner approval of this Topic review is required.');
        writes.push(env.DB.prepare(`INSERT INTO catalog_topics(id,name,revision,published) VALUES (?,?,?,1)
          ON CONFLICT(id) DO UPDATE SET name=excluded.name,revision=excluded.revision,published=1 WHERE deleted=0`)
          .bind(id,JSON.parse(r.entity.value!).name,r.entity.revision));
        writes.push(env.DB.prepare("UPDATE studio_entities SET state='active' WHERE resource_type='topic' AND id=?").bind(id),captureChange(env,kind,id));
        status = 'published';
      } else {
        const routine = r.head > 0 && r.entity.state === 'active' && (r.preview.published || r.resume);
        if (principal.role !== 'owner_admin' && !routine) throw new StudioError(403,'forbidden');
        if (!routine && !r.initialApproved) fail('Owner approval of this initial or hidden Pack review is required.');
        if (r.entity.revision <= r.head) fail('There is no newer committed Pack revision to release.');
        requestId = r.preview.pendingRequestId ?? crypto.randomUUID();
        writes.push(env.DB.prepare("INSERT OR IGNORE INTO studio_release_requests VALUES (?,?,?,?,?,?,?,?, 'pending_operator')")
          .bind(requestId,id,r.preview.fingerprint,r.entity.revision,r.head,principal.uid,principal.role,new Date().toISOString()));
        status = 'pending_operator';
      }
    } else if (action === 'unpublish') {
      const table = kind === 'pack' ? 'catalog_packs' : 'catalog_topics';
      writes.push(env.DB.prepare(`UPDATE ${table} SET published=0 WHERE id=?`).bind(id));
      writes.push(env.DB.prepare("UPDATE studio_entities SET state='hidden',revision=revision+1 WHERE resource_type=? AND id=?").bind(kind,id));
      if (kind === 'pack') writes.push(env.DB.prepare('DELETE FROM publication_suppression WHERE pack_id=?').bind(id));
      writes.push(captureChange(env,kind,id)); status = 'unpublished';
    }
    await env.DB.batch(writes);
    return json({ ...(await review(env,principal,kind,id)).preview, status, ...(requestId ? { requestId } : {}) });
  } catch (error) { return reviewFailure(error); }
}
export function reviewFailure(error: unknown): Response {
  const conflict = String(error).includes('review_conflict') || String(error).includes('publication_conflict');
  const e = error instanceof StudioError ? error : new ReviewError(conflict ? 412 : 503,conflict ? 'revision_conflict' : 'internal_error',
    conflict ? 'Content changed. Refresh and retry.' : 'Publication storage is unavailable.');
  return json({ protocolVersion: 1, error: { code: e.code, message: e instanceof ReviewError ? e.detail : 'Publication access is unavailable.',
    requestId: crypto.randomUUID(), retryable: e.status === 503, currentRevision: null } },e.status);
}

/** Only imported by the separately provisioned privileged operator entrypoint.
 * The signature is necessary but insufficient: exact authoring/review/rights
 * and current server allowlist authority are checked again before activation. */
export async function releaseReviewed(env: Env, requestId: string, bundle: Bundle): Promise<void> {
  const saved = await env.DB.prepare('SELECT * FROM studio_release_requests WHERE id=?').bind(requestId).first<Release>();
  if (!saved || saved.status !== 'pending_operator') throw new StudioError(409,'release_conflict');
  let users: Principal[];
  try { users = JSON.parse(env.STUDIO_USERS ?? 'null'); } catch { throw new StudioError(503,'auth_unavailable'); }
  if (!Array.isArray(users) || !users.every(p => p && typeof p.uid === 'string' && typeof p.email === 'string'
    && (p.role === 'owner_admin' || p.role === 'collector'))) throw new StudioError(503,'auth_unavailable');
  const matches = users.filter(p => p.uid === saved.actor_uid && p.role === saved.actor_role);
  if (matches.length !== 1) throw new StudioError(403,'forbidden');
  const r = await review(env,matches[0],'pack',saved.pack_id);
  if (r.preview.errors.length || r.preview.fingerprint !== saved.fingerprint || r.entity.revision !== saved.revision
    || r.head !== saved.expected_revision) fail('The queued review is stale or no longer eligible.');
  const routine = r.head > 0 && r.entity.state === 'active' && (r.preview.published || r.resume);
  if (!routine && (!r.initialApproved || saved.actor_role !== 'owner_admin')) throw new StudioError(403,'forbidden');
  const s = bundle.receipt.statement;
  const manifest = JSON.parse(new TextDecoder().decode(decode(bundle.manifest))) as Manifest;
  if (s.packId !== saved.pack_id || s.revision !== saved.revision || s.topicId !== r.topic?.id
    || manifest.pack.name !== JSON.parse(r.entity.value!).name || manifest.topic.name !== JSON.parse(r.topic!.value!).name
    || canonical(manifest.cards.map(c => ({...c})).sort((a,b) => a.id < b.id ? -1 : 1)) !== canonical(r.cards.map(c => ({...c})).sort((a,b) => String(a.id) < String(b.id) ? -1 : 1))) fail('Signed artifact differs from the reviewed content.');
  // Topic visibility is an independent Owner decision. T22 fixture defaults
  // must not inadvertently publish a draft Topic during a Pack activation.
  await publish(env,bundle,saved.expected_revision,{
    before: [env.DB.prepare('INSERT INTO studio_release_guards VALUES (?,?)').bind(saved.id,r.generation)],
    after: [env.DB.prepare("UPDATE studio_release_requests SET status='released' WHERE id=?").bind(saved.id),
      env.DB.prepare('UPDATE catalog_packs SET published=1 WHERE id=? AND deleted=0').bind(saved.pack_id),
      env.DB.prepare("UPDATE studio_entities SET state='active' WHERE resource_type='pack' AND id=?").bind(saved.pack_id),
      env.DB.prepare('UPDATE catalog_topics SET published=? WHERE id=?').bind(Number(r.topicPublished),s.topicId),
      captureChange(env,'pack',saved.pack_id)],
  });
}
