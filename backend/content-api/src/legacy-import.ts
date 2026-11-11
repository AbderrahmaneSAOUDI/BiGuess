/** Trusted local operator library. It is intentionally not routed by index.ts. */
import type { Env } from './env';
import { hash } from './publication';
import { validatePreparedImage } from './image-validation';

export type LegacyRecord = {
  resourceType: 'topic' | 'pack' | 'card'; id: string; name: string; inventoryId: string;
  parentId?: string; difficulty?: number; imageReference?: string; sourcePath?: string;
  sourceSha256?: string; sourceBytes?: number; preparedSha256?: string; preparedBytes?: number;
  provenance?: Record<string, unknown>;
};
export type LegacyImportBundle = { protocolVersion: 1; importId: string;
  inventorySha256: string; workerSha256: string; records: LegacyRecord[]; objects: Record<string, string> };
export class LegacyImportError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) { super(message); }
}
const invalid = (message: string): never => { throw new LegacyImportError(422, 'invalid_import', message); };
const conflict = (message: string): never => { throw new LegacyImportError(409, 'import_conflict', message); };
const hex = (v: unknown): v is string => typeof v === 'string' && /^[a-f0-9]{64}$/.test(v);
const text = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 4096;
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (object(value)) return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  return JSON.stringify(value);
}
const bytes = (value: string) => new TextEncoder().encode(value);
const keyOf = (kind: string, id: string) => JSON.stringify([kind,id]);
const valueOf = (row: LegacyRecord) => row.resourceType === 'topic' ? {name:row.name}
  : row.resourceType === 'pack' ? {name:row.name,topicId:row.parentId}
    : {name:row.name,packId:row.parentId,imageReference:row.imageReference,difficulty:1};
