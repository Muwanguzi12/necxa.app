import type { Request, Response, NextFunction } from 'express';
import {
  createRemoteJWKSet,
  decodeJwt,
  importSPKI,
  jwtVerify,
  type JWTPayload,
} from 'jose';

interface AuthProvider {
  issuer?: string;
  projectUrl?: string;
  publishableKey?: string;
  jwks: ReturnType<typeof createRemoteJWKSet>;
}

export interface AuthRequest extends Request {
  user?: JWTPayload & { sub?: string; id?: string };
}

function values(...inputs: Array<string | undefined>): string[] {
  return inputs
    .flatMap((input) => (input || '').split(','))
    .map((input) => input.trim().replace(/\/$/, ''))
    .filter(Boolean);
}

function projectIssuer(projectUrl: string) {
  return `${projectUrl}/auth/v1`;
}

function buildProviders(): AuthProvider[] {
  const providers: AuthProvider[] = [];
  const addProject = (projectUrl?: string, publishableKey?: string) => {
    const normalizedUrl = projectUrl?.trim().replace(/\/$/, '');
    if (!normalizedUrl) return;
    const existing = providers.find(
      (provider) => provider.projectUrl === normalizedUrl,
    );
    if (existing) {
      existing.publishableKey ||= publishableKey?.trim() || undefined;
      return;
    }
    providers.push({
      projectUrl: normalizedUrl,
      issuer: projectIssuer(normalizedUrl),
      publishableKey: publishableKey?.trim() || undefined,
      jwks: createRemoteJWKSet(
        new URL(`${projectIssuer(normalizedUrl)}/.well-known/jwks.json`),
      ),
    });
  };

  const configuredUrls = values(process.env.SUPABASE_AUTH_URLS);
  const configuredKeys = values(process.env.SUPABASE_AUTH_PUBLISHABLE_KEYS);
  configuredUrls.forEach((url, index) => {
    addProject(url, configuredKeys[index] || configuredKeys[0]);
  });
  addProject(
    process.env.PRIMARY_SUPABASE_URL,
    process.env.PRIMARY_SUPABASE_PUBLISHABLE_KEY ||
      process.env.PRIMARY_SUPABASE_ANON_KEY,
  );
  addProject(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_ANON_KEY,
  );
  addProject(
    process.env.SUPABASE_2_URL,
    process.env.SUPABASE_2_PUBLISHABLE_KEY || process.env.SUPABASE_2_ANON_KEY,
  );
  addProject(
    process.env.SUPABASE_FINANCE_URL,
    process.env.SUPABASE_FINANCE_PUBLISHABLE_KEY ||
      process.env.SUPABASE_FINANCE_ANON_KEY,
  );

  const explicitIssuers = values(process.env.JWT_ISSUERS, process.env.JWT_ISSUER);
  const explicitJwks = values(process.env.JWKS_URIS, process.env.JWKS_URI);
  for (let index = 0; index < explicitJwks.length; index += 1) {
    const uri = explicitJwks[index];
    providers.push({
      issuer: explicitIssuers[index] || explicitIssuers[0],
      jwks: createRemoteJWKSet(new URL(uri)),
    });
  }
  return providers;
}

async function verifyWithSupabaseUserEndpoint(
  token: string,
  providers: AuthProvider[],
): Promise<(JWTPayload & { sub?: string; id?: string }) | null> {
  for (const provider of providers) {
    if (!provider.projectUrl || !provider.publishableKey) continue;
    try {
      const response = await fetch(`${provider.projectUrl}/auth/v1/user`, {
        headers: {
          apikey: provider.publishableKey,
          authorization: `Bearer ${token}`,
        },
      });
      if (!response.ok) continue;
      const user = (await response.json()) as { id?: string; role?: string };
      if (!user.id) continue;
      return {
        sub: user.id,
        id: user.id,
        role: user.role || 'authenticated',
        iss: provider.issuer,
      };
    } catch (_) {
      // Try the next configured Supabase project.
    }
  }
  return null;
}

export function jwksAuth() {
  const providers = buildProviders();
  const publicKey = process.env.JWT_PUBLIC_KEY?.trim() || '';
  const algorithm = process.env.JWT_ALG?.trim() || 'RS256';
  const audience = process.env.JWT_AUDIENCE?.trim() || undefined;
  let localKey: Awaited<ReturnType<typeof importSPKI>> | null = null;

  return async (req: AuthRequest, res: Response, next: NextFunction) => {
    const header = req.headers.authorization;
    if (!header) {
      return res.status(401).json({ message: 'missing Authorization header' });
    }
    const [scheme, token, ...extra] = header.trim().split(/\s+/);
    if (scheme.toLowerCase() !== 'bearer' || !token || extra.length > 0) {
      return res.status(401).json({ message: 'malformed Authorization header' });
    }
    if (providers.length === 0 && !publicKey) {
      return res.status(503).json({ message: 'authentication is not configured' });
    }

    let unverifiedIssuer: string | undefined;
    try {
      unverifiedIssuer = decodeJwt(token).iss;
    } catch (_) {
      return res.status(401).json({ message: 'invalid token' });
    }

    const candidates = unverifiedIssuer
      ? providers.filter(
          (provider) => !provider.issuer || provider.issuer === unverifiedIssuer,
        )
      : providers;
    for (const provider of candidates) {
      try {
        const { payload } = await jwtVerify(token, provider.jwks, {
          ...(provider.issuer ? { issuer: provider.issuer } : {}),
          ...(audience ? { audience } : {}),
        });
        req.user = payload as AuthRequest['user'];
        return next();
      } catch (_) {
        // JWKS can be empty for a Supabase project still using legacy HS256.
      }
    }

    const supabaseUser = await verifyWithSupabaseUserEndpoint(token, candidates);
    if (supabaseUser) {
      req.user = supabaseUser;
      return next();
    }

    if (publicKey) {
      try {
        localKey ||= await importSPKI(publicKey, algorithm);
        const { payload } = await jwtVerify(token, localKey, {
          ...(audience ? { audience } : {}),
        });
        req.user = payload as AuthRequest['user'];
        return next();
      } catch (_) {
        // Fall through to the generic rejection below.
      }
    }

    return res.status(401).json({ message: 'invalid token' });
  };
}

export function requireRole(role: string) {
  return (req: AuthRequest, res: Response, next: NextFunction) => {
    const user = req.user as Record<string, unknown> | undefined;
    if (!user) return res.status(401).json({ message: 'unauthenticated' });
    const rawRoles = user.roles || user.role || user['https://necxa.uk/roles'] || [];
    const roles = Array.isArray(rawRoles) ? rawRoles : [rawRoles];
    if (roles.includes(role)) return next();
    return res.status(403).json({ message: 'forbidden' });
  };
}
