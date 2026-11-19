import decodePng, { init as initPng } from '@jsquash/png/decode.js';
import decodeWebp, { init as initWebp } from '@jsquash/webp/decode.js';
// Wrangler's Wasm import is a precompiled Module; upstream's .wasm.d.ts instead
// describes instance exports. The pinned build + Workerd tests verify this ABI.
// @ts-expect-error upstream declaration is for the instantiated Wasm exports
import pngModule from '@jsquash/png/codec/pkg/squoosh_png_bg.wasm';
import webpModule from '@jsquash/webp/codec/dec/webp_dec.wasm';

export class ImageValidationError extends Error {}
const invalid = (): never => { throw new ImageValidationError('Invalid prepared image.'); };
const u32 = (b: Uint8Array, p: number, little = false): number =>
  new DataView(b.buffer, b.byteOffset, b.byteLength).getUint32(p, little);
const ascii = (b: Uint8Array, p: number) => String.fromCharCode(...b.subarray(p, p + 4));
let crcTable: number[] | undefined;
let webpReady: Promise<void> | undefined;
function crc(b: Uint8Array, start: number, end: number): number {
  crcTable ??= Array.from({ length: 256 }, (_, i) => {
    let v = i; for (let j = 0; j < 8; j++) v = v & 1 ? 0xedb88320 ^ (v >>> 1) : v >>> 1;
    return v >>> 0;
  });
  let result = 0xffffffff;
  for (let i = start; i < end; i++) result = crcTable[(result ^ b[i]) & 255] ^ (result >>> 8);
  return (result ^ 0xffffffff) >>> 0;
}

/** Bound declared dimensions before calling an independent, bundled WASM decoder.
 * Only metadata-free still PNG/WebP output from T32 is ingested; JPEG sources
 * must first pass through T32. Never fetch a caller URL or a codec at runtime. */
export async function validatePreparedImage(b: Uint8Array, type: string): Promise<{width: number; height: number}> {
  let width = 0, height = 0;
  const dimensions = (w: number, h: number) => {
    if (w < 1 || h < 1 || w > 1024 || h > 1024 || (width && (w !== width || h !== height))) invalid();
    width = w; height = h;
  };
  if (type === 'image/png') {
    if (b.length < 8 || ![137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => b[i] === v)) invalid();
    let p = 8, first = true, ended = false, data = false;
    while (p + 12 <= b.length) {
      const length = u32(b, p), kind = ascii(b, p + 4);
      if (length > b.length - p - 12 || crc(b, p + 4, p + 8 + length) !== u32(b, p + 8 + length)) invalid();
      if (first) {
        if (kind !== 'IHDR' || length !== 13) invalid();
        dimensions(u32(b, p + 8), u32(b, p + 12)); first = false;
      } else if (kind === 'IHDR') invalid();
      if (!['IHDR', 'IDAT', 'IEND', 'sRGB', 'gAMA', 'cHRM', 'pHYs', 'PLTE', 'tRNS'].includes(kind)) invalid();
      if (kind === 'IDAT') data = true;
      p += length + 12;
      if (kind === 'IEND') {
        if (length || p !== b.length || !data) invalid();
        ended = true; break;
      }
    }
    if (!ended) invalid();
  } else if (type === 'image/webp') {
    if (b.length < 20 || ascii(b, 0) !== 'RIFF' || ascii(b, 8) !== 'WEBP' || u32(b, 4, true) + 8 !== b.length) invalid();
    let p = 12, frame = false, extended = false;
    while (p + 8 <= b.length) {
      const kind = ascii(b, p), size = u32(b, p + 4, true), q = p + 8;
      if (size > b.length - q) invalid();
      if (!['VP8X', 'VP8 ', 'VP8L', 'ALPH', 'ICCP'].includes(kind)) invalid();
      if (kind === 'VP8X') {
        if (extended || size !== 10 || b[q] & (0xc0 | 1 | 2 | 4 | 8) || b[q + 1] || b[q + 2] || b[q + 3]) invalid();
        extended = true;
        dimensions(1 + b[q + 4] + (b[q + 5] << 8) + (b[q + 6] << 16),
          1 + b[q + 7] + (b[q + 8] << 8) + (b[q + 9] << 16));
      } else if (kind === 'VP8 ') {
        if (frame || size < 10 || b[q + 3] !== 0x9d || b[q + 4] !== 1 || b[q + 5] !== 0x2a) invalid();
        dimensions((b[q + 6] | b[q + 7] << 8) & 0x3fff, (b[q + 8] | b[q + 9] << 8) & 0x3fff); frame = true;
      } else if (kind === 'VP8L') {
        if (frame || size < 5 || b[q] !== 0x2f) invalid();
        dimensions(1 + ((b[q + 1] | b[q + 2] << 8) & 0x3fff),
          1 + ((b[q + 2] >> 6 | b[q + 3] << 2 | b[q + 4] << 10) & 0x3fff)); frame = true;
      }
      p = q + size + (size & 1);
    }
    if (p !== b.length || !frame) invalid();
  } else invalid();
  try {
    // Initialise each bundled codec once per isolate. Synchronous decoder work
    // cannot interleave with another request; max decoded RGBA is 4 MiB.
    const buffer = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;
    let decoded;
    if (type === 'image/png') { await initPng(pngModule); decoded = await decodePng(buffer); }
    else { await (webpReady ??= initWebp(webpModule)); decoded = await decodeWebp(buffer); }
    if (decoded.width !== width || decoded.height !== height || decoded.data.length !== width * height * 4) invalid();
  } catch { invalid(); }
  return { width, height };
}
