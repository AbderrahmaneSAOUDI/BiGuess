import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';

export const root = fileURLToPath(new URL('../', import.meta.url));
// Miniflare 5's v4 converter does not discover imported modules or support
// modulesRules. Enumerate the exact Wrangler-emitted Wasm artifacts explicitly.
export function workerModules(scriptPath) {
  return [{ type: 'ESModule', path: scriptPath }, ...readdirSync(dirname(scriptPath))
    .filter(name => name.endsWith('.wasm')).sort()
    .map(name => ({ type: 'CompiledWasm', path: join(dirname(scriptPath), name) }))];
}
export function wrangler(args) {
  return execFileSync(process.execPath, ['node_modules/wrangler/bin/wrangler.js', ...args], {
    cwd: root,
    encoding: 'utf8',
    env: { ...process.env, WRANGLER_SEND_METRICS: 'false' },
    timeout: 60_000,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}