function local(env: Env) {
  if (env.APP_ENV !== 'local') throw new LegacyImportError(403,'local_only','Legacy import and rollback are local-only.');
}
function validate(input: unknown): {bundle: LegacyImportBundle; manifest: string; refs: Map<string, LegacyRecord>} {
  if (!object(input) || Object.keys(input).sort().join(',') !== 'importId,inventorySha256,objects,protocolVersion,records,workerSha256'
    || input.protocolVersion !== 1 || !hex(input.importId) || !hex(input.inventorySha256) || !hex(input.workerSha256)
    || !Array.isArray(input.records) || input.records.length < 1 || input.records.length > 10000 || !object(input.objects)) invalid('Invalid import envelope.');
  const bundle = input as unknown as LegacyImportBundle;
  const ids = new Set<string>(), paths = new Set<string>(), inventoryIds = new Set<string>();
  const refs = new Map<string, LegacyRecord>();
  for (const row of bundle.records) {
    if (!object(row) || !['topic','pack','card'].includes(row.resourceType) || !text(row.id)
      || !row.id.startsWith(`legacy:${row.resourceType}:`) || /[\s\p{Cc}\p{Cs}]/u.test(row.id)
      || !text(row.name) || row.name.trim() !== row.name || row.name.length > 160
      || !text(row.inventoryId) || !/^[a-f0-9-]{36}$/.test(row.inventoryId)) invalid('Invalid legacy entity identity.');
    const base = ['resourceType','id','name','inventoryId'];
    const fields = row.resourceType === 'topic' ? base : row.resourceType === 'pack' ? [...base,'parentId']
      : [...base,'parentId','difficulty','imageReference','sourcePath','sourceSha256','sourceBytes','preparedSha256','preparedBytes','provenance'];
    if (Object.keys(row).sort().join(',') !== fields.sort().join(',')) invalid('Unexpected legacy fields.');
    if (ids.has(keyOf(row.resourceType,row.id)) || inventoryIds.has(row.inventoryId)) invalid('Duplicate legacy identity.');
    ids.add(keyOf(row.resourceType,row.id)); inventoryIds.add(row.inventoryId);
    if (row.resourceType !== 'topic' && !text(row.parentId)) invalid('Invalid legacy parent.');
    if (row.resourceType === 'card') {
      if (row.difficulty !== 1 || !hex(row.sourceSha256) || !hex(row.preparedSha256)
        || !Number.isSafeInteger(row.sourceBytes) || row.sourceBytes! < 1 || row.sourceBytes! > 20*1024*1024
        || !Number.isSafeInteger(row.preparedBytes) || row.preparedBytes! < 1 || row.preparedBytes! > 5*1024*1024
        || !text(row.sourcePath) || !/^assets\/images\/[^/]+\/[^/]+\/[^/]+\.(webp|png|jpe?g)$/i.test(row.sourcePath)
        || row.sourcePath.includes('..') || paths.has(row.sourcePath)
        || !text(row.imageReference) || !new RegExp(`^objects/${row.preparedSha256}\\.(webp|png)$`).test(row.imageReference)
        || !object(row.provenance) || !['unverified','quarantined'].includes(String(row.provenance.rights_status))
        || row.provenance.permission_to_publish !== false || row.provenance.public_test_publishable !== false
        || !text(row.provenance.source) || !text(row.provenance.license) || !text(row.provenance.attribution)
        || !text(row.provenance.quarantine_reason)) invalid('Invalid quarantined source or image provenance.');
      paths.add(row.sourcePath!);
      const previous = refs.get(row.imageReference!);
      if (previous && previous.preparedBytes !== row.preparedBytes) invalid('Conflicting normalized image descriptors.');
      refs.set(row.imageReference!,row);
    }
  }
  for (const row of bundle.records) if (row.resourceType !== 'topic'
    && !ids.has(keyOf(row.resourceType === 'pack' ? 'topic' : 'pack',row.parentId!))) invalid('Missing legacy parent.');
  if (Object.keys(bundle.objects).length !== refs.size || [...refs.keys()].some(ref => typeof bundle.objects[ref] !== 'string')) invalid('Image objects must match the source mapping exactly.');
  const manifest = canonical({protocolVersion:1,inventorySha256:bundle.inventorySha256,workerSha256:bundle.workerSha256,records:bundle.records});
  return {bundle,manifest,refs};
}
function result(row: {import_id: string; record_count: number; source_count: number; object_count: number; manifest_json: string}, rolledBack: boolean, replayed: boolean) {
  const manifest = JSON.parse(row.manifest_json) as LegacyImportBundle;
  return {protocolVersion:1,importId:row.import_id,state:rolledBack?'rolled_back':'quarantined',replayed,
    recordCount:row.record_count,sourceCount:row.source_count,objectCount:row.object_count,
    manifestSha256:row.import_id,inventorySha256:manifest.inventorySha256,workerSha256:manifest.workerSha256};
}
const changeRows = (env: Env, importId: string) => env.DB.prepare(`INSERT INTO studio_read_changes
  (generation,resource_type,resource_id,pack_id,pack_creator_uid,kind,projection_json)
  SELECT g.generation,e.resource_type,e.id,CASE WHEN e.resource_type='topic' THEN NULL WHEN e.resource_type='pack' THEN e.id ELSE e.parent_id END,
    NULL,CASE WHEN e.state='deleted' THEN 'remove' ELSE 'upsert' END,
    json_patch(json_patch(json_object('resourceType',e.resource_type,'id',e.id,'state',e.state,'revision',e.revision,
      'createdByUid',NULL,'createdAt',NULL),CASE WHEN e.resource_type='pack' THEN json_object('topicId',e.parent_id)
      WHEN e.resource_type='card' THEN json_object('packId',e.parent_id) ELSE '{}' END),e.value)
  FROM studio_entities e JOIN studio_legacy_records q ON q.resource_type=e.resource_type AND q.resource_id=e.id
  CROSS JOIN studio_generation g WHERE q.import_id=? AND g.id=1`).bind(importId);
type ImportRow = {import_id: string; record_count: number; source_count: number; object_count: number; manifest_json: string};

