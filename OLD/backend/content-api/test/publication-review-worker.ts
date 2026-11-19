// Test-only multiplexer for two independently deployed entrypoints. No such
// forwarding route or test fault injection exists in either production service.
import api from '../src/index';
import operator from '../src/publication-operator';
import type { Env } from '../src/env';
export default {
  async fetch(request: Request, env: Env & { PUBLICATION_OPERATOR_TOKEN?: string }): Promise<Response> {
    const url = new URL(request.url);
    if (!url.pathname.startsWith('/__operator/')) return api.fetch(request,env);
    url.pathname = url.pathname.replace('/__operator/','/releases/');
    const failAfter = Number(request.headers.get('X-Test-Fail-After'));
    let writes = 0;
    const content = new Proxy(env.CONTENT,{ get(target,key) {
      if (key === 'put') return async (...args: Parameters<R2Bucket['put']>) => {
        if (++writes === 1 && request.headers.get('X-Test-Hide-On-Write') === '1') {
          await env.DB.batch([
            env.DB.prepare("UPDATE studio_entities SET state='hidden',revision=revision+1 WHERE resource_type='pack'"),
            env.DB.prepare('UPDATE catalog_packs SET published=0'),
            env.DB.prepare('UPDATE studio_generation SET generation=generation+1 WHERE id=1'),
          ]);
        }
        if (writes === 1 && request.headers.get('X-Test-Generation-On-Write') === '1') {
          await env.DB.prepare('UPDATE studio_generation SET generation=generation+1 WHERE id=1').run();
        }
        if (writes === failAfter) throw new Error('injected_write_failure');
        return target.put(...args);
      };
      const value = Reflect.get(target,key);
      return typeof value === 'function' ? value.bind(target) : value;
    }});
    return operator.fetch(new Request(url,request),{ ...env, CONTENT: content });
  },
};
