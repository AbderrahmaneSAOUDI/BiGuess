import type { Env } from './env';
import { StudioError, type Principal } from './studio-auth';
import { adminImageReference } from './studio-scope';
import { hash, immutable } from './publication';
import { ImageValidationError, validatePreparedImage } from './image-validation';

const MAX_BYTES = 5 * 1024 * 1024;
const DAY = 86400;
const LEASE = 300;
let activeTransfers = 0;
const now = () => Math.floor(Date.now() / 1000);
class UploadError extends Error {
  constructor(readonly status: number, readonly code: string, message: string,
    readonly revision: number | null = null) { super(message); }
}
interface Upload {
  pack_id: string; object_reference: string; staging_key: string | null;
  actor_uid: string; byte_length: number; content_type: string; width: number; height: number;
  state: 'reserved' | 'ready' | 'attached' | 'deleting'; lease_token: string; expires_at: number;
  canonical_reserved: number;
}
const response = (body: unknown, status = 200) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
async function pack(env: Env, principal: Principal, id: string, revision: number): Promise<void> {
  const row = await env.DB.prepare(`SELECT p.revision,p.state,t.state AS topic_state,c.created_by_uid,c.source
    FROM studio_entities p LEFT JOIN studio_entities t ON t.resource_type='topic' AND t.id=p.parent_id
    LEFT JOIN studio_creators c ON c.resource_type='pack' AND c.resource_id=p.id
    WHERE p.resource_type='pack' AND p.id=?`).bind(id)
    .first<{revision: number; state: string; topic_state: string | null; created_by_uid: string | null; source: string | null}>();
  if (!row || principal.role !== 'owner_admin' && (row.source !== 'authenticated' || row.created_by_uid !== principal.uid)
    || !['active', 'hidden'].includes(row.state)) throw new StudioError(404, 'not_found');
  if (!row.topic_state || !['active', 'hidden'].includes(row.topic_state)) throw new UploadError(422, 'validation_failed', 'The Pack parent is unavailable.');
  if (row.revision !== revision) throw new UploadError(412, 'revision_conflict', 'Refresh the Pack before uploading.', row.revision);
}
async function readBody(request: Request): Promise<Uint8Array> {
  const length = request.headers.get('Content-Length');
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > MAX_BYTES)) throw new UploadError(413, 'image_too_large', 'Prepared images must be at most 5 MiB.');
  const reader = request.body?.getReader();
  if (!reader) throw new UploadError(400, 'invalid_request', 'A prepared image body is required.');
  const buffer = new Uint8Array(MAX_BYTES); let size = 0;
  const deadline = Date.now() + 30000;
  try {
    while (true) {
      let timer: ReturnType<typeof setTimeout> | null = null;
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new UploadError(408, 'upload_interrupted', 'Image transfer timed out. Retry the same image.');
      const result = await Promise.race([reader.read(), new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new UploadError(408, 'upload_interrupted', 'Image transfer timed out. Retry the same image.')), remaining);
      })]).finally(() => clearTimeout(timer));
      if (result.done) break;
      if (result.value.length > MAX_BYTES - size) throw new UploadError(413, 'image_too_large', 'Prepared images must be at most 5 MiB.');
      buffer.set(result.value, size); size += result.value.length;
    }
  } catch (error) {
    void reader.cancel().catch(() => {});
    if (error instanceof UploadError) throw error;
    throw new UploadError(400, 'upload_interrupted', 'Image transfer was interrupted. Retry the same image.');
  } finally { reader.releaseLock(); }
  if (!size || length !== null && Number(length) !== size) throw new UploadError(400, 'upload_interrupted', 'The image body is incomplete.');
  return buffer.slice(0, size);
}
async function receipt(id: string, reference: string, digest: string, type: string, length: number, dimensions: {width: number; height: number}) {
  return { protocolVersion: 1, imageIngestionVersion: 1, packId: id,
    imageReference: await adminImageReference(id, reference), sha256: digest,
    byteLength: length, contentType: type, ...dimensions };
}

