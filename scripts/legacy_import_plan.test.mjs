import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { legacyIds,readLegacyInventory,createLegacyBundle,canonical,sha256 } from './legacy_import_plan.mjs';
const root=fileURLToPath(new URL('../',import.meta.url));
test('reconciles all 1174 original sources and keeps the four cleared fixtures separate',()=>{
  const inventory=readLegacyInventory(root);
  assert.deepEqual(inventory.totals,{Anime:922,Geography:252});
  assert.equal(inventory.records.length,1174);
  assert.equal(inventory.excludedFixtures.length,4);
  assert(inventory.records.every(r=>r.rights.permission_to_publish===false));
});
test('T06 IDs preserve case, Unicode, parent keys and filename source identity',()=>{
  const p='assets/images/Anime/Attack on Titan/Éren (Young).webp';
  const ids=legacyIds(p);
  assert.equal(ids.topicId,'legacy:topic:Anime');
  assert.equal(ids.packId,'legacy:pack:Anime:Attack%20on%20Titan');
  assert.equal(ids.cardId,`legacy:card:Anime:Attack%20on%20Titan:${encodeURIComponent(p)}`);
  assert.equal(ids.name,'Éren (Young)');
  assert.throws(()=>legacyIds('assets/images/Anime/../bad.webp'));
});
test('plan retains all stable IDs/provenance and is byte-repeatable without promoting rights',()=>{
  const inventory=readLegacyInventory(root);
  const preparation={workerSha256:'a'.repeat(64),prepared:inventory.records.map(r=>({sourcePath:r.source_path,
    sourceSha256:r.sha256,sha256:r.sha256,sizeBytes:r.size_bytes,mimeType:'image/webp',objectReference:`objects/${r.sha256}.webp`}))};
  const first=createLegacyBundle(inventory,preparation);
  assert.equal(first.records.length,1183);
  assert.equal(first.importId,createLegacyBundle(inventory,preparation).importId);
  assert.deepEqual(first.records.filter(r=>r.resourceType==='card').map(r=>r.inventoryId),inventory.records.map(r=>r.proposed_stable_id));
  assert(first.records.filter(r=>r.resourceType==='card').every(r=>r.provenance.rights_status==='unverified'));
  assert.throws(()=>createLegacyBundle(inventory,{...preparation,prepared:preparation.prepared.slice(1)}));
  assert.equal(inventory.inventorySha256,sha256(readFileSync(root+'docs/migration/content_inventory.json')));
  assert.equal(canonical({b:1,a:2}),'{'+'"a":2,"b":1}');
});

test('source checksum drift, extra files and symlinks fail before image conversion',async()=>{
  const {mkdtempSync,mkdirSync,writeFileSync,rmSync,symlinkSync}=await import('node:fs');
  const {tmpdir}=await import('node:os');
  const dir=mkdtempSync(tmpdir()+'/t38-source-');
  try {
    mkdirSync(dir+'/assets/images/Anime/Pack',{recursive:true});
    mkdirSync(dir+'/docs/migration',{recursive:true});
    const sourcePath='assets/images/Anime/Pack/One.webp',bytes=Buffer.from('read-only source audit');
    const record={source_path:sourcePath,sha256:sha256(bytes),size_bytes:bytes.length,topic:'Anime',pack:'Pack',
      proposed_stable_id:'card',proposed_topic_id:'topic',proposed_pack_id:'pack',technical_importability:{is_importable:true},
      rights:{rights_status:'unverified'}};
    writeFileSync(dir+'/'+sourcePath,bytes);
    writeFileSync(dir+'/docs/migration/content_inventory.json',JSON.stringify({inventory_version:'1.0.0',records:[record]}));
    assert.equal(readLegacyInventory(dir,{Anime:1}).records.length,1);
    writeFileSync(dir+'/'+sourcePath,'changed');
    assert.throws(()=>readLegacyInventory(dir,{Anime:1}),/checksum/);
    writeFileSync(dir+'/'+sourcePath,bytes);
    writeFileSync(dir+'/assets/images/Anime/Pack/unaccounted.webp',bytes);
    assert.throws(()=>readLegacyInventory(dir,{Anime:1}),/drift/);
    rmSync(dir+'/assets/images/Anime/Pack/unaccounted.webp');
    rmSync(dir+'/'+sourcePath);symlinkSync('/etc/hosts',dir+'/'+sourcePath);
    assert.throws(()=>readLegacyInventory(dir,{Anime:1}),/escapes/);
  } finally {rmSync(dir,{recursive:true,force:true});}
});

test('operator preflight rejects repository outputs and unrelated nonempty directories without writing',async()=>{
  const {execFileSync}=await import('node:child_process');
  const {existsSync,mkdtempSync,writeFileSync,rmSync}=await import('node:fs');
  const {tmpdir}=await import('node:os');
  const invalid=root+'build/t38-forbidden-'+process.pid;
  assert.equal(existsSync(invalid),false);
  assert.throws(()=>execFileSync(process.execPath,[root+'scripts/import_legacy_content.mjs','--output',invalid],{stdio:'pipe'}));
  assert.equal(existsSync(invalid),false);
  const existing=mkdtempSync(tmpdir()+'/t38-unrelated-');
  try {
    writeFileSync(existing+'/import-report.json','unrelated data');
    assert.throws(()=>execFileSync(process.execPath,[root+'scripts/import_legacy_content.mjs','--output',existing],{stdio:'pipe'}));
    assert.equal(readFileSync(existing+'/import-report.json','utf8'),'unrelated data');
    assert.equal(existsSync(existing+'/.biguess-t38-local-output'),false);
  } finally {rmSync(existing,{recursive:true,force:true});}
});

test('marked output child symlinks cannot redirect report writes outside private storage',async()=>{
  const {execFileSync}=await import('node:child_process');
  const {mkdtempSync,writeFileSync,rmSync,symlinkSync,existsSync}=await import('node:fs');
  const {tmpdir}=await import('node:os');
  const dir=mkdtempSync(tmpdir()+'/t38-linked-output-'),target=dir+'-unrelated.txt';
  try {
    writeFileSync(target,'preserve me');
    writeFileSync(dir+'/.biguess-t38-local-output','BiGuess T38 local private import v1\n');
    symlinkSync(target,dir+'/repeat-report.json');
    assert.throws(()=>execFileSync(process.execPath,[root+'scripts/import_legacy_content.mjs','--output',dir],{stdio:'pipe'}));
    assert.equal(readFileSync(target,'utf8'),'preserve me');
    assert.equal(existsSync(dir+'/preparation.json'),false);
  } finally {rmSync(dir,{recursive:true,force:true});rmSync(target);}
});

test('ownership marker must be an exact regular file before adopting a nonempty output',async()=>{
  const {execFileSync}=await import('node:child_process');
  const {mkdtempSync,writeFileSync,rmSync,mkdirSync}=await import('node:fs');
  const {tmpdir}=await import('node:os');
  const dir=mkdtempSync(tmpdir()+'/t38-marker-');
  try {
    writeFileSync(dir+'/.biguess-t38-local-output','another application');
    assert.throws(()=>execFileSync(process.execPath,[root+'scripts/import_legacy_content.mjs','--output',dir],{stdio:'pipe'}));
    rmSync(dir+'/.biguess-t38-local-output');mkdirSync(dir+'/.biguess-t38-local-output');
    assert.throws(()=>execFileSync(process.execPath,[root+'scripts/import_legacy_content.mjs','--output',dir],{stdio:'pipe'}));
  } finally {rmSync(dir,{recursive:true,force:true});}
});
