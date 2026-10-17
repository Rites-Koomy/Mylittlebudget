export interface AccessConfig { teamDomain?: string; audience?: string }

export async function requireCloudflareAccess(request: Request, config: AccessConfig): Promise<Response | null> {
  const token = request.headers.get('Cf-Access-Jwt-Assertion');
  if (!token) return jsonError('Authentification requise.', 401);
  if (!config.teamDomain || !config.audience) return jsonError('Accès privé non configuré.', 503);
  try {
    await verifyAccessJwt(token, { teamDomain: config.teamDomain, audience: config.audience });
    return null;
  } catch {
    return jsonError('Jeton Access invalide.', 401);
  }
}

type JwtHeader = { alg?: string; kid?: string };
type JwtClaims = { iss?: string; aud?: string | string[]; exp?: number; nbf?: number };
type AccessJwk = JsonWebKey & { kid?: string };

async function verifyAccessJwt(token: string, config: { teamDomain: string; audience: string }): Promise<void> {
  const [encodedHeader, encodedPayload, encodedSignature] = token.split('.');
  if (!encodedHeader || !encodedPayload || !encodedSignature) throw new Error('Malformed JWT');
  const header = JSON.parse(decodeBase64Url(encodedHeader)) as JwtHeader;
  const claims = JSON.parse(decodeBase64Url(encodedPayload)) as JwtClaims;
  if (header.alg !== 'RS256' || !header.kid) throw new Error('Unsupported JWT');
  const issuer = config.teamDomain.replace(/\/$/, '');
  const now = Math.floor(Date.now() / 1000);
  if (claims.iss !== issuer || !claims.exp || claims.exp <= now || (claims.nbf !== undefined && claims.nbf > now)) throw new Error('Invalid claims');
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(config.audience)) throw new Error('Invalid audience');
  const jwksResponse = await fetch(`${issuer}/cdn-cgi/access/certs`);
  if (!jwksResponse.ok) throw new Error('JWKS unavailable');
  const jwks = await jwksResponse.json() as { keys?: AccessJwk[] };
  const jwk = jwks.keys?.find((key) => key.kid === header.kid);
  if (!jwk) throw new Error('Unknown key');
  const cryptoKey = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const valid = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', cryptoKey, decodeBytes(encodedSignature), new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`));
  if (!valid) throw new Error('Invalid signature');
}

function decodeBase64Url(value: string): string { return new TextDecoder().decode(new Uint8Array(decodeBytes(value))); }

function decodeBytes(value: string): ArrayBuffer {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - value.length % 4) % 4);
  const binary = atob(normalized);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

export function jsonError(message: string, status: number): Response {
  return Response.json({ error: message }, { status, headers: { 'Cache-Control': 'no-store' } });
}
