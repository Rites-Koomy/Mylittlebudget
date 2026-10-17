import { jsonError, requireCloudflareAccess } from './middleware/access';

export interface Env { CLOUDFLARE_ACCESS_TEAM_DOMAIN?: string; CLOUDFLARE_ACCESS_AUDIENCE?: string }

const jsonHeaders = { 'Cache-Control': 'no-store' };

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === 'GET' && url.pathname === '/api/health') {
    return Response.json({ ok: true, service: 'budget-perso-worker' }, { headers: jsonHeaders });
  }
  if (url.pathname === '/api/private-demo') {
    const denied = await requireCloudflareAccess(request, { teamDomain: env.CLOUDFLARE_ACCESS_TEAM_DOMAIN, audience: env.CLOUDFLARE_ACCESS_AUDIENCE });
    if (denied) return denied;
    return Response.json({ ok: true }, { headers: jsonHeaders });
  }
  return jsonError('Route introuvable.', 404);
}

export default { fetch: handleRequest } satisfies ExportedHandler<Env>;
