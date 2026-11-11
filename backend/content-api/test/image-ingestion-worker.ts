// Test-only operator/failure harness. Never imported by production src/.
import worker from '../src/index';
import { cleanupImages } from '../src/studio-images';
import type { Env } from '../src/env';
const held = new Map<string, () => void>();
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === '/__held') return Response.json({ count: held.size });
    if (path === '/__release') {
      for (const release of held.values()) release(); held.clear();
      return Response.json({ released: true });
    }
    if (path === '/__cleanup') {
      const body = await request.json() as {time?: number; limit?: number};
      return Response.json({ removed: await cleanupImages(env, body.time, body.limit) });
    }
    const hold = request.headers.get('X-Test-Hold-Body');
    const truncate = request.headers.get('X-Test-Truncate-Body') === '1';
    const broken = request.headers.get('X-Test-Broken-Stream') === '1';
    if (hold || truncate || broken) {
      const bytes = new Uint8Array(await request.arrayBuffer());
      const headers = new Headers(request.headers);
      headers.delete('Content-Length');
      if (truncate) headers.set('Content-Length', String(bytes.length + 20));
      let started = false;
      const body = new ReadableStream<Uint8Array>({ pull(controller) {
        if (started) return; started = true;
        if (broken) { controller.error(new Error('synthetic broken transfer')); return; }
        if (hold) return new Promise<void>(resolve => held.set(hold, () => {
          controller.enqueue(bytes); controller.close(); resolve();
        }));
        controller.enqueue(bytes); controller.close();
      } }, { highWaterMark: 0 });
      request = new Request(request.url, { method: request.method, headers, body });
    }
    const fail = request.headers.get('X-Test-Fail-Stage') === '1';
    const race = request.headers.get('X-Test-Cleanup-On-Promote') === '1';
    const raceHead = request.headers.get('X-Test-Cleanup-On-Canonical-Head') === '1';
    if (fail || race || raceHead) {
      const original = env.CONTENT;
      const content = new Proxy(original, { get(target, key) {
        if (key === 'head' && raceHead) return async (name: string) => {
          const result = await original.head(name);
          if (name.startsWith('objects/')) await cleanupImages(env, Math.floor(Date.now() / 1000) + 90000);
          return result;
        };
        if (key === 'put') return async (...args: Parameters<R2Bucket['put']>) => {
          if (fail && String(args[0]).startsWith('studio-staging/')) throw new Error('synthetic interrupted R2 write');
          const result = await original.put(...args);
          if (race && String(args[0]).startsWith('objects/')) await cleanupImages(env, Math.floor(Date.now() / 1000) + 90000);
          return result;
        };
        const value = Reflect.get(target, key);
        return typeof value === 'function' ? value.bind(target) : value;
      } });
      return worker.fetch(request, { ...env, CONTENT: content });
    }
    return worker.fetch(request, env);
  },
};