export async function importLegacyDrafts(env: Env, input: unknown) {
  local(env);
  const {bundle,manifest,refs} = validate(input);
  if (await hash(bytes(manifest)) !== bundle.importId) invalid('Import checksum does not match its manifest.');
  const normalized = new Map<string,Uint8Array>();
  let total = 0;
  // Decode/validate one image at a time. Input and prepared output remain bounded;
  // no native/Python image conversion occurs in this operator library.
  for (const [ref,row] of refs) {
    const encoded = bundle.objects[ref];
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) invalid('Invalid image encoding.');
    let image: Uint8Array;
    try { image = Uint8Array.from(atob(encoded), c=>c.charCodeAt(0)); } catch { return invalid('Invalid image encoding.'); }
    if (image.length !== row.preparedBytes || (total += image.length) > 100*1024*1024 || await hash(image) !== row.preparedSha256) invalid('Prepared image checksum mismatch.');
    await validatePreparedImage(image,ref.endsWith('.webp')?'image/webp':'image/png');
    normalized.set(ref,image);
  }
  const reads = await env.DB.batch<Record<string, unknown>>([
    env.DB.prepare('SELECT generation FROM studio_generation WHERE id=1'),
    env.DB.prepare('SELECT * FROM studio_legacy_imports WHERE import_id=?').bind(bundle.importId),
    env.DB.prepare('SELECT 1 FROM studio_legacy_rollbacks WHERE import_id=?').bind(bundle.importId),
    env.DB.prepare(`SELECT json_extract(r.value,'$.id') AS id FROM json_each(?) r WHERE
      EXISTS (SELECT 1 FROM studio_entities e WHERE e.resource_type=json_extract(r.value,'$.resourceType') AND e.id=json_extract(r.value,'$.id'))
      OR EXISTS (SELECT 1 FROM catalog_topics c WHERE json_extract(r.value,'$.resourceType')='topic' AND c.id=json_extract(r.value,'$.id'))
      OR EXISTS (SELECT 1 FROM catalog_packs c WHERE json_extract(r.value,'$.resourceType')='pack' AND c.id=json_extract(r.value,'$.id'))
      OR EXISTS (SELECT 1 FROM publication_heads h WHERE h.pack_id=json_extract(r.value,'$.id')) LIMIT 1`).bind(JSON.stringify(bundle.records)),
  ]);
  const existing = reads[1].results[0] as ImportRow | undefined;
  if (existing) {
    if (existing.manifest_json !== manifest) conflict('Import identity already records a different manifest.');
    // Replaying a manifest is evidence of a complete private installation, not
    // permission to repair or overlook missing/corrupt persistent image bytes.
    for (const [ref,descriptor] of refs) {
      const stored = await env.CONTENT.get(ref);
      const type = ref.endsWith('.webp')?'image/webp':'image/png';
      if (!stored || stored.size !== descriptor.preparedBytes || stored.httpMetadata?.contentType !== type
        || await hash(new Uint8Array(await stored.arrayBuffer())) !== descriptor.preparedSha256) {
        conflict('A persisted imported image is missing, corrupt or mislabeled; replay did not repair it.');
      }
    }
    return result(existing,reads[2].results.length>0,true);
  }
  if (reads[3].results.length) conflict('A stable legacy ID already exists; no overwrite is permitted.');
  // Content-addressed writes are private. A failed metadata commit can leave
  // only unreferenced private objects; it cannot create a public catalog entry.
  for (const [ref,image] of normalized) {
    const old = await env.CONTENT.get(ref);
    if (old) {
      if (old.size !== image.length || old.httpMetadata?.contentType !== (ref.endsWith('.webp')?'image/webp':'image/png')
        || await hash(new Uint8Array(await old.arrayBuffer())) !== ref.slice(8,72)) conflict('Existing image bytes or media type do not match their content address.');
    } else await env.CONTENT.put(ref,image,{httpMetadata:{contentType:ref.endsWith('.webp')?'image/webp':'image/png'}});
  }
  const now = new Date().toISOString();
  const row: ImportRow = {import_id:bundle.importId,record_count:bundle.records.length,
    source_count:bundle.records.filter(r=>r.resourceType==='card').length,object_count:refs.size,manifest_json:manifest};
  const report = result(row,false,false);
  const staged = JSON.stringify(bundle.records.map(r=>({...r,value:canonical(valueOf(r))})));
  const generation = reads[0].results[0].generation;
  try {
    await env.DB.batch<Record<string, unknown>>([
      env.DB.prepare('INSERT INTO studio_commits VALUES (?,?,?,?,?,?,?)').bind('__legacy_import__',bundle.importId,bundle.importId,manifest,JSON.stringify(report),`legacy-import:${bundle.importId}`,generation),
      env.DB.prepare('INSERT INTO studio_legacy_imports VALUES (?,?,?,?,?,?)').bind(bundle.importId,manifest,now,row.record_count,row.source_count,row.object_count),
      env.DB.prepare(`INSERT INTO studio_legacy_records SELECT json_extract(value,'$.resourceType'),json_extract(value,'$.id'),?,json_remove(value,'$.value') FROM json_each(?)`).bind(bundle.importId,staged),
      env.DB.prepare(`INSERT INTO studio_entities SELECT json_extract(value,'$.resourceType'),json_extract(value,'$.id'),json_extract(value,'$.parentId'),json_extract(value,'$.value'),'hidden',1 FROM json_each(?)`).bind(staged),
      env.DB.prepare(`INSERT INTO studio_creators SELECT json_extract(value,'$.resourceType'),json_extract(value,'$.id'),NULL,NULL,'legacy' FROM json_each(?)`).bind(staged),
      env.DB.prepare(`INSERT OR IGNORE INTO studio_pack_images SELECT json_extract(value,'$.parentId'),json_extract(value,'$.imageReference'),NULL,? FROM json_each(?) WHERE json_extract(value,'$.resourceType')='card'`).bind(now,staged),
      changeRows(env,bundle.importId),
    ]);
  } catch { conflict('Content changed or a stable ID was occupied; retry the unchanged local import.'); }
  return report;
}

