/** Separate privileged service. NOT imported by index.ts and NOT deployed by
 * the Studio/site/API workflows. Provision only after the T35 operator review.
 * No signing key belongs here: artifacts are prepared/signed offline by T22. */
import type { Env } from './env';
import { hash, type Bundle } from './publication';
import { releaseReviewed, reviewFailure } from './studio-publication';
import { StudioError } from './studio-auth';
interface OperatorEnv extends Env { PUBLICATION_OPERATOR_TOKEN?: string }
export default {
  async fetch(request: Request, env: OperatorEnv): Promise<Response> {
    try {
      const token = env.PUBLICATION_OPERATOR_TOKEN;
      const supplied = request.headers.get('Authorization') ?? '';
      // Fixed-size digests avoid direct secret-string comparisons. This token is
      // an independent operator credential, never a Firebase or Studio token.
      if (!token || token.length < 32 || !supplied.startsWith('Bearer ')
        || await hash(new TextEncoder().encode(supplied.slice(7))) !== await hash(new TextEncoder().encode(token))) throw new StudioError(403,'forbidden');
      const url = new URL(request.url);
      const match = /^\/releases\/([a-zA-Z0-9-]+)$/.exec(url.pathname);
      if (request.method !== 'POST' || !match || url.search) throw new StudioError(404,'not_found');
      // Operator bundles are deliberately fixture-sized until streaming budgets
      // are reviewed. Bound input before JSON/base64 expansion.
      const limit = 16 * 1024 * 1024;
      if (Number(request.headers.get('Content-Length') ?? 0) > limit) throw new StudioError(413,'invalid_request');
      const reader = request.body?.getReader();
      if (!reader) throw new StudioError(400,'invalid_request');
      const chunks: Uint8Array[] = []; let size = 0;
      try {
        while (true) {
          const part = await reader.read(); if (part.done) break;
          size += part.value.length;
          if (size > limit) { void reader.cancel(); throw new StudioError(413,'invalid_request'); }
          chunks.push(part.value);
        }
      } finally { reader.releaseLock(); }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.length; }
      let bundle: Bundle;
      try { bundle = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new StudioError(400,'invalid_request'); }
      await releaseReviewed(env,match[1],bundle);
      return Response.json({ protocolVersion: 1, requestId: match[1], status: 'released' },{ headers: { 'Cache-Control': 'no-store' } });
    } catch (error) { return reviewFailure(error); }
  },
} satisfies ExportedHandler<OperatorEnv>;
