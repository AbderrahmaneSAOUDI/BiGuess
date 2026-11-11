// Private, local T38 preparation. Image transforms run only in the unchanged T32
// browser Worker; Node verifies source/output bytes and writes derived objects.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const {createHash} = require('node:crypto');
const {chromium} = require('playwright');
const MAX_INPUT = 20 * 1024 * 1024;
const MAX_OUTPUT = 5 * 1024 * 1024;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const inside = (parent, child) => child === parent || child.startsWith(parent + path.sep);
const cancelled = () => Object.assign(new Error('Legacy preparation cancelled.'), {code:'cancelled'});
function checkSignal(signal) { if (signal?.aborted) throw cancelled(); }
function sourceBytes(source) {
  if (fs.realpathSync(source.filename) !== source.filename) throw new Error('Source symlinks are not permitted.');
  const descriptor = fs.openSync(source.filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile() || stat.size < 1 || stat.size > MAX_INPUT || stat.size !== source.record.size_bytes) {
      throw new Error(`Invalid source size: ${source.record.source_path}`);
    }
    const bytes = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < bytes.length) {
      const count = fs.readSync(descriptor, bytes, offset, bytes.length-offset, offset);
      if (count === 0) throw new Error('Source changed during read.');
      offset += count;
    }
    if (fs.fstatSync(descriptor).size !== stat.size || digest(bytes) !== source.record.sha256) {
      throw new Error(`Source checksum mismatch: ${source.record.source_path}`);
    }
    return bytes;
  } finally { fs.closeSync(descriptor); }
}

