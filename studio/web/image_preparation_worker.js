/* One bounded job per worker. Cancellation terminates this worker and its pixel buffers. */
'use strict';
const MAX_INPUT = 20 * 1024 * 1024;
const MAX_PIXELS = 16 * 1024 * 1024;
const MAX_OUTPUT = 5 * 1024 * 1024;
const fail = (code, message) => { throw Object.assign(new Error(message), {code}); };
const isResourceFailure = error => error instanceof RangeError || error?.name === 'QuotaExceededError';
const progress = (stage, value) => postMessage({progress: {stage, progress: value, fraction: value}});
const u32be = (b, p) => (b[p] * 0x1000000 + (b[p+1] << 16) + (b[p+2] << 8) + b[p+3]) >>> 0;
const u32le = (b, p) => (b[p] + (b[p+1] << 8) + (b[p+2] << 16) + b[p+3] * 0x1000000) >>> 0;
const text = (b, p, n) => String.fromCharCode(...b.subarray(p, p+n));
let crcTable;
function crc32(bytes, start, end) {
  crcTable ||= Array.from({length:256}, (_, i) => { let v=i; for(let j=0;j<8;j++) v=(v&1) ? 0xedb88320^(v>>>1) : v>>>1; return v>>>0; });
  let crc=0xffffffff;
  for(let i=start;i<end;i++) crc=crcTable[(crc^bytes[i])&255]^(crc>>>8);
  return (crc^0xffffffff)>>>0;
}
function inspect(b) {
  let mimeType, width, height;
  // Every container and frame declaration must fit before a native decoder runs.
  const dimensions=(w,h)=>{
    if(!Number.isInteger(w)||!Number.isInteger(h)||w<1||h<1) fail('corrupt-image','The image dimensions are invalid.');
    if(w*h>MAX_PIXELS||w>16384||h>16384) fail('image-too-large','The image exceeds the safe decode limit of 16 megapixels. Resize it before selecting it.');
    if(width!==undefined&&(width!==w||height!==h)) fail('corrupt-image','The image has conflicting frame dimensions.');
    width=w;height=h;
  };
  if (b.length >= 8 && [137,80,78,71,13,10,26,10].every((v,i) => b[i]===v)) {
    mimeType='image/png'; let p=8, first=true, ended=false, hasData=false;
    while(p+12<=b.length) {
      const length=u32be(b,p), kind=text(b,p+4,4);
      if(length>b.length-p-12 || crc32(b,p+4,p+8+length)!==u32be(b,p+8+length)) fail('corrupt-image','The PNG is truncated or has damaged data.');
      if(first) { if(kind!=='IHDR'||length!==13) fail('corrupt-image','The PNG header is invalid.'); dimensions(u32be(b,p+8),u32be(b,p+12)); first=false; }
      else if(kind==='IHDR') fail('corrupt-image','The PNG contains duplicate image headers.');
      if(kind==='acTL') fail('unsupported-format','Animated images are not supported. Select a still image.');
      if(kind==='IDAT') hasData=true;
      p+=length+12;
      if(kind==='IEND') { if(length!==0||p!==b.length||!hasData) fail('corrupt-image','The PNG ending is invalid.'); ended=true; break; }
    }
    if(!ended) fail('corrupt-image','The PNG is incomplete.');
  } else if(b.length>=4 && b[0]===255 && b[1]===216) {
    mimeType='image/jpeg';
    if(b[b.length-2]!==255 || b[b.length-1]!==217) fail('corrupt-image','The JPEG is incomplete.');
    let p=2, entropy=false, ended=false, scans=0;
    while(p<b.length) {
      let marker;
      if(entropy) {
        while(p<b.length) {
          if(b[p++]!==255) continue;
          while(b[p]===255) p++;
          if(p>=b.length) fail('corrupt-image','The JPEG scan is truncated.');
          marker=b[p++];
          if(marker===0||marker>=0xd0&&marker<=0xd7) continue;
          entropy=false;break;
        }
      } else {
        if(b[p++]!==255) fail('corrupt-image','The JPEG header is invalid.');
        while(b[p]===255) p++;
        marker=b[p++];
      }
      if(marker===undefined) break;
      if(marker===0xd9) { if(p!==b.length) fail('corrupt-image','The JPEG has trailing image data.');ended=true;break; }
      if(marker===1) continue;
      if(marker===0xd8||marker===0||marker>=0xd0&&marker<=0xd7) fail('corrupt-image','The JPEG marker sequence is invalid.');
      if(p+2>b.length) fail('corrupt-image','The JPEG header is truncated.');
      const size=(b[p]<<8)|b[p+1];
      if(size<2||p+size>b.length) fail('corrupt-image','The JPEG header is truncated.');
      if([0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf].includes(marker)) {
        if(size<8) fail('corrupt-image','The JPEG frame is invalid.');
        dimensions((b[p+5]<<8)|b[p+6],(b[p+3]<<8)|b[p+4]);
      }
      p+=size;
      if(marker===0xda) { entropy=true;scans++; }
    }
    if(!ended||scans===0) fail('corrupt-image','The JPEG scan is incomplete.');
  } else if(b.length>=20 && text(b,0,4)==='RIFF' && text(b,8,4)==='WEBP') {
    mimeType='image/webp';
    if(u32le(b,4)+8!==b.length) fail('corrupt-image','The WebP container is incomplete.');
    let p=12, hasFrame=false, hasExtended=false;
    while(p+8<=b.length) {
      const kind=text(b,p,4), size=u32le(b,p+4), q=p+8;
      if(size>b.length-q) fail('corrupt-image','The WebP data is truncated.');
      if(kind==='VP8X') {
        if(size!==10||hasExtended) fail('corrupt-image','The WebP header is invalid.');
        hasExtended=true;
        if(b[q]&2) fail('unsupported-format','Animated images are not supported. Select a still image.');
        dimensions(1+b[q+4]+(b[q+5]<<8)+(b[q+6]<<16),1+b[q+7]+(b[q+8]<<8)+(b[q+9]<<16));
      } else if(kind==='VP8 ') {
        if(size<10 || b[q+3]!==0x9d || b[q+4]!==1 || b[q+5]!==0x2a) fail('corrupt-image','The WebP frame is invalid.');
        if(hasFrame) fail('corrupt-image','The WebP contains multiple still frames.');
        dimensions((b[q+6]|b[q+7]<<8)&0x3fff,(b[q+8]|b[q+9]<<8)&0x3fff);hasFrame=true;
      } else if(kind==='VP8L') {
        if(size<5 || b[q]!==0x2f) fail('corrupt-image','The WebP frame is invalid.');
        if(hasFrame) fail('corrupt-image','The WebP contains multiple still frames.');
        dimensions(1+((b[q+1]|b[q+2]<<8)&0x3fff),1+((b[q+2]>>6|b[q+3]<<2|b[q+4]<<10)&0x3fff));hasFrame=true;
      } else if(kind==='ANIM' || kind==='ANMF') fail('unsupported-format','Animated images are not supported. Select a still image.');
      p=q+size+(size&1);
    }
    if(p!==b.length || !hasFrame) fail('corrupt-image','The WebP frame is incomplete.');
  } else fail('unsupported-format','Select a JPEG, PNG or WebP image.');
  if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1) fail('corrupt-image','The image dimensions are invalid.');
  if(width*height>MAX_PIXELS || width>16384 || height>16384) fail('image-too-large','The image exceeds the safe decode limit of 16 megapixels. Resize it before selecting it.');
  return {mimeType,width,height};
}
function names(filename, mime) {
  const leaf=String(filename).split(/[\\/]/).pop().normalize('NFC');
  const stem=leaf.replace(/\.[^.]*$/, '').replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g,'').replace(/[_-]+/g,' ').replace(/\s+/g,' ').trim();
  const suggestedName=Array.from(stem || 'Untitled image').slice(0,160).join('');
  return {suggestedName,filename:`${suggestedName}.${mime==='image/webp'?'webp':'png'}`};
}
self.onmessage=async ({data}) => {
  let bitmap, canvas, check;
  try {
    const {file,filename,maxEdge,forcePng}=data;
    if(!(file instanceof Blob)||file.size<1) fail('invalid-input','Choose a nonempty image file.');
    if(file.size>MAX_INPUT) fail('image-too-large','Select an image no larger than 20 MiB.');
    if(typeof createImageBitmap!=='function'||typeof OffscreenCanvas!=='function'||!self.crypto?.subtle) fail('unsupported-browser','This browser lacks the image decoder, offscreen canvas or hashing needed for safe preparation.');
    progress('reading',0.05);
    const input=new Uint8Array(await file.arrayBuffer());
    const header=inspect(input);
    if(file.type && !['image/jpeg','image/png','image/webp'].includes(file.type)) fail('unsupported-format','The selected file type is unsupported.');
    if(file.type && file.type!==header.mimeType) fail('invalid-format','The image bytes do not match the selected file type.');
    progress('decoding',0.2);
    try { bitmap=await createImageBitmap(new Blob([input],{type:header.mimeType}),{imageOrientation:'from-image'}); }
    catch (error) { if(isResourceFailure(error)) throw error; fail('corrupt-image','The browser could not decode this image. It may be damaged or unsupported.'); }
    if(bitmap.width*bitmap.height>MAX_PIXELS || bitmap.width<1||bitmap.height<1) fail('image-too-large','The decoded image exceeds the safe memory limit.');
    const scale=Math.min(1,maxEdge/Math.max(bitmap.width,bitmap.height));
    const width=Math.max(1,Math.round(bitmap.width*scale)), height=Math.max(1,Math.round(bitmap.height*scale));
    canvas=new OffscreenCanvas(width,height);
    const context=canvas.getContext('2d',{alpha:true});
    if(!context) fail('unsupported-browser','The browser could not allocate an image canvas.');
    progress('resizing',0.4);
    context.drawImage(bitmap,0,0,width,height); bitmap.close(); bitmap=null;
    progress('encoding',0.6);
    const warnings=[];
    let output;
    try { output=await canvas.convertToBlob({type:forcePng?'image/png':'image/webp',quality:0.84}); }
    catch (_) { if(forcePng) throw _; }
    if(!output || !['image/webp','image/png'].includes(output.type)) {
      output=await canvas.convertToBlob({type:'image/png'}); warnings.push('WebP encoding is unavailable; PNG was retained to preserve image quality and transparency.');
    } else if(!forcePng && output.type!=='image/webp') warnings.push('WebP encoding is unavailable; PNG was retained to preserve image quality and transparency.');
    canvas.width=1; canvas.height=1; canvas=null;
    if(!output || !['image/webp','image/png'].includes(output.type)||output.size<1) fail('unsupported-browser','The browser did not produce a supported image format.');
    if(output.size>MAX_OUTPUT) fail('output-too-large','The prepared image exceeds the 5 MiB local attachment safety limit.');
    progress('validating',0.8);
    const bytes=await output.arrayBuffer();
    let encoded;
    try { encoded=inspect(new Uint8Array(bytes)); } catch (_) { fail('invalid-output','The browser produced damaged or unsupported image bytes.'); }
    if(encoded.mimeType!==output.type || encoded.width!==width||encoded.height!==height) fail('invalid-output','The browser produced inconsistent image bytes.');
    try { check=await createImageBitmap(output); } catch (error) { if(isResourceFailure(error)) throw error; fail('invalid-output','The prepared image could not be decoded.'); }
    if(check.width!==width||check.height!==height) fail('invalid-output','The prepared image has unexpected dimensions.');
    check.close(); check=null;
    progress('hashing',0.9);
    const digest=await crypto.subtle.digest('SHA-256',bytes);
    const sha256=Array.from(new Uint8Array(digest), v=>v.toString(16).padStart(2,'0')).join('');
    if(output.size>50*1024) warnings.push('This image exceeds the approximate 50 KiB quality target; it remains valid.');
    progress('complete',1);
    postMessage({result:{bytes,mimeType:output.type,width,height,sha256,warnings,...names(filename,output.type)}},[bytes]);
  } catch(error) {
    const resourceCode=error.name==='QuotaExceededError'?'quota-exceeded':error instanceof RangeError?'memory-limit':null;
    const explicitCode=typeof error.code==='string'?error.code:null;
    postMessage({error:{code:explicitCode||resourceCode||'preparation-failed',message:explicitCode?error.message:resourceCode?'The browser ran out of image preparation resources. Free memory or site storage and retry.':'The browser could not prepare this image. Check available memory or choose another image.'}});
  } finally {
    bitmap?.close(); check?.close();
    if(canvas) { canvas.width=1; canvas.height=1; }
    self.close();
  }
};