/** Authenticated, normalized-image staging only; no Card or public projection is changed. */
export async function ingestImage(request: Request, env: Env, principal: Principal, id: string): Promise<Response> {
  let acquired = false;
  try {
    if (!id || /[\s\p{Cc}\p{Cs}]/u.test(id) || new URL(request.url).search) throw new UploadError(400, 'invalid_request', 'Invalid Pack image route.');
    // Ownership must be checked even before reporting missing/malformed headers.
    const match = /^"rev-([1-9][0-9]*)"$/.exec(request.headers.get('If-Match') ?? '');
    const revision = match ? Number(match[1]) : 0;
    await pack(env, principal, id, revision || -1).catch(error => {
      if (error instanceof UploadError && error.status === 412 && !revision) return;
      throw error;
    });
    if (!match || !Number.isSafeInteger(revision) || request.headers.has('If-None-Match')) throw new UploadError(428, 'precondition_required', 'Send the current Pack revision in If-Match.');
    const type = request.headers.get('Content-Type') ?? '';
    const digest = request.headers.get('X-Content-SHA256') ?? '';
    if (!['image/png', 'image/webp'].includes(type) || !/^[a-f0-9]{64}$/.test(digest)) throw new UploadError(422, 'validation_failed', 'Send normalized PNG/WebP bytes and their SHA-256.');
    // This is an isolate memory guard, not a distributed rate-limit guarantee.
    // Scope/header checks precede it, and no image body is retained when full.
    if (activeTransfers >= 2) throw new UploadError(429, 'rate_limited', 'Two image transfers are already active. Retry when they finish.');
    activeTransfers++; acquired = true;
    const bytes = await readBody(request);
    if (await hash(bytes) !== digest) throw new UploadError(422, 'validation_failed', 'Image bytes do not match the declared SHA-256.');
    const dimensions = await validatePreparedImage(bytes, type);
    const reference = `objects/${digest}.${type === 'image/png' ? 'png' : 'webp'}`;
    // Revalidate parent/revision after untrusted transfer and decode.
    await pack(env, principal, id, revision);
    const existing = await env.DB.prepare('SELECT * FROM studio_image_uploads WHERE pack_id=? AND object_reference=?')
      .bind(id, reference).first<Upload>();
    if (existing) {
      if (!['ready', 'attached'].includes(existing.state)) throw new UploadError(409, 'upload_in_progress', 'Image transfer is pending cleanup. Retry shortly.');
      const object = await env.CONTENT.head(existing.state === 'attached' ? reference : existing.staging_key ?? reference);
      if (!object || object.size !== bytes.length || object.httpMetadata?.contentType !== type) throw new UploadError(503, 'storage_unavailable', 'The staged image is unavailable. Retry after cleanup.');
      const renewed = await env.DB.prepare(`UPDATE studio_image_uploads SET expires_at=?,pack_revision=?,request_uid=?,request_role=?
        WHERE pack_id=? AND object_reference=? AND lease_token=? AND state IN ('ready','attached')
        AND EXISTS (SELECT 1 FROM studio_entities p JOIN studio_entities t ON t.resource_type='topic' AND t.id=p.parent_id
          JOIN studio_creators c ON c.resource_type='pack' AND c.resource_id=p.id
          WHERE p.resource_type='pack' AND p.id=? AND p.revision=? AND p.state IN ('active','hidden') AND t.state IN ('active','hidden')
          AND (?='owner_admin' OR (c.source='authenticated' AND c.created_by_uid=?)))`)
        .bind(now() + DAY, revision, principal.uid, principal.role, id, reference, existing.lease_token,
          id, revision, principal.role, principal.uid).run();
      if (renewed.meta.changes !== 1) {
        await pack(env, principal, id, revision);
        throw new UploadError(409, 'upload_in_progress', 'The staged image expired during retry. Retry after cleanup.');
      }
      return response(await receipt(id, reference, digest, type, bytes.length, dimensions));
    }
    const lease = crypto.randomUUID(), staging = `studio-staging/v1/${crypto.randomUUID()}`;
    const time = now();
    try {
      await env.DB.prepare(`INSERT INTO studio_image_uploads
        (pack_id,object_reference,actor_uid,request_uid,request_role,pack_revision,staging_key,byte_length,content_type,width,height,state,lease_token,lease_expires_at,expires_at,created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,'reserved',?,?,?,?)`)
        .bind(id, reference, principal.uid, principal.uid, principal.role, revision, staging, bytes.length, type,
          dimensions.width, dimensions.height, lease, time + LEASE, time + DAY, time).run();
    } catch (error) {
      const message = String(error);
      if (message.includes('image_quota_exceeded')) throw new UploadError(429, 'quota_exceeded', 'Private image quota reached. Contact the Owner or retry after orphan cleanup.');
      if (message.includes('image_scope_changed')) { await pack(env, principal, id, revision); throw new UploadError(409, 'upload_in_progress', 'The Pack changed. Retry upload.'); }
      if (message.includes('UNIQUE constraint failed')) throw new UploadError(409, 'upload_in_progress', 'The same image is uploading. Retry shortly.');
      throw error;
    }
    // Unique staging key per reservation: interrupted/late writes never replace
    // another upload, and trusted cleanup can delete only this private attempt.
    await env.CONTENT.put(staging, bytes, { onlyIf: { etagDoesNotMatch: '*' },
      httpMetadata: { contentType: type, cacheControl: 'private, no-store' },
      customMetadata: { sha256: digest, imageIngestionVersion: '1' } });
    try {
      const result = await env.DB.batch([
        env.DB.prepare(`UPDATE studio_image_uploads SET state='ready' WHERE pack_id=? AND object_reference=? AND lease_token=? AND state='reserved'`)
          .bind(id, reference, lease),
        env.DB.prepare(`INSERT OR IGNORE INTO studio_pack_images (pack_id,object_reference,established_by_uid,created_at)
          SELECT pack_id,object_reference,request_uid,? FROM studio_image_uploads
          WHERE pack_id=? AND object_reference=? AND lease_token=? AND state='ready'`)
          .bind(new Date().toISOString(), id, reference, lease),
      ]);
      if (result[0].meta.changes !== 1) throw new UploadError(409, 'upload_in_progress', 'Upload reservation expired. Retry the image.');
    } catch (error) {
      if (String(error).includes('image_scope_changed')) { await pack(env, principal, id, revision); }
      throw error;
    }
    return response(await receipt(id, reference, digest, type, bytes.length, dimensions));
  } catch (error) {
    if (error instanceof StudioError) throw error;
    const failure = error instanceof UploadError ? error : error instanceof ImageValidationError
      ? new UploadError(422, 'validation_failed', 'Image format, dimensions or encoded pixels are invalid.')
      : new UploadError(503, 'storage_unavailable', 'Image storage is unavailable. Retry the same image.');
    return response({ protocolVersion: 1, error: { code: failure.code, message: failure.message,
      requestId: crypto.randomUUID(), retryable: failure.status === 503 || failure.status === 409 || failure.status === 408,
      currentRevision: failure.revision } }, failure.status);
  } finally {
    if (acquired) activeTransfers--;
  }
}