export async function rollbackLegacyDrafts(env: Env, importId: string) {
  local(env);
  if (!hex(importId)) invalid('Invalid import checksum.');
  const reads = await env.DB.batch<Record<string, unknown>>([
    env.DB.prepare('SELECT generation FROM studio_generation WHERE id=1'),
    env.DB.prepare('SELECT * FROM studio_legacy_imports WHERE import_id=?').bind(importId),
    env.DB.prepare('SELECT report_json FROM studio_legacy_rollbacks WHERE import_id=?').bind(importId),
    env.DB.prepare(`SELECT e.*,q.record_json,c.source,c.created_by_uid FROM studio_legacy_records q
      LEFT JOIN studio_entities e ON e.resource_type=q.resource_type AND e.id=q.resource_id
      LEFT JOIN studio_creators c ON c.resource_type=q.resource_type AND c.resource_id=q.resource_id WHERE q.import_id=?`).bind(importId),
    env.DB.prepare(`SELECT 1 FROM studio_legacy_records q WHERE q.import_id=? AND (
      EXISTS (SELECT 1 FROM catalog_topics c WHERE q.resource_type='topic' AND c.id=q.resource_id)
      OR EXISTS (SELECT 1 FROM catalog_packs c WHERE q.resource_type='pack' AND c.id=q.resource_id)
      OR EXISTS (SELECT 1 FROM publication_heads h WHERE h.pack_id=q.resource_id)
      OR EXISTS (SELECT 1 FROM studio_publication_events p WHERE p.resource_id=q.resource_id)
      OR EXISTS (SELECT 1 FROM studio_entities e WHERE e.parent_id=q.resource_id AND NOT EXISTS (
        SELECT 1 FROM studio_legacy_records child WHERE child.import_id=q.import_id AND child.resource_type=e.resource_type AND child.resource_id=e.id))) LIMIT 1`).bind(importId),
  ]);
  const row = reads[1].results[0] as ImportRow | undefined;
  if (!row) return conflict('Import evidence does not exist.');
  if (reads[2].results.length) return {...JSON.parse(String(reads[2].results[0].report_json)),replayed:true};
  if (reads[4].results.length || reads[3].results.length !== row.record_count) conflict('Import has external dependents or review/publication side effects.');
  for (const stored of reads[3].results) {
    const source = JSON.parse(String(stored.record_json)) as LegacyRecord;
    if (stored.revision !== 1 || stored.state !== 'hidden' || stored.source !== 'legacy'
      || stored.created_by_uid !== null || stored.parent_id !== (source.parentId ?? null)
      || stored.value !== canonical(valueOf(source))) conflict('Imported records have changed; automatic rollback is unsafe.');
  }
  const now = new Date().toISOString();
  const report = result(row,true,false);
  try {
    await env.DB.batch<Record<string, unknown>>([
      env.DB.prepare('INSERT INTO studio_commits VALUES (?,?,?,?,?,?,?)').bind('__legacy_import__',`rollback:${importId}`,importId,'{}',JSON.stringify(report),`legacy-rollback:${importId}`,reads[0].results[0].generation),
      env.DB.prepare('INSERT INTO studio_legacy_rollbacks VALUES (?,?,?)').bind(importId,now,JSON.stringify(report)),
      env.DB.prepare(`UPDATE studio_entities SET state='deleted',revision=2 WHERE EXISTS (SELECT 1 FROM studio_legacy_records q WHERE q.import_id=? AND q.resource_type=studio_entities.resource_type AND q.resource_id=studio_entities.id)`).bind(importId),
      env.DB.prepare(`INSERT INTO studio_tombstones SELECT resource_type,resource_id,2,? FROM studio_legacy_records WHERE import_id=?`).bind(now,importId),
      changeRows(env,importId),
    ]);
  } catch { conflict('Content changed during rollback; no imported metadata was partially rolled back.'); }
  return report;
}
