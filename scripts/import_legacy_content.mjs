#!/usr/bin/env node
/** Local-only T38 operator. No cloud URL, credentials, publish or remote mode. */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, realpathSync, lstatSync, renameSync, chmodSync } from 'node:fs';
import path from 'node:path';
import { canonical,sha256,readLegacyInventory,createLegacyBundle } from './legacy_import_plan.mjs';

const repoRoot=fileURLToPath(new URL('../',import.meta.url));
const backend=path.join(repoRoot,'backend/content-api');
const require=createRequire(path.join(backend,'package.json'));
const {Miniflare,convertV4MiniflareOptions}=require('miniflare');
const {generateKeyPair,exportJWK,SignJWT}=await import(require.resolve('jose'));
const args=process.argv.slice(2);
if (args.includes('--help')) {
  console.log('node scripts/import_legacy_content.mjs --output /absolute/private/directory [--rollback]');
  process.exit(0);
}
if (args.some((arg,i)=> !['--output','--rollback'].includes(arg) && args[i-1]!=='--output') ||
    args.filter(arg=>arg==='--output').length!==1 || args.filter(arg=>arg==='--rollback').length>1) throw new Error('Unknown or repeated argument');
const outputArgument=args[args.indexOf('--output')+1];
if (!outputArgument || !path.isAbsolute(outputArgument)) throw new Error('An absolute private --output directory is required');
const output=path.resolve(outputArgument);
if (output===repoRoot.slice(0,-1) || output.startsWith(repoRoot)) throw new Error('Output must be outside the repository');
let ancestor=output;
while (!existsSync(ancestor)) ancestor=path.dirname(ancestor);
if (path.resolve(realpathSync(ancestor),path.relative(ancestor,output))!==output) throw new Error('Output symlinks are not accepted');
const marker=path.join(output,'.biguess-t38-local-output');
const markerText='BiGuess T38 local private import v1\n';
if (existsSync(output) && readdirSync(output).length && (!existsSync(marker) ||
    !lstatSync(marker).isFile() || lstatSync(marker).isSymbolicLink() || readFileSync(marker,'utf8')!==markerText)) {
  throw new Error('Use an empty dedicated private output directory or the exact regular ownership marker');
}
function rejectOutputLinks(directory) {
  for (const name of readdirSync(directory)) {
    const child=path.join(directory,name),info=lstatSync(child);
    if (info.isSymbolicLink() || info.isFile() && info.nlink>1) throw new Error('Output links are not accepted: '+child);
    if (info.isDirectory()) rejectOutputLinks(child);
  }
}
if (existsSync(output)) rejectOutputLinks(output);
mkdirSync(output,{recursive:true,mode:0o700});
if (lstatSync(output).isSymbolicLink() || realpathSync(output)!==output) throw new Error('Output must be a real private directory');
chmodSync(output,0o700);
if (!existsSync(marker)) writeFileSync(marker,markerText,{mode:0o600,flag:'wx'});
const json=(filename,value)=>{
  const temporary=path.join(output,`.t38-${randomUUID()}.tmp`);
  writeFileSync(temporary,JSON.stringify(value,null,2)+'\n',{mode:0o600,flag:'wx'});
  renameSync(temporary,path.join(output,filename));
};
const manifestPath=path.join(output,'manifest.json');
let bundle,preparation,sourceAudit;
if (args.includes('--rollback')) {
  bundle=JSON.parse(readFileSync(manifestPath));
} else {
  sourceAudit=readLegacyInventory(repoRoot);
  const {prepareLegacyImages}=require(path.join(repoRoot,'scripts/legacy_image_preparation.cjs'));
  preparation=await prepareLegacyImages({repoRoot,records:sourceAudit.records,outputDir:output,
    chromeExecutable:process.env.CHROME_EXECUTABLE,
    onProgress:value=>{if (value.completed===1 || value.completed%100===0 || value.completed===1174) console.log(JSON.stringify({preparation:value}));}});
  bundle=createLegacyBundle(sourceAudit,preparation);
  if (existsSync(manifestPath)) assert.equal(canonical(JSON.parse(readFileSync(manifestPath))),canonical(bundle),'An existing import manifest cannot be replaced by different output');
  else json('manifest.json',bundle);
  json('preparation.json',preparation);
  // Detect source changes during browser processing before any import occurs.
  assert.equal(canonical(readLegacyInventory(repoRoot)),canonical(sourceAudit),'Source changed during preparation');
}
const workerDir=path.join(output,'worker');
mkdirSync(workerDir,{recursive:true,mode:0o700});
execFileSync(process.execPath,[path.join(backend,'node_modules/wrangler/bin/wrangler.js'),'deploy','test/legacy-import-worker.ts',
  '--env','local','--dry-run','--outdir',workerDir],{cwd:backend,stdio:'pipe',timeout:60000,env:{...process.env,WRANGLER_SEND_METRICS:'false'}});
