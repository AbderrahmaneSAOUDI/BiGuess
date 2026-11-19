// Local image preparation only. Files and pixel buffers never leave this origin.
(() => {
  'use strict';
  const scriptUrl = document.currentScript?.src || new URL('image_preparation.js', document.baseURI).href;
  const workerUrl = new URL('image_preparation_worker.js', scriptUrl).href;
  let active = 0;
  const capabilities = () => ({worker: typeof Worker === 'function', crypto: !!globalThis.crypto?.subtle,
    supported: typeof Worker === 'function' && !!globalThis.crypto?.subtle});
  function prepare(file, {onProgress, signal, maxEdge = 1024, forcePng = false} = {}) {
    return new Promise((resolve, reject) => {
      if (signal?.aborted) { reject(new DOMException('Image preparation cancelled.', 'AbortError')); return; }
      if (!capabilities().supported) { reject(Object.assign(new Error('This browser cannot prepare images securely. Use a browser with Worker and Web Crypto support.'), {code: 'unsupported-browser'})); return; }
      if (!(file instanceof Blob)) { reject(Object.assign(new Error('Choose an image file.'), {code: 'invalid-input'})); return; }
      if (active !== 0) { reject(Object.assign(new Error('Another image is being prepared. Process selected files sequentially.'), {code: 'busy'})); return; }
      if (!Number.isInteger(maxEdge) || maxEdge < 64 || maxEdge > 1024) { reject(Object.assign(new Error('Invalid image size limit.'), {code: 'invalid-input'})); return; }
      let worker;
      let done = false;
      let timer;
      const finish = (value, error) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
        worker?.terminate();
        active--;
        if (error) reject(error); else resolve(value);
      };
      const abort = () => finish(null, new DOMException('Image preparation cancelled.', 'AbortError'));
      active++;
      try {
        worker = new Worker(workerUrl);
        signal?.addEventListener('abort', abort, {once: true});
        // A stalled decoder cannot retain an unbounded in-flight job.
        timer = setTimeout(() => finish(null, Object.assign(new Error('Image preparation timed out. Try a smaller image.'), {code: 'timeout'})), 30000);
        worker.onmessage = ({data}) => {
          if (done) return;
          if (data.progress) { try { onProgress?.(data.progress); } catch (_) { /* Observers cannot retain worker resources. */ } }
          else if (data.error) finish(null, Object.assign(new Error(data.error.message), {code: data.error.code}));
          else if (data.result) finish(data.result);
        };
        worker.onerror = event => { event.preventDefault(); finish(null, Object.assign(new Error('This browser could not start image preparation. Check available memory and browser support.'), {code: 'worker-failed'})); };
        worker.postMessage({file, filename: file.name || 'image', maxEdge, forcePng: forcePng === true});
      } catch (_) {
        finish(null, Object.assign(new Error('This browser could not allocate image preparation resources.'), {code: 'memory-or-capability'}));
      }
    });
  }
  globalThis.biguessImages = Object.freeze({prepare, capabilities});
})();
