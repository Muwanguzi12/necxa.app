# Necxa ↔ Goobox support bridge

This directory contains the Goobox-owned half of the support bridge. Browser
code never receives `GOOBOX_SHARED_SECRET` or a service-role key.

## Projects

- Necxa primary/auth: `lzdtrmjcwzalckszdzpt`
- Necxa chat orchestrator: `ayvescksetiuekoyfqar`
- Goobox: `anregykcgolpgxecfxej`

## Deploy in this order

1. Run `supabase/migrations/202608020001_necxa_support_bridge.sql` in the
   Goobox SQL editor.
2. Generate two different random values, each at least 32 bytes:
   `SUPPORT_TOKEN_SECRET` and `GOOBOX_SHARED_SECRET`.
3. From the repository root, deploy the primary handoff function:

   ```powershell
   supabase functions deploy create-support-token --project-ref lzdtrmjcwzalckszdzpt --no-verify-jwt
   supabase secrets set SUPPORT_TOKEN_SECRET=<token-secret> --project-ref lzdtrmjcwzalckszdzpt
   ```

4. Create the system account once using
   `scripts/create_necxa_support_account.ts`, then copy the printed UUID:

   ```powershell
   deno run --allow-env --allow-net scripts/create_necxa_support_account.ts
   ```

5. Deploy the updated chat orchestrator and set its secrets:

   ```powershell
   supabase functions deploy necxa-chat --project-ref ayvescksetiuekoyfqar --no-verify-jwt
   supabase secrets set GOOBOX_SHARED_SECRET=<bridge-secret> SUPPORT_ACCOUNT_ID=<support-user-uuid> --project-ref ayvescksetiuekoyfqar
   ```

6. From this `goobox` directory, deploy the three Goobox functions:

   ```powershell
   supabase functions deploy verify-support-token --project-ref anregykcgolpgxecfxej --no-verify-jwt
   supabase functions deploy create-support-ticket --project-ref anregykcgolpgxecfxej --no-verify-jwt
   supabase functions deploy deliver-necxa-support-reply --project-ref anregykcgolpgxecfxej --no-verify-jwt
   supabase secrets set SUPPORT_TOKEN_SECRET=<token-secret> GOOBOX_SHARED_SECRET=<bridge-secret> NECXA_CHAT_URL=https://ayvescksetiuekoyfqar.supabase.co/functions/v1/necxa-chat NECXA_CHAT_ANON_KEY=<chat-project-anon-key> --project-ref anregykcgolpgxecfxej
   ```

7. Publish the updated `index (1).html` to `goobox.necxa.uk`, then ship the
   Flutter app after deploying `create-support-token`.

Unverified visitors can still create email-only tickets. Only tickets whose
signed handoff is re-verified by `create-support-ticket` receive in-app replies.
