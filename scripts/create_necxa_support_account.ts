import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const url = Deno.env.get("PRIMARY_SUPABASE_URL") ||
  "https://lzdtrmjcwzalckszdzpt.supabase.co"
const serviceRole = Deno.env.get("PRIMARY_SUPABASE_SERVICE_ROLE_KEY") || ""
if (!serviceRole) throw new Error("Set PRIMARY_SUPABASE_SERVICE_ROLE_KEY before running this script")

const admin = createClient(url, serviceRole, {
  auth: { persistSession: false, autoRefreshToken: false },
})
const email = "support@necxa.uk"

let supportUser
for (let pageNumber = 1; !supportUser; pageNumber++) {
  const { data: page, error: listError } = await admin.auth.admin.listUsers({
    page: pageNumber,
    perPage: 1000,
  })
  if (listError) throw listError
  supportUser = page.users.find((user) => user.email?.toLowerCase() === email)
  if (page.users.length < 1000) break
}

if (!supportUser) {
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password: `${crypto.randomUUID()}-${crypto.randomUUID()}`,
    email_confirm: true,
    user_metadata: {
      full_name: "Necxa Support",
      is_system_account: true,
    },
  })
  if (error || !data.user) throw error || new Error("Support account was not created")
  supportUser = data.user
}

const { error: profileError } = await admin.from("profiles").upsert({
  id: supportUser.id,
  email,
  full_name: "Necxa Support",
  is_agent: true,
  is_verified_agent: true,
  trust_score: 100,
}, { onConflict: "id" })
if (profileError) throw profileError

console.log(`SUPPORT_ACCOUNT_ID=${supportUser.id}`)
