// Local Chromium/T32 smoke and failure checks; never modifies repository assets.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {createHash} = require('node:crypto');
const {prepareLegacyImages} = require('../../scripts/legacy_image_preparation.cjs');
const hash = bytes=>createHash('sha256').update(bytes).digest('hex');
(async()=>{
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(),'biguess-legacy-preparation-test-'));
  const root = path.join(temporary,'repo');
  try {
    fs.mkdirSync(path.join(root,'studio/web'),{recursive:true});
    fs.mkdirSync(path.join(root,'assets/images/Fixture/Pack'),{recursive:true});
    const worker = fs.readFileSync(path.resolve(__dirname,'../web/image_preparation_worker.js'));
    fs.writeFileSync(path.join(root,'studio/web/image_preparation_worker.js'),worker);
    const bytes = fs.readFileSync(path.resolve(__dirname,'../../backend/content-api/fixtures/image.webp'));
    const records = ['Alpha.webp','Même image.webp'].map(file_name=>{
      const source_path=`assets/images/Fixture/Pack/${file_name}`;
      fs.writeFileSync(path.join(root,source_path),bytes);
      return {source_path,file_name,sha256:hash(bytes),size_bytes:bytes.length};
    });
    const outputDir = path.join(temporary,'private-output');
    const progress=[];
    const first = await prepareLegacyImages({repoRoot:root,records,outputDir,onProgress:p=>progress.push(p.completed)});
    assert.equal(first.prepared.length,2);
    assert.equal(first.workerSha256,hash(worker));
    assert.equal(typeof first.browserVersion,'string');
    assert.deepEqual(progress,[1,2]);
    assert.equal(first.prepared[0].objectReference,first.prepared[1].objectReference,'equal bytes keep separate source records but one normalized object');
    assert.equal(fs.readdirSync(path.join(outputDir,'objects')).length,1);
    for(const record of records) assert.equal(hash(fs.readFileSync(path.join(root,record.source_path))),record.sha256);
    const second = await prepareLegacyImages({repoRoot:root,records,outputDir});
    assert.deepEqual(second.prepared,first.prepared,'same sources/browser/worker are repeatable');
    await assert.rejects(prepareLegacyImages({repoRoot:root,records:[{...records[0],sha256:'0'.repeat(64)}],outputDir}),/checksum mismatch/);
    await assert.rejects(prepareLegacyImages({repoRoot:root,records,outputDir:path.join(root,'assets/private')}),/outside the repository/);
    const controller = new AbortController(); controller.abort();
    await assert.rejects(prepareLegacyImages({repoRoot:root,records,outputDir,signal:controller.signal}),error=>error.code==='cancelled');
    const interrupted = new AbortController();
    await assert.rejects(prepareLegacyImages({repoRoot:root,records,outputDir,
      signal:interrupted.signal,onProgress:()=>interrupted.abort()}),error=>error.code==='cancelled');
    console.log('T38 Chromium preparation PASS: unchanged T32 worker, sequential duplicate-preserving records, deterministic normalized objects, unchanged sources, checksum/output-boundary rejection and cancellation.');
  } finally { fs.rmSync(temporary,{recursive:true,force:true}); }
})().catch(error=>{console.error(error);process.exitCode=1;});
