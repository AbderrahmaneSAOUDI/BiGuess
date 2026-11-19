// Real Chromium/Worker/Canvas acceptance, isolated from Firebase and content API.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root=path.resolve(__dirname,'../web');
const server=http.createServer((req,res)=>{
  const pathname=new URL(req.url,'http://localhost').pathname;
  if(pathname==='/') return res.end('<!doctype html><script src="/image_preparation.js"></script>');
  if(!['/image_preparation.js','/image_preparation_worker.js'].includes(pathname)) return res.writeHead(404).end();
  res.setHeader('Content-Type','application/javascript'); res.setHeader('Cache-Control','no-store');
  fs.createReadStream(path.join(root,pathname)).pipe(res);
});
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const browser=await chromium.launch({args:['--no-sandbox']});
  try {
    const page=await browser.newPage();
    const errors=[];page.on('pageerror',e=>errors.push(String(e)));
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    const results=await page.evaluate(async()=>{
      const assert=(condition,message)=>{if(!condition)throw Error(message);};
      async function source(mime,width=30,height=20,alpha=false) {
        const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;
        const c=canvas.getContext('2d'); c.fillStyle=alpha?'rgba(120,35,200,.4)':'rgb(120,35,200)';c.fillRect(0,0,width,height);
        const blob=await new Promise(resolve=>canvas.toBlob(resolve,mime,.9));
        return new File([blob],`Grace_Hopper.${mime.split('/')[1]}`,{type:blob.type});
      }
      const failures=[];
      async function reject(file,code,opts) {
        try {await biguessImages.prepare(file,opts);throw Error('unexpected acceptance');}
        catch(e){assert(e.code===code,`expected ${code}, got ${e.code}: ${e.message}`);failures.push(code);}
      }
      const outputs=[];
      for(const mime of ['image/jpeg','image/png','image/webp']) {
        const file=await source(mime,2000,1000,mime!=='image/jpeg');
        const phases=[];
        const output=await biguessImages.prepare(file,{onProgress:value=>phases.push(value.stage)});
        assert(output.width===1024&&output.height===512,'bounded resize dimensions');
        assert(output.mimeType==='image/webp','Chromium WebP encoding');
        assert(output.sha256.length===64,'sha256');
        assert(output.suggestedName==='Grace Hopper','name suggestion');
        assert(output.filename==='Grace Hopper.webp','output filename matches bytes');
        assert(phases.join(',')==='reading,decoding,resizing,encoding,validating,hashing,complete','progress stages');
        const decoded=await createImageBitmap(new Blob([output.bytes],{type:output.mimeType}));
        const canvas=new OffscreenCanvas(decoded.width,decoded.height),c=canvas.getContext('2d');c.drawImage(decoded,0,0);decoded.close();
        const alpha=c.getImageData(0,0,1,1).data[3];
        assert(mime==='image/jpeg'?alpha===255:alpha>90&&alpha<115,'transparency retained');
        outputs.push({mime,size:output.bytes.byteLength,width:output.width,height:output.height});
      }
      const marker='PRIVATE_AUTHOR_EXIF_XMP_9831';
      const concat=(...arrays)=>{const out=new Uint8Array(arrays.reduce((n,a)=>n+a.length,0));let p=0;for(const a of arrays){out.set(a,p);p+=a.length;}return out;};
      const ascii=value=>new TextEncoder().encode(value);
      const crc=bytes=>{let c=0xffffffff;for(const b of bytes){c^=b;for(let i=0;i<8;i++)c=(c&1)?0xedb88320^(c>>>1):c>>>1;}return(c^0xffffffff)>>>0;};
      const be=value=>new Uint8Array([value>>>24,value>>>16&255,value>>>8&255,value&255]);
      const pngSource=new Uint8Array(await (await source('image/png')).arrayBuffer());
      const payload=ascii('Author\0'+marker),kind=ascii('tEXt'),body=concat(kind,payload);
      const metadataPng=concat(pngSource.slice(0,33),be(payload.length),body,be(crc(body)),pngSource.slice(33));
      const jpgSource=new Uint8Array(await (await source('image/jpeg')).arrayBuffer());
      const exif=ascii('Exif\0\0'+marker),len=exif.length+2;
      const metadataJpeg=concat(jpgSource.slice(0,2),new Uint8Array([255,225,len>>8,len&255]),exif,jpgSource.slice(2));
      const webpSource=new Uint8Array(await (await source('image/webp')).arrayBuffer());
      const exifWebp=ascii(marker),le=value=>new Uint8Array([value&255,value>>>8&255,value>>>16&255,value>>>24]);
      const extra=concat(ascii('EXIF'),le(exifWebp.length),exifWebp,exifWebp.length%2?new Uint8Array(1):new Uint8Array(0));
      const metadataWebp=concat(webpSource,extra);metadataWebp.set(le(metadataWebp.length-8),4);
      for(const [bytes,mime] of [[metadataPng,'image/png'],[metadataJpeg,'image/jpeg'],[metadataWebp,'image/webp']]) {
        const result=await biguessImages.prepare(new File([bytes],'private.'+mime.split('/')[1],{type:mime}));
        assert(!new TextDecoder().decode(result.bytes).includes(marker),'input metadata stripped '+mime);
      }
      const noise=document.createElement('canvas');noise.width=1024;noise.height=1024;
      const nc=noise.getContext('2d'),pixels=nc.createImageData(1024,1024);let random=123;
      for(let i=0;i<pixels.data.length;i+=4){for(let j=0;j<3;j++){random=(Math.imul(random,1664525)+1013904223)>>>0;pixels.data[i+j]=random>>>24;}pixels.data[i+3]=255;}nc.putImageData(pixels,0,0);
      const noiseBlob=await new Promise(resolve=>noise.toBlob(resolve,'image/png'));
      const quality=await biguessImages.prepare(new File([noiseBlob],'quality.png',{type:'image/png'}));
      assert(quality.bytes.byteLength>50*1024&&quality.warnings.some(w=>w.includes('50 KiB')),'quality target warns without rejecting');
      const tiny=await source('image/png',3,2,true);
      const png=await biguessImages.prepare(tiny,{forcePng:true});
      assert(png.mimeType==='image/png'&&png.width===3&&png.height===2,'PNG fallback/no upscaling');
      const duplicate=await biguessImages.prepare(tiny,{forcePng:true});
      assert(duplicate.sha256===png.sha256,'duplicate normalized content hash');
      const named=await biguessImages.prepare(new File([tiny],'folder/  Ada__Lovelace-\u202e test.png',{type:'image/png'}));
      assert(named.suggestedName==='Ada Lovelace test'&&!named.filename.includes('/'),'safe Unicode candidate naming');
      await reject(new File(['not an image'],'broken.png',{type:'image/png'}),'unsupported-format');
      const damaged=new Uint8Array(await tiny.arrayBuffer());damaged[damaged.length-1]^=1;
      await reject(new File([damaged],'broken.png',{type:'image/png'}),'corrupt-image');
      const jpeg=await source('image/jpeg');const truncated=new Uint8Array(await jpeg.arrayBuffer()).slice(0,-2);
      await reject(new File([truncated],'broken.jpg',{type:'image/jpeg'}),'corrupt-image');
      await reject(new File([tiny],'mismatch.jpg',{type:'image/jpeg'}),'invalid-format');
      await reject(new File([new Uint8Array(20*1024*1024+1)],'large.png',{type:'image/png'}),'image-too-large');
      const huge=await source('image/png',5000,4000);
      await reject(huge,'image-too-large');
      const controller=new AbortController();controller.abort();
      try {await biguessImages.prepare(tiny,{signal:controller.signal});throw Error('aborted accepted');}catch(e){assert(e.name==='AbortError','pre-cancel');}
      const live=new AbortController();
      let liveCancelled=false;
      try {await biguessImages.prepare(huge,{signal:live.signal,onProgress:()=>live.abort()});}catch(e){liveCancelled=e.name==='AbortError';}
      assert(liveCancelled,'in-flight cancellation');
      // Hundreds of selected references remain lightweight; only one worker/pixel
      // job exists at a time and timers continue running throughout the batch.
      let ticks=0;const timer=setInterval(()=>ticks++,0);
      let complete=0;
      for(let i=0;i<120;i++) {const output=await biguessImages.prepare(tiny);assert(output.sha256.length===64,'batch output validated');complete++;}
      clearInterval(timer);assert(ticks>20,'event loop remains responsive');
      const inFlight=biguessImages.prepare(tiny);
      await reject(tiny,'busy');await inFlight;
      return {outputs,failures,batch:complete,ticks};
    });
    // Alter only worker capability surfaces in a fresh test context; production
    // code has no test bypass bindings or network capability switches.
    const workerSource=fs.readFileSync(path.join(root,'image_preparation_worker.js'),'utf8');
    for(const [name,prefix,expected] of [
      ['no decoder','self.createImageBitmap=undefined;','unsupported-browser'],
      ['no canvas','self.OffscreenCanvas=undefined;','unsupported-browser'],
      ['decoder quota failure',`self.createImageBitmap=async()=>{throw new DOMException('quota','QuotaExceededError');};`,'quota-exceeded'],
      ['decoder memory failure',`self.createImageBitmap=async()=>{throw new RangeError('allocation');};`,'memory-limit'],
      ['quota failure',`OffscreenCanvas.prototype.convertToBlob=async()=>{throw new DOMException('quota','QuotaExceededError');};`,'quota-exceeded'],
      ['memory failure',`OffscreenCanvas.prototype.getContext=function(){throw new RangeError('allocation');};`,'memory-limit'],
      ['WebP fallback',`const original=OffscreenCanvas.prototype.convertToBlob;OffscreenCanvas.prototype.convertToBlob=function(options){return original.call(this,{...options,type:'image/png'});};`,null],
      ['invalid output',`OffscreenCanvas.prototype.convertToBlob=async()=>new Blob(['bad'],{type:'image/webp'});`,'invalid-output'],
    ]) {
      await page.route('**/image_preparation_worker.js',route=>route.fulfill({contentType:'application/javascript',body:prefix+'\n'+workerSource}));
      const value=await page.evaluate(async()=>{
        const c=document.createElement('canvas');c.width=3;c.height=2;
        const b=await new Promise(resolve=>c.toBlob(resolve,'image/png'));
        try {const r=await biguessImages.prepare(new File([b],'x.png',{type:'image/png'}));return {mime:r.mimeType,warnings:r.warnings};}
        catch(e){return {error:e.code};}
      });
      if(expected)assert.equal(value.error,expected,name);else {assert.equal(value.mime,'image/png');assert(value.warnings.some(w=>w.includes('WebP')));}
      await page.unroute('**/image_preparation_worker.js');
    }
    assert.deepEqual(errors,[]);
    console.log('T32 image Chromium PASS: '+JSON.stringify(results)+'; supported formats/transparency, corruption, bounds, normalized names/hash duplicates, 120-file sequential responsiveness, cancellation and unsupported capabilities/output covered.');
  } finally {await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1;});
