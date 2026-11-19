/** T38 source reconciliation and immutable mapping. No image transformation. */
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, lstatSync, realpathSync } from 'node:fs';
import path from 'node:path';

export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
export function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort()
    .map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  return JSON.stringify(value);
}
const expected = {Anime:922,Geography:252};
export function legacyIds(sourcePath) {
  const parts = sourcePath.split('/');
  if (parts.length !== 5 || parts[0] !== 'assets' || parts[1] !== 'images' ||
      parts.some(p => !p || p === '.' || p === '..') || sourcePath.includes('\\')) {
    throw new Error(`Invalid legacy source path: ${sourcePath}`);
  }
  const topic = parts[2], pack = parts[3];
  const topicKey = encodeURIComponent(topic), packKey = `${topicKey}:${encodeURIComponent(pack)}`;
  // T06 adapts the generated manifest, which NFC-normalizes the filename only.
  const asset = [...parts.slice(0,4),parts[4].normalize('NFC')].join('/');
  return {topicId:`legacy:topic:${topicKey}`,packId:`legacy:pack:${packKey}`,
    cardId:`legacy:card:${packKey}:${encodeURIComponent(asset)}`,
    topic,pack,name:path.posix.parse(parts[4].normalize('NFC')).name};
}
function walk(directory) {
  return readdirSync(directory,{withFileTypes:true}).sort((a,b)=>a.name<b.name?-1:a.name>b.name?1:0)
    .flatMap(entry => {
      const child = path.join(directory,entry.name);
      if (entry.isSymbolicLink()) throw new Error(`Symlink source is not accepted: ${child}`);
      return entry.isDirectory() ? walk(child) : [child];
    });
}
export function readLegacyInventory(repoRoot, expectedCounts = expected) {
  const root = realpathSync(repoRoot);
  const inventoryPath = path.join(root,'docs/migration/content_inventory.json');
  const inventoryBytes = readFileSync(inventoryPath);
  const inventory = JSON.parse(inventoryBytes);
  if (inventory.inventory_version !== '1.0.0' || !Array.isArray(inventory.records)) throw new Error('Unsupported T05 inventory');
  const records = inventory.records.filter(r => r.source_path.startsWith('assets/images/'));
  const paths = new Set(), ids = new Set(), totals = {};
  for (const record of records) {
    const names = legacyIds(record.source_path);
    if (paths.has(record.source_path) || ids.has(names.cardId)) throw new Error('Duplicate source path or T06 ID');
    paths.add(record.source_path); ids.add(names.cardId);
    if (names.topic !== record.topic || names.pack !== record.pack || !record.proposed_stable_id ||
        !record.proposed_topic_id || !record.proposed_pack_id || record.technical_importability?.is_importable !== true ||
        !record.rights || !['unverified','quarantined','cleared'].includes(record.rights.rights_status)) {
      throw new Error(`Invalid T05 source metadata: ${record.source_path}`);
    }
    const file = path.join(root,record.source_path);
    if (lstatSync(file).isSymbolicLink() || !realpathSync(file).startsWith(root + path.sep)) throw new Error('Source escapes repository');
    const bytes = readFileSync(file);
    if (bytes.length !== record.size_bytes || sha256(bytes) !== record.sha256) throw new Error(`Source checksum mismatch: ${record.source_path}`);
    totals[names.topic] = (totals[names.topic] || 0) + 1;
  }
  const actual = walk(path.join(root,'assets/images')).map(file=>path.relative(root,file).split(path.sep).join('/'));
  if (actual.length !== paths.size || actual.some(file=>!paths.has(file))) {
    throw new Error('Source inventory drift: ' + actual.filter(file=>!paths.has(file)).join(', '));
  }
  if (canonical(totals) !== canonical(expectedCounts)) throw new Error(`Source count deviation: ${canonical(totals)}`);
  return {records:records.sort((a,b)=>a.source_path<b.source_path?-1:a.source_path>b.source_path?1:0),
    inventorySha256:sha256(inventoryBytes),totals,
    excludedFixtures:inventory.records.filter(r=>!paths.has(r.source_path)).map(r=>({sourcePath:r.source_path,
      inventoryId:r.proposed_stable_id,rights:r.rights,reason:'Separate T05 fixture; not part of the legacy import'}))};
}
export function createLegacyBundle(inventory, preparation) {
  const prepared = new Map(preparation.prepared.map(r=>[r.sourcePath,r]));
  if (prepared.size !== inventory.records.length || preparation.prepared.length !== prepared.size) throw new Error('Incomplete preparation');
  const records = [], topics = new Map(), packs = new Map();
  for (const source of inventory.records) {
    const ids = legacyIds(source.source_path), image = prepared.get(source.source_path);
    if (!image || image.sourceSha256 !== source.sha256 || image.sizeBytes < 1 ||
        !['image/png','image/webp'].includes(image.mimeType) || image.objectReference !==
          `objects/${image.sha256}.${image.mimeType === 'image/png'?'png':'webp'}`) throw new Error(`Invalid preparation receipt: ${source.source_path}`);
    const topic = {resourceType:'topic',id:ids.topicId,name:ids.topic,inventoryId:source.proposed_topic_id};
    const pack = {resourceType:'pack',id:ids.packId,name:ids.pack,parentId:ids.topicId,inventoryId:source.proposed_pack_id};
    if (topics.has(topic.id) && canonical(topics.get(topic.id)) !== canonical(topic) ||
        packs.has(pack.id) && canonical(packs.get(pack.id)) !== canonical(pack)) throw new Error('Inconsistent T05 parent mapping');
    topics.set(topic.id,topic); packs.set(pack.id,pack);
    records.push({resourceType:'card',id:ids.cardId,parentId:ids.packId,name:ids.name,difficulty:1,
      imageReference:image.objectReference,sourcePath:source.source_path,inventoryId:source.proposed_stable_id,
      sourceSha256:source.sha256,sourceBytes:source.size_bytes,preparedSha256:image.sha256,
      preparedBytes:image.sizeBytes,provenance:source.rights});
  }
  const core = {protocolVersion:1,inventorySha256:inventory.inventorySha256,
    workerSha256:preparation.workerSha256,records:[...topics.values(),...packs.values(),...records]};
  return {...core,importId:sha256(Buffer.from(canonical(core)))};
}