const scriptPath=path.join(workerDir,'legacy-import-worker.js');
const modules=[{type:'ESModule',path:scriptPath},...readdirSync(workerDir).filter(n=>n.endsWith('.wasm')).sort()
  .map(name=>({type:'CompiledWasm',path:path.join(workerDir,name)}))];
const project='biguess-t38-local';
const users=['owner','collector-a','collector-b'].map(uid=>({uid,email:`${uid}@fixture.test`,role:uid==='owner'?'owner_admin':'collector'}));
const pair=await generateKeyPair('RS256');
const jwk={...await exportJWK(pair.publicKey),kid:'t38-local-key',alg:'RS256',use:'sig'};
const tokens={};
for (const user of users) {
  const now=Math.floor(Date.now()/1000);
  tokens[user.uid]=await new SignJWT({sub:user.uid,email:user.email,email_verified:true,firebase:{sign_in_provider:'google.com'},
    aud:project,iss:`https://securetoken.google.com/${project}`,iat:now-10,auth_time:now-20,exp:now+3600})
    .setProtectedHeader({alg:'RS256',kid:jwk.kid}).sign(pair.privateKey);
}
const mf=new Miniflare(convertV4MiniflareOptions({modules,modulesRoot:workerDir,scriptPath,compatibilityDate:'2026-11-01',
  bindings:{APP_ENV:'local',FIREBASE_PROJECT_ID:project,STUDIO_USERS:JSON.stringify(users)},
  d1Databases:{DB:'t38-private-database'},r2Buckets:{CONTENT:'t38-private-images'},
  resourcePersistencePath:path.join(output,'state'),
  outboundService:request=>{
    assert.equal(request.url,'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com');
    return Response.json({keys:[jwk]});
  }}));
