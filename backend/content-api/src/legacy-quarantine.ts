import type { Env } from './env';

/** A T38 import cannot become publication-eligible through generic approvals.
 * Any future clearance needs a separate reviewed transition; there is no such
 * transition in this ticket. The immutable marker also survives rollback. */
export async function isLegacyQuarantined(env: Env, topicId?: string, packId?: string): Promise<boolean> {
  const row = await env.DB.prepare(`SELECT 1 AS quarantined FROM studio_legacy_records
    WHERE (resource_type='topic' AND resource_id=?) OR (resource_type='pack' AND resource_id=?) LIMIT 1`)
    .bind(topicId ?? '', packId ?? '').first();
  return row !== null;
}
