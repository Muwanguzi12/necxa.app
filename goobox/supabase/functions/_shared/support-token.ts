import { verify } from "https://deno.land/x/djwt@v3.0.2/mod.ts"

export type VerifiedSupportUser = {
  user_id: string
  email: string
}

let keyPromise: Promise<CryptoKey> | null = null

function verificationKey(): Promise<CryptoKey> {
  const secret = Deno.env.get("SUPPORT_TOKEN_SECRET") || ""
  if (secret.length < 32) throw new Error("SUPPORT_TOKEN_SECRET is not configured")
  keyPromise ??= crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  )
  return keyPromise
}

export async function verifySupportToken(token: string): Promise<VerifiedSupportUser> {
  if (!token || token.length > 4096) throw new Error("Invalid support token")
  const payload = await verify(token, await verificationKey())
  if (
    payload.purpose !== "goobox_support" ||
    payload.iss !== "necxa" ||
    payload.aud !== "goobox_support" ||
    typeof payload.user_id !== "string" ||
    typeof payload.email !== "string"
  ) {
    throw new Error("Invalid support token")
  }
  return { user_id: payload.user_id, email: payload.email }
}
