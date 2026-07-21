import type { Request, Response, NextFunction } from 'express';
import { createRemoteJWKSet, jwtVerify, importSPKI, type JWTPayload } from 'jose';

const JWKS_URI = process.env.JWKS_URI || '';
const ISSUER = process.env.JWT_ISSUER || '';
const AUDIENCE = process.env.JWT_AUDIENCE || '';
const JWT_PUBLIC_KEY = process.env.JWT_PUBLIC_KEY || ''; // PEM-format public key (RS256)
const JWT_ALG = process.env.JWT_ALG || 'RS256';

let remoteJwks: ReturnType<typeof createRemoteJWKSet> | null = null;
let localKey: any = null;

if (JWKS_URI) remoteJwks = createRemoteJWKSet(new URL(JWKS_URI));

export interface AuthRequest extends Request {
  user?: JWTPayload & { sub?: string };
}

async function getLocalKey() {
  if (localKey) return localKey;
  if (!JWT_PUBLIC_KEY) return null;
  // importSPKI returns a KeyLike for verification
  localKey = await importSPKI(JWT_PUBLIC_KEY, JWT_ALG);
  return localKey;
}

export function jwksAuth() {
  if (!remoteJwks && !JWT_PUBLIC_KEY) {
    console.warn('Neither JWKS_URI nor JWT_PUBLIC_KEY configured — jwksAuth will reject requests in production');
  }

  return async (req: AuthRequest, res: Response, next: NextFunction) => {
    try {
      const header = req.headers.authorization;
      if (!header) return res.status(401).json({ message: 'missing Authorization header' });
      const parts = header.split(' ');
      if (parts.length !== 2 || parts[0] !== 'Bearer') return res.status(401).json({ message: 'malformed Authorization header' });
      const token = parts[1];

      const opts: any = {};
      if (ISSUER) opts.issuer = ISSUER;
      if (AUDIENCE) opts.audience = AUDIENCE;

      // Prefer JWKS remote validation when configured
      if (remoteJwks) {
        const { payload } = await jwtVerify(token, remoteJwks, opts);
        req.user = payload as JWTPayload & { sub?: string };
        return next();
      }

      // Fallback to local PEM public key verification
      const key = await getLocalKey();
      if (!key) return res.status(500).json({ message: 'no JWKS or public key configured' });
      const { payload } = await jwtVerify(token, key, opts);
      req.user = payload as JWTPayload & { sub?: string };
      return next();
    } catch (err: any) {
      return res.status(401).json({ message: 'invalid token', detail: String(err?.message || err) });
    }
  };
}

export function requireRole(role: string) {
  return (req: AuthRequest, res: Response, next: NextFunction) => {
    const user = req.user as any;
    if (!user) return res.status(401).json({ message: 'unauthenticated' });
    const roles = (user.roles || user.role || user['https://necxa.uk/roles']) || [];
    const roleList = Array.isArray(roles) ? roles : [roles];
    if (roleList.includes(role)) return next();
    return res.status(403).json({ message: 'forbidden' });
  };
}
