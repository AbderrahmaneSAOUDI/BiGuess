// Local Miniflare operator/test harness only. No production routing imports it.
import worker from '../src/index';
import { importLegacyDrafts, rollbackLegacyDrafts, LegacyImportError } from '../src/legacy-import';
import type { Env } from '../src/env';
import { publish, type Bundle } from '../src/publication';
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path.startsWith('/__legacy/') && env.APP_ENV !== 'local') {
      return Response.json({error:{code:'local_only',message:'Legacy operator harness is local-only.'}},{status:403,headers:{'Cache-Control':'no-store'}});
    }
    try {
      if (request.method==='POST' && path==='/__legacy/import') {
        return Response.json(await importLegacyDrafts(env,await request.json()),{headers:{'Cache-Control':'no-store'}});
      }
      if (request.method==='POST' && path==='/__legacy/rollback') {
        const body = await request.json() as {importId:string};
        return Response.json(await rollbackLegacyDrafts(env,body.importId),{headers:{'Cache-Control':'no-store'}});
      }
      if (request.method==='POST' && path==='/__legacy/publish') {
        const body = await request.json() as {bundle:Bundle;expectedRevision:number};
        try {
          await publish(env,body.bundle,body.expectedRevision);
          return Response.json({published:true},{headers:{'Cache-Control':'no-store'}});
        } catch { return Response.json({error:{code:'invalid_publication'}},{status:409,headers:{'Cache-Control':'no-store'}}); }
      }
      return worker.fetch(request,env);
    } catch (error) {
      return Response.json({error:{code:error instanceof LegacyImportError?error.code:'invalid_import',
        message:error instanceof Error?error.message:'Invalid local import.'}},
        {status:error instanceof LegacyImportError?error.status:422,headers:{'Cache-Control':'no-store'}});
    }
  },
};
