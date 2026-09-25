begin;

-- Gmail reply/sync refresh the access token from the durable refresh token.
-- Keep the refresh timestamp on the canonical inbox row for operations checks.
alter table public.inboxes
  add column if not exists gmail_token_updated timestamptz;

commit;
