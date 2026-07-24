-- Complete the production listing contract used by clever-processor/create-listing.
-- Existing environments created listings before film_hub_content was added to
-- the application payload, so both the Edge Function and direct fallback fail
-- after product miniatures have already uploaded.

begin;

alter table public.listings
  add column if not exists film_hub_content text;

update public.listings
set film_hub_content = media_url
where film_hub_content is null
  and media_url is not null;

comment on column public.listings.film_hub_content is
  'Compatibility media URL used by Shop, showcase, and Film Hub surfaces.';

notify pgrst, 'reload schema';

commit;