/** Called only by explicit T24 attachment after Pack binding resolution. */
export async function promoteImage(env: Env, packId: string, reference: string): Promise<void> {
  if (await env.CONTENT.head(reference)) return; // T24 validates immutable bytes afterward.
  const upload = await env.DB.prepare(`SELECT * FROM studio_image_uploads WHERE pack_id=? AND object_reference=? AND state IN ('ready','attached') AND staging_key IS NOT NULL LIMIT 1`)
    .bind(packId, reference).first<Upload>();
  if (!upload?.staging_key) return;
  // Durable storage charge BEFORE any immutable copy. Once a canonical write is
  // attempted, even a failed Commit must not release its retained-byte quota.
  // This CAS also prevents a cleanup winner leaving an uncharged object behind.
  const reserved = await env.DB.prepare(`UPDATE studio_image_uploads SET canonical_reserved=1
    WHERE pack_id=? AND object_reference=? AND lease_token=? AND state IN ('ready','attached')
    AND EXISTS (SELECT 1 FROM studio_pack_images WHERE pack_id=? AND object_reference=?)`)
    .bind(packId, reference, upload.lease_token, packId, reference).run();
  if (reserved.meta.changes !== 1) throw new ImageValidationError('Image binding expired before promotion.');
  const stored = await env.CONTENT.get(upload.staging_key);
  if (!stored) return;
  const bytes = new Uint8Array(await stored.arrayBuffer());
  const type = reference.endsWith('.png') ? 'image/png' : 'image/webp';
  if (bytes.length > MAX_BYTES || bytes.length !== upload.byte_length || stored.httpMetadata?.contentType !== type
    || await hash(bytes) !== reference.slice(8, 72)) throw new ImageValidationError();
  await validatePreparedImage(bytes, type);
  await env.CONTENT.put(reference, bytes, { onlyIf: { etagDoesNotMatch: '*' },
    httpMetadata: { contentType: type, cacheControl: immutable } });
}

