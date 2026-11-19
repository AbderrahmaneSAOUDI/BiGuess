import type { Env } from './env';
import { StudioError, type Principal } from './studio-auth';

type ScopeBatch = { aggregate: {resourceType: string; id: string};
  operations: {resourceType: string; id: string; action: string; value?: {topicId?: string}}[] };

export function scopeReads(env: Env, batch: ScopeBatch): D1PreparedStatement[] {
  return [
    env.DB.prepare(`SELECT e.state,c.created_by_uid,c.source FROM studio_entities e
      LEFT JOIN studio_creators c ON c.resource_type='pack' AND c.resource_id=e.id
      WHERE e.resource_type='pack' AND e.id=?`).bind(batch.aggregate.id),
    env.DB.prepare(`SELECT e.id,e.parent_id,e.state,c.created_by_uid,c.source FROM studio_entities e
      LEFT JOIN studio_creators c ON c.resource_type='pack' AND c.resource_id=e.parent_id
      WHERE e.resource_type='card' AND e.id IN (SELECT value FROM json_each(?))`)
      .bind(JSON.stringify(batch.operations.filter(o => o.resourceType === 'card').map(o => o.id))),
    env.DB.prepare(`SELECT resource_id FROM studio_legacy_records WHERE resource_type='topic' AND
      (resource_id IN (SELECT parent_id FROM studio_entities WHERE resource_type='pack' AND id=?)
       OR resource_id IN (SELECT value FROM json_each(?)))`).bind(batch.aggregate.id,
        JSON.stringify(batch.operations.filter(o=>o.resourceType==='pack').map(o=>o.value?.topicId).filter(Boolean))),
  ];
}

/** Pack creator is authority; a Card's own creator never grants access. */
export function assertBatchScope(principal: Principal, batch: ScopeBatch,
  pack: unknown[], cards: unknown[], replay = false, quarantined: unknown[] = []): void {
  if (principal.role === 'owner_admin') return;
  if (quarantined.length) throw new StudioError(404,'not_found');
  if (batch.aggregate.resourceType !== 'pack') throw new StudioError(403, 'forbidden');
  const row = pack[0] as {state: string; created_by_uid: string|null; source: string}|undefined;
  if (row ? row.source !== 'authenticated' || row.created_by_uid !== principal.uid
      || ['deleted','purged'].includes(row.state)
    : replay || !batch.operations.some(o => o.resourceType === 'pack' && o.id === batch.aggregate.id && o.action === 'create')) {
    throw new StudioError(404, 'not_found');
  }
  for (const card of cards as {parent_id: string; state: string; created_by_uid: string|null; source: string}[]) {
    if (card.parent_id !== batch.aggregate.id || card.created_by_uid !== principal.uid
      || card.source !== 'authenticated' || ['deleted','purged'].includes(card.state)) {
      throw new StudioError(404, 'not_found');
    }
  }
}

export async function checkBatchScope(env: Env, principal: Principal, batch: ScopeBatch,
  replay = false): Promise<void> {
  if (principal.role === 'owner_admin') return;
  const [pack, cards, quarantined] = await env.DB.batch(scopeReads(env,batch));
  assertBatchScope(principal,batch,pack.results,cards.results,replay,quarantined.results);
}

/** Public wire shape stays compatible; this identifier is not the R2 object key. */
export async function adminImageReference(packId: string, reference: string): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify([packId, reference]));
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  const hex = Array.from(digest, b => b.toString(16).padStart(2, '0')).join('');
  return `objects/${hex}.${reference.split('.').at(-1)}`;
}

/** No hash guessing: bytes must already have a trusted grant to this Pack. */
export async function resolvePackImage(env: Env, packId: string, reference: string): Promise<string> {
  const rows = await env.DB.prepare('SELECT object_reference FROM studio_pack_images WHERE pack_id=?')
    .bind(packId).all<{object_reference: string}>();
  for (const row of rows.results) {
    if (row.object_reference === reference || await adminImageReference(packId, row.object_reference) === reference) {
      return row.object_reference;
    }
  }
  throw new StudioError(404, 'not_found');
}

/** Append after all entity/creator writes, inside their guarded D1 batch. */
export function captureChange(env: Env, kind: string, id: string): D1PreparedStatement {
  return env.DB.prepare(`INSERT INTO studio_read_changes
    (generation,resource_type,resource_id,pack_id,pack_creator_uid,kind,projection_json)
    SELECT g.generation,e.resource_type,e.id,
      CASE WHEN e.resource_type='pack' THEN e.id WHEN e.resource_type='card' THEN e.parent_id ELSE NULL END,
      CASE WHEN e.resource_type='pack' THEN c.created_by_uid ELSE pc.created_by_uid END,
      CASE WHEN e.state IN ('deleted','purged') OR (e.resource_type='card' AND p.state IN ('deleted','purged'))
        THEN 'remove' ELSE 'upsert' END,
      json_patch(json_patch(json_object('resourceType',e.resource_type,'id',e.id,'state',e.state,
        'revision',e.revision,'createdByUid',c.created_by_uid,'createdAt',c.created_at),
        CASE WHEN e.resource_type='pack' THEN json_object('topicId',e.parent_id)
          WHEN e.resource_type='card' THEN json_object('packId',e.parent_id) ELSE '{}' END),coalesce(e.value,'{}'))
    FROM studio_entities e CROSS JOIN studio_generation g
    LEFT JOIN studio_creators c ON c.resource_type=e.resource_type AND c.resource_id=e.id
    LEFT JOIN studio_entities p ON e.resource_type='card' AND p.resource_type='pack' AND p.id=e.parent_id
    LEFT JOIN studio_creators pc ON e.resource_type='card' AND pc.resource_type='pack' AND pc.resource_id=e.parent_id
    WHERE g.id=1 AND e.resource_type=? AND e.id=?`).bind(kind,id);
}