try {
  const db=await mf.getD1Database('DB');
  assert(existsSync(path.join(output,'state')),'Miniflare persistence was not created');
  await db.exec('CREATE TABLE IF NOT EXISTS local_legacy_migrations (name TEXT PRIMARY KEY, sha256 TEXT NOT NULL)');
  for (const name of readdirSync(path.join(backend,'migrations')).filter(n=>n.endsWith('.sql')).sort()) {
    const bytes=readFileSync(path.join(backend,'migrations',name)),digest=sha256(bytes);
    const applied=await db.prepare('SELECT sha256 FROM local_legacy_migrations WHERE name=?').bind(name).first();
    if (applied) assert.equal(applied.sha256,digest,`Changed migration: ${name}`);
    else {
      await db.exec(bytes.toString('utf8').split('\n').filter(line=>!line.trim().startsWith('--')).join(' '));
      await db.prepare('INSERT INTO local_legacy_migrations VALUES (?,?)').bind(name,digest).run();
    }
  }
  if (existsSync(path.join(output,'import-report.json')) || args.includes('--rollback')) {
    const durable=await db.prepare('SELECT import_id FROM studio_legacy_imports WHERE import_id=?').bind(bundle.importId).first();
    assert(durable,'Prior import evidence has no durable local database; use a fresh dedicated output rather than silently reconstructing it');
  }
  const request=(route,{actor='owner',method='GET',body}={})=>mf.dispatchFetch('https://local.test'+route,{method,
    headers:{...(actor?{Authorization:`Bearer ${tokens[actor]}`}:{}) ,...(body?{'Content-Type':'application/json'}:{})},
    ...(body?{body:JSON.stringify(body)}:{})});
  const checked=async(response,status=200)=>{assert.equal(response.status,status,await response.clone().text());return response.json();};
  if (args.includes('--rollback')) {
    const sourceBefore=readLegacyInventory(repoRoot);
    const bucket=await mf.getR2Bucket('CONTENT');
    const objectKeys=async()=>{const keys=[];let cursor;do {const page=await bucket.list({prefix:'objects/',...(cursor?{cursor}:{})});keys.push(...page.objects.map(o=>o.key));cursor=page.truncated?page.cursor:null;} while(cursor);return keys.sort();};
    const objectsBefore=await objectKeys();
    const evidenceBefore=(await db.prepare('SELECT resource_type,resource_id,record_json FROM studio_legacy_records WHERE import_id=? ORDER BY resource_type,resource_id').bind(bundle.importId).all()).results;
    const before=await db.prepare('SELECT state,COUNT(*) AS count FROM studio_entities GROUP BY state').all();
    const receipt=await checked(await request('/__legacy/rollback',{method:'POST',body:{importId:bundle.importId}}));
    const replay=await checked(await request('/__legacy/rollback',{method:'POST',body:{importId:bundle.importId}}));
    const after=await db.prepare('SELECT state,COUNT(*) AS count FROM studio_entities GROUP BY state').all();
    assert.equal(receipt.state,'rolled_back'); assert.equal(replay.replayed,true);
    const importedState=(await db.prepare('SELECT e.state,e.revision,COUNT(*) AS count FROM studio_entities e JOIN studio_legacy_records q ON q.resource_type=e.resource_type AND q.resource_id=e.id WHERE q.import_id=? GROUP BY e.state,e.revision').bind(bundle.importId).all()).results;
    assert.deepEqual(importedState,[{state:'deleted',revision:2,count:receipt.recordCount}]);
    const tombstones=(await db.prepare('SELECT COUNT(*) AS count FROM studio_tombstones t JOIN studio_legacy_records q ON q.resource_type=t.resource_type AND q.resource_id=t.resource_id WHERE q.import_id=? AND t.revision=2').bind(bundle.importId).first()).count;
    assert.equal(tombstones,receipt.recordCount);
    const sourceAfter=readLegacyInventory(repoRoot);
    assert.equal(canonical(sourceBefore),canonical(sourceAfter),'Rollback changed source files');
    assert.deepEqual(await objectKeys(),objectsBefore,'Rollback removed private objects');
    for (const record of new Map(bundle.records.filter(r=>r.resourceType==='card').map(r=>[r.imageReference,r])).values()) {
      const stored=await bucket.get(record.imageReference);
      assert(stored,'Rollback private image missing');
      assert.equal(sha256(Buffer.from(await stored.arrayBuffer())),record.preparedSha256,'Rollback private image checksum mismatch');
      assert.equal(stored.httpMetadata?.contentType,record.imageReference.endsWith('.png')?'image/png':'image/webp');
    }
    const evidenceAfter=(await db.prepare('SELECT resource_type,resource_id,record_json FROM studio_legacy_records WHERE import_id=? ORDER BY resource_type,resource_id').bind(bundle.importId).all()).results;
    assert.equal(canonical(evidenceBefore),canonical(evidenceAfter),'Rollback changed provenance');
    json('rollback-report.json',{protocolVersion:1,importId:bundle.importId,receipt,replay,before:before.results,after:after.results,importedState,tombstones,
      sourceFilesRetained:true,sourceCount:sourceAfter.records.length,provenanceRetained:true,provenanceRecords:evidenceAfter.length,
      privateObjectsRetained:true,privateObjectsValidated:true,privateObjectCount:objectsBefore.length,productionPublishing:false});
    console.log(JSON.stringify({rollback:receipt}));
  } else {
    const objects={};
    for (const record of bundle.records.filter(r=>r.resourceType==='card')) {
      if (objects[record.imageReference]) continue;
      const bytes=readFileSync(path.join(output,record.imageReference));
      assert.equal(sha256(bytes),record.preparedSha256); assert.equal(bytes.length,record.preparedBytes);
      objects[record.imageReference]=bytes.toString('base64');
    }
    const receipt=await checked(await request('/__legacy/import',{method:'POST',body:{...bundle,objects}}));
    const replay=await checked(await request('/__legacy/import',{method:'POST',body:{...bundle,objects}}));
    assert.equal(replay.replayed,true);
    if (receipt.state==='rolled_back') throw new Error('This import was rolled back; reimport never silently restores it. Use a separately reviewed recovery.');
    const before=readLegacyInventory(repoRoot);
    assert.equal(canonical(before),canonical(sourceAudit),'Originals changed during import');
    const scan=async actor=>{
      const rows=[];let cursor;let resume;
      do {
        const query=new URLSearchParams({limit:'100',...(cursor?{cursor}:{})});
        const page=await checked(await request('/studio/v1/sync/initial?'+query,{actor}));
        rows.push(...page.items);cursor=page.nextCursor;resume=page.resumeCursor;
      } while(cursor);
      return {rows,resume};
    };
    const owner=await scan('owner');
    assert.deepEqual(owner.rows.map(r=>r.id).sort(),bundle.records.map(r=>r.id).sort());
    assert(owner.rows.every(r=>r.state==='hidden'&&r.createdByUid===null));
    const collectors={};
    for (const uid of ['collector-a','collector-b']) {
      const data=await scan(uid); assert.deepEqual(data.rows,[]);
      const changes=await checked(await request('/studio/v1/sync/changes?'+new URLSearchParams({limit:'100',cursor:data.resume}),{actor:uid}));
      assert.deepEqual(changes.items,[]);
      const profile=await checked(await request('/studio/v1/profile',{actor:uid}));
      assert.equal(profile.counts.totalOperations,0);assert.deepEqual(profile.activity,[]);
      for (const record of bundle.records.filter(r=>r.resourceType!=='card')) {
        const collection=record.resourceType==='topic'?'topics':'packs';
        await checked(await request(`/studio/v1/${collection}/${encodeURIComponent(record.id)}`,{actor:uid}),404);
      }
      collectors[uid]={initialRecords:0,changes:0,contributions:0,guessedParentIds:'denied'};
    }
    const topics=await checked(await request('/content/v1/catalog/topics',{actor:null}));
    assert.deepEqual(topics.items,[]);
    const packs=bundle.records.filter(r=>r.resourceType==='pack');
    for (const pack of packs) {
      await checked(await request('/content/v1/packs/'+encodeURIComponent(pack.id)+'/download',{actor:null}),404);
      await checked(await request('/content/v1/packs/'+encodeURIComponent(pack.id)+'/revisions/1/manifest',{actor:null}),404);
      const catalog=await request('/content/v1/catalog/packs?'+new URLSearchParams({topicId:pack.parentId}),{actor:null});
      assert.equal(catalog.status,404);
    }
    const creators=(await db.prepare('SELECT source,created_by_uid,COUNT(*) AS count FROM studio_creators GROUP BY source,created_by_uid').all()).results;
    assert(creators.every(r=>r.source==='legacy'&&r.created_by_uid===null));
    const counts={};
    for (const table of ['catalog_topics','catalog_packs','publication_heads','publication_revisions','studio_rights_approvals','studio_publication_approvals','studio_release_requests','studio_audit']) {
      counts[table]=(await db.prepare(`SELECT COUNT(*) AS count FROM ${table}`).first()).count;
      assert.equal(counts[table],0,`Unexpected public/approval/contribution row: ${table}`);
    }
    const report={protocolVersion:1,importId:bundle.importId,inventorySha256:bundle.inventorySha256,workerSha256:bundle.workerSha256,
      browserVersion:preparation.browserVersion,sourceCount:sourceAudit.records.length,totals:sourceAudit.totals,
      topics:bundle.records.filter(r=>r.resourceType==='topic').length,packs:packs.length,cards:1174,
      preparedObjects:Object.keys(objects).length,receipt,replay,creators,collectors,publicRows:counts,
      sourceChecksumsUnchanged:true,excludedFixtures:sourceAudit.excludedFixtures,
      sourceSetSha256:sha256(Buffer.from(canonical(sourceAudit.records.map(r=>({path:r.source_path,sha256:r.sha256}))))),
      state:'quarantined',ownerControl:'owner_admin_only',productionPublishing:false};
    json(existsSync(path.join(output,'import-report.json'))?'repeat-report.json':'import-report.json',report);
    console.log(JSON.stringify({importId:bundle.importId,sourceCount:1174,recordCount:1183,objectCount:Object.keys(objects).length,
      state:'quarantined',ownerControl:'owner_admin_only',sourceChecksumsUnchanged:true,publicRows:counts}));
  }
} finally {await mf.dispose();}
