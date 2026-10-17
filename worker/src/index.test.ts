import { describe, expect, it } from 'vitest';
import { handleRequest } from './index';

const env = {};

describe('Worker Budget Perso', () => {
  it('répond à la route de santé en JSON', async () => {
    const response = await handleRequest(new Request('https://local.test/api/health'), env);
    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toContain('application/json');
    expect(await response.json()).toEqual({ ok: true, service: 'budget-perso-worker' });
  });

  it('refuse une route privée sans authentification', async () => {
    const response = await handleRequest(new Request('https://local.test/api/private-demo'), env);
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: 'Authentification requise.' });
  });

  it('ne considère pas un e-mail arbitraire comme une authentification', async () => {
    const response = await handleRequest(new Request('https://local.test/api/private-demo', { headers: { 'X-User-Email': 'ritesmassamba@gmail.com' } }), env);
    expect(response.status).toBe(401);
  });

  it('gère les routes inconnues avec une réponse JSON', async () => {
    const response = await handleRequest(new Request('https://local.test/api/unknown'), env);
    expect(response.status).toBe(404);
    expect(response.headers.get('content-type')).toContain('application/json');
  });
});