async function prepareLegacyImages({repoRoot, records, outputDir, onProgress,
  chromeExecutable = process.env.CHROME_EXECUTABLE, signal} = {}) {
  checkSignal(signal);
  const root = fs.realpathSync(path.resolve(repoRoot));
  const destination = path.resolve(outputDir);
  // Derived legacy images must never become Flutter/static-site bundle inputs.
  if (inside(root,destination)) throw new Error('Private outputDir must be outside the repository.');
  if (!Array.isArray(records) || records.length < 1 || records.length > 2000) throw new Error('Prepare 1–2000 source records sequentially.');
  const seen = new Set();
  const sources = records.map(record => {
    if (!record || typeof record.source_path !== 'string' || !record.source_path.startsWith('assets/images/') ||
      !/^[a-f0-9]{64}$/.test(record.sha256) || !Number.isInteger(record.size_bytes) ||
      record.size_bytes < 1 || record.size_bytes > MAX_INPUT || typeof record.file_name !== 'string' ||
      !record.file_name || seen.has(record.source_path)) throw new Error('Invalid or duplicate source record.');
    seen.add(record.source_path);
    const filename = path.resolve(root,record.source_path);
    if (!inside(path.join(root,'assets/images'),filename) || fs.realpathSync(filename) !== filename ||
        path.basename(filename) !== record.file_name) throw new Error('Source path is outside the exact inventory.');
    return {record,filename};
  });
  // Hash every source before browser startup. A changed source is never silently
  // accepted; it is verified again when served and inside the browser.
  for (const source of sources) { checkSignal(signal); sourceBytes(source); }
  fs.mkdirSync(destination,{recursive:true});
  const realDestination = fs.realpathSync(destination);
  if (inside(root,realDestination)) throw new Error('Private outputDir resolves into the repository.');
  const objectDirectory = path.join(realDestination,'objects');
  fs.mkdirSync(objectDirectory,{recursive:true});
  if (fs.lstatSync(objectDirectory).isSymbolicLink() || fs.realpathSync(objectDirectory) !== objectDirectory) throw new Error('Object directory symlinks are not permitted.');
  const workerBytes = fs.readFileSync(path.join(root,'studio/web/image_preparation_worker.js'));
  const workerSha256 = digest(workerBytes);
  const server = http.createServer((req,res) => {
    res.setHeader('Cache-Control','no-store');
    res.setHeader('X-Content-Type-Options','nosniff');
    if (req.method !== 'GET') return res.writeHead(405).end();
    const url = new URL(req.url,'http://127.0.0.1');
    if (url.search) return res.writeHead(404).end();
    if (url.pathname === '/') {
      res.setHeader('Content-Type','text/html');
      return res.end('<!doctype html><title>Private legacy image preparation</title>');
    }
    if (url.pathname === '/image_preparation_worker.js') {
      res.setHeader('Content-Type','application/javascript'); return res.end(workerBytes);
    }
    const match = /^\/source\/([0-9]+)$/.exec(url.pathname);
    if (!match || !sources[Number(match[1])]) return res.writeHead(404).end();
    try {
      const source = sources[Number(match[1])];
      const mime = {'.webp':'image/webp','.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg'}[path.extname(source.filename).toLowerCase()];
      if (!mime) throw new Error('Unsupported source encoding.');
      const bytes = sourceBytes(source);
      res.setHeader('Content-Type',mime); res.end(bytes);
    } catch (_) { res.writeHead(409).end('Source no longer matches the inventory.'); }
  });
  let browser;
  const abort = () => { void browser?.close(); server.close(); };
  signal?.addEventListener('abort',abort,{once:true});
  try {
    await new Promise((resolve,reject) => { server.once('error',reject); server.listen(0,'127.0.0.1',resolve); });
    checkSignal(signal);
    const origin = `http://127.0.0.1:${server.address().port}`;
    browser = await chromium.launch({...(chromeExecutable ? {executablePath:chromeExecutable} : {}),args:['--no-sandbox','--disable-dev-shm-usage']});
    checkSignal(signal);
    const browserVersion = browser.version();
    const page = await browser.newPage();
    // This local tool has no reason to contact a third-party origin.
    await page.route('**/*',route => route.request().url().startsWith(origin + '/') ? route.continue() : route.abort());
    await page.goto(origin,{waitUntil:'domcontentloaded',timeout:30000});
    const prepared = [];
    for (let index=0;index<sources.length;index++) {
      checkSignal(signal);
      const {record} = sources[index];
      const result = await page.evaluate(async ({index,expectedHash,expectedBytes,filename}) => {
        const response = await fetch(`/source/${index}`,{cache:'no-store'});
        if (!response.ok) throw new Error('Source no longer matches the inventory.');
        const blob = await response.blob();
        if (blob.size !== expectedBytes) throw new Error('Source size mismatch.');
        const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',await blob.arrayBuffer())),b=>b.toString(16).padStart(2,'0')).join('');
        if (hash !== expectedHash) throw new Error('Source checksum mismatch.');
        const outcome = await new Promise((resolve,reject) => {
          const worker = new Worker('/image_preparation_worker.js');
          const finish = (value,error) => { clearTimeout(timer); worker.terminate(); error ? reject(error) : resolve(value); };
          const timer = setTimeout(()=>finish(null,new Error('T32 worker timed out after 30 seconds.')),30000);
          worker.onerror = () => finish(null,new Error('T32 worker crashed.'));
          worker.onmessage = ({data}) => {
            if (data.error) finish(null,new Error(`${data.error.code}: ${data.error.message}`));
            else if (data.result) finish(data.result);
          };
          worker.postMessage({file:blob,filename,maxEdge:1024,forcePng:false});
        });
        const bytes = new Uint8Array(outcome.bytes);
        if (bytes.length < 1 || bytes.length > 5*1024*1024) throw new Error('Prepared output exceeds bounds.');
        const outputHash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
        if (outputHash !== outcome.sha256) throw new Error('Prepared output checksum mismatch.');
        // Bounded per-image bridge; no collection of decoded/encoded images is
        // retained in the page or worker between iterations.
        let binary='';
        for (let start=0;start<bytes.length;start+=32768) binary+=String.fromCharCode(...bytes.subarray(start,start+32768));
        return {base64:btoa(binary),sha256:outcome.sha256,mimeType:outcome.mimeType,width:outcome.width,height:outcome.height};
      },{index,expectedHash:record.sha256,expectedBytes:record.size_bytes,filename:record.file_name});
      checkSignal(signal);
      const bytes = Buffer.from(result.base64,'base64');
      if (bytes.length < 1 || bytes.length > MAX_OUTPUT || digest(bytes) !== result.sha256 ||
        !['image/webp','image/png'].includes(result.mimeType) || !Number.isInteger(result.width) ||
        !Number.isInteger(result.height) || result.width < 1 || result.height < 1 || result.width > 1024 || result.height > 1024) throw new Error('Invalid prepared result.');
      const objectReference = `objects/${result.sha256}.${result.mimeType === 'image/webp'?'webp':'png'}`;
      const output = path.join(realDestination,objectReference);
      try { fs.writeFileSync(output,bytes,{flag:'wx',mode:0o600}); }
      catch (error) {
        if (error.code !== 'EEXIST' || !fs.lstatSync(output).isFile() || fs.lstatSync(output).isSymbolicLink() || !fs.readFileSync(output).equals(bytes)) throw error;
      }
      prepared.push({sourcePath:record.source_path,sourceSha256:record.sha256,sha256:result.sha256,
        mimeType:result.mimeType,width:result.width,height:result.height,sizeBytes:bytes.length,objectReference});
      onProgress?.({completed:index+1,total:sources.length,sourcePath:record.source_path});
    }
    // A source modified during the complete run invalidates the whole plan.
    for (const source of sources) { checkSignal(signal); sourceBytes(source); }
    return {prepared,workerSha256,browserVersion};
  } catch (error) {
    if (signal?.aborted) throw cancelled();
    throw error;
  } finally {
    signal?.removeEventListener('abort',abort);
    await browser?.close();
    server.closeAllConnections();
    await new Promise(resolve=>server.close(resolve));
  }
}
module.exports = {prepareLegacyImages};