/** Trusted operator primitive, no HTTP/Collector delete route or production cron.
 * Claims rows transactionally before deleting only private staging objects.
 * Canonical objects are never deleted, including copies from failed Commits. */
export async function cleanupImages(env: Env, time = now(), limit = 100): Promise<number> {
  if (!Number.isSafeInteger(time) || time < 0 || !Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error('invalid_cleanup');
  const rows = await env.DB.prepare(`SELECT * FROM studio_image_uploads WHERE
    (state='reserved' AND lease_expires_at<?) OR (state='ready' AND expires_at<? AND canonical_reserved=0)
    OR ((state='attached' OR canonical_reserved=1) AND staging_key IS NOT NULL) OR state='deleting'
    ORDER BY CASE WHEN canonical_reserved=0 AND state IN ('reserved','ready','deleting') THEN 0 ELSE 1 END,
      expires_at,pack_id,object_reference LIMIT ?`)
    .bind(time, time, limit).all<Upload>();
  let removed = 0;
  for (const row of rows.results) {
    if (row.state === 'attached' || row.canonical_reserved === 1) {
      // A crashed/failed canonical put retains its stage and charge so a later
      // explicit Commit can retry. Never discard the last recoverable bytes.
      if (!await env.CONTENT.head(row.object_reference)) continue;
      if (row.staging_key) await env.CONTENT.delete(row.staging_key);
      await env.DB.prepare(`UPDATE studio_image_uploads SET staging_key=NULL WHERE pack_id=? AND object_reference=? AND (state='attached' OR canonical_reserved=1)`)
        .bind(row.pack_id, row.object_reference).run();
      removed++; continue;
    }
    const token = crypto.randomUUID();
    const claims = await env.DB.batch([
      env.DB.prepare(`UPDATE studio_image_uploads SET state='deleting',lease_token=? WHERE pack_id=? AND object_reference=?
        AND canonical_reserved=0 AND ((state='reserved' AND lease_expires_at<?) OR (state='ready' AND expires_at<?) OR state='deleting')`)
        .bind(token, row.pack_id, row.object_reference, time, time),
      env.DB.prepare(`DELETE FROM studio_pack_images WHERE pack_id=? AND object_reference=? AND EXISTS
        (SELECT 1 FROM studio_image_uploads u WHERE u.pack_id=? AND u.object_reference=? AND u.state='deleting' AND u.lease_token=?)`)
        .bind(row.pack_id, row.object_reference, row.pack_id, row.object_reference, token),
    ]);
    if (!claims[0].meta.changes) continue;
    if (row.staging_key) await env.CONTENT.delete(row.staging_key);
    await env.DB.prepare(`DELETE FROM studio_image_uploads WHERE pack_id=? AND object_reference=? AND state='deleting' AND lease_token=?`)
      .bind(row.pack_id, row.object_reference, token).run();
    removed++;
  }
  // A process may die after an R2 put but before D1 completion. Unique unbound
  // private keys can be collected after a full day; no canonical prefix is listed.
  const scan = await env.DB.prepare('SELECT cursor FROM studio_image_cleanup_scan WHERE id=1').first<{cursor: string | null}>();
  const objects = await env.CONTENT.list({ prefix: 'studio-staging/v1/', limit, ...(scan?.cursor ? { cursor: scan.cursor } : {}) });
  for (const object of objects.objects) {
    if (object.uploaded.getTime() / 1000 >= time - DAY) continue;
    const bound = await env.DB.prepare('SELECT 1 AS found FROM studio_image_uploads WHERE staging_key=?')
      .bind(object.key).first();
    if (!bound) { await env.CONTENT.delete(object.key); removed++; }
  }
  await env.DB.prepare('UPDATE studio_image_cleanup_scan SET cursor=? WHERE id=1')
    .bind(objects.truncated ? objects.cursor : null).run();
  return removed;
}
