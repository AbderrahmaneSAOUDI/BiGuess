import type { Env } from './env';

const methods = ['GET', 'POST', 'PATCH', 'DELETE'];
const headers = ['authorization', 'content-type', 'if-match', 'if-none-match', 'idempotency-key', 'x-content-sha256'];

// Private Studio traffic has a separate origin policy from anonymous catalog
// traffic. No default, wildcard, suffix matching or browser credentials.
function allowed(origin: string, env: Env): boolean {
  let origins: unknown;
  try { origins = JSON.parse(env.STUDIO_ALLOWED_ORIGINS ?? '[]'); } catch { return false; }
  if (!Array.isArray(origins) || !origins.every(value => {
    if (typeof value !== 'string') return false;
    try {
      const url = new URL(value);
      return url.origin === value && (url.protocol === 'https:'
        || (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)));
    } catch { return false; }
  })) return false;
  return origins.includes(origin);
}

export async function studioCors(request: Request, env: Env,
  next: () => Promise<Response>, denied: () => Response): Promise<Response> {
  const origin = request.headers.get('Origin');
  let response: Response;
  if ((origin !== null && !allowed(origin, env)) || (request.method === 'OPTIONS' && origin === null)) {
    response = denied();
  } else if (request.method === 'OPTIONS') {
    const method = request.headers.get('Access-Control-Request-Method');
    const requested = (request.headers.get('Access-Control-Request-Headers') ?? '')
      .split(',').map(value => value.trim().toLowerCase()).filter(Boolean);
    if (!method || !methods.includes(method) || requested.some(value => !headers.includes(value))) {
      response = denied();
    } else {
      response = new Response(null, { status: 204, headers: { 'Cache-Control': 'no-store' } });
      response.headers.set('Access-Control-Allow-Origin', origin!);
      response.headers.set('Access-Control-Allow-Methods', methods.join(', '));
      response.headers.set('Access-Control-Allow-Headers', headers.join(', '));
    }
  } else {
    response = await next();
    if (origin !== null) {
      response.headers.set('Access-Control-Allow-Origin', origin);
      response.headers.set('Access-Control-Expose-Headers', 'ETag, WWW-Authenticate');
    }
  }
  response.headers.append('Vary', 'Origin');
  return response;
}
