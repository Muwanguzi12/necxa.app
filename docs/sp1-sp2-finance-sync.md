# SP1 ↔ SP2 finance profile synchronization

SP2 (`ayvescksetiuekoyfqar`) is the only wallet and ledger authority. SP1
(`lzdtrmjcwzalckszdzpt`) stores a private, read-only snapshot for profile display
and temporary fallback. Clients must never write a balance in either project.

## Data flow

1. An atomic SP2 finance RPC changes fiat, NCX, escrow, earnings, or spending.
2. The SP2 wallet trigger upserts that user into `finance_profile_sync_outbox`.
3. `finance-engine` attempts an immediate delivery for interactive operations.
4. The scheduled SP2 `push-finance-profile-sync` function retries pending users.
5. The SP1 `sync-finance-profile` function authenticates the shared internal secret.
6. SP1 applies the snapshot only when its monotonic `finance_version` is at least
   as new as the saved version.

The outbox is keyed by `user_id`, so repeated wallet changes collapse to the latest
state. A successful delivery deletes only the exact queued version; a newer wallet
change cannot be accidentally acknowledged by an older delivery.

SP2's original finance-core wallet schema keeps `user_id` as its primary key and
retains its existing `version` column. The synchronization migration adds a stable
wallet `id`, escrow/earned/spent summaries, and a separate `finance_version` without
replacing the existing keys. Finance-only system wallets such as “Necxa Platform”
are deliberately excluded because they do not represent SP1 user profiles.

## Deployment order

Generate one long random `FINANCE_SYNC_SECRET`. It must be identical in SP1 and
SP2 and must never be included in Flutter or web frontend code.

### SP1 — primary identity project

1. Apply `202608020002_supabase1_profile_finance_snapshot.sql` if it has not run.
2. Apply `202608020003_supabase1_apply_finance_snapshot.sql`.
3. Deploy `sync-finance-profile` to project `lzdtrmjcwzalckszdzpt`.
4. Set `FINANCE_SYNC_SECRET` on that project.

### SP2 — finance project

1. Apply `202608020004_supabase2_finance_sync_outbox.sql`.
2. Store the matching secret in Vault under `finance_sync_secret`.
3. Apply `202608020005_supabase2_finance_sync_schedule.sql`.
4. Deploy the updated `finance-engine` and `push-finance-profile-sync` functions to
   project `ayvescksetiuekoyfqar`.
5. Set these SP2 function secrets:

   - `PRIMARY_SUPABASE_URL=https://lzdtrmjcwzalckszdzpt.supabase.co`
   - `PRIMARY_SUPABASE_ANON_KEY=<SP1 anon key>`
   - `FINANCE_SYNC_SECRET=<the exact SP1 value>`

The schedule migration invokes `push-finance-profile-sync` every minute using the
Vault secret and `{ "limit": 100 }`.

## Reconciliation checks

On SP2, a healthy queue should normally be empty or contain only very recent rows:

```sql
select user_id, wallet_version, wallet_updated_at, attempts, last_attempt_at, last_error
from public.finance_profile_sync_outbox
order by queued_at;
```

For a user, SP1 is current when `profile_finance_snapshots.finance_version`
matches SP2 `wallets.finance_version` and the fiat, coin, escrow, earned, and spent
values are equal. The immutable SP2 ledger remains the source used to investigate
or rebuild a disputed balance.
