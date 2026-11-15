-- NECXA Filter Catalogue
-- Each row describes one downloadable filter/effect package.

create table if not exists public.necxa_filters (
  id            uuid primary key default gen_random_uuid(),
  display_name  text not null,
  category      text not null check (category in ('beauty','super_face','symmetry','glow','color','creative')),
  description   text,
  asset_version text not null default '1.0.0',
  asset_path    text,           -- Storage path in 'necxa-filters' bucket, e.g. 'v1/beauty_glow.zip'
  thumbnail_path text,          -- Storage path to thumbnail PNG
  asset_size_bytes bigint,
  asset_sha256  text,           -- Hex SHA-256 of the zip for integrity check
  engine_min_version text not null default '1.0.0',
  is_enabled    boolean not null default true,
  effect_params jsonb,          -- e.g. {"brightness": 0.1, "saturation": 1.2, "hue": 0.0, "colorMatrixPreset": "cinema"}
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Updated-at trigger
create or replace function public.set_necxa_filter_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace trigger necxa_filters_updated_at
  before update on public.necxa_filters
  for each row execute procedure public.set_necxa_filter_updated_at();

-- RLS: authenticated users can read enabled filters; only service role can write
alter table public.necxa_filters enable row level security;

create policy "Authenticated users can read enabled filters"
  on public.necxa_filters for select
  to authenticated
  using (is_enabled = true);

-- Also allow public anon select if desired for pre-login experiences
create policy "Anon users can read enabled filters"
  on public.necxa_filters for select
  to anon
  using (is_enabled = true);

-- Seed built-in filters (asset_path null = engine-local, no download needed)
insert into public.necxa_filters (display_name, category, description, is_enabled, effect_params) values
  ('Natural', 'beauty',      'Subtle skin smoothing, warm tones',          true, '{"brightness":0.05,"contrast":1.05,"saturation":1.1,"hue":0.0}'),
  ('Cinema',  'color',       'Orange & teal grade, film contrast',         true, '{"brightness":-0.05,"contrast":1.15,"saturation":0.9,"hue":0.08,"colorMatrixPreset":"cinema"}'),
  ('Neon',    'creative',    'Purple tint, high saturation glow',          true, '{"brightness":0.0,"contrast":1.1,"saturation":1.6,"hue":-0.15,"colorMatrixPreset":"neon"}'),
  ('Noir',    'color',       'Black & white desaturation',                 true, '{"brightness":0.0,"contrast":1.2,"saturation":0.0,"hue":0.0,"colorMatrixPreset":"grayscale"}'),
  ('Vivid',   'color',       'Boosted vibrance and clarity',               true, '{"brightness":0.05,"contrast":1.1,"saturation":1.5,"hue":0.0}'),
  ('Glow',    'glow',        'Soft warm highlight bloom',                  true, '{"brightness":0.12,"contrast":0.95,"saturation":1.2,"hue":0.02}'),
  ('Golden',  'beauty',      'Warm golden hour skin tone',                 true, '{"brightness":0.08,"contrast":1.05,"saturation":1.15,"hue":0.06}'),
  ('Arctic',  'color',       'Cool blue, desaturated winter feel',         true, '{"brightness":0.0,"contrast":1.1,"saturation":0.85,"hue":-0.08}'),
  ('Moody',   'creative',    'Deep shadows, high contrast cinematic',      true, '{"brightness":-0.1,"contrast":1.3,"saturation":0.8,"hue":0.0}'),
  ('Dream',   'glow',        'Soft pastel, slightly overexposed',          true, '{"brightness":0.15,"contrast":0.9,"saturation":1.1,"hue":0.03}');

-- Storage bucket setup (run once as superuser / dashboard):
-- INSERT INTO storage.buckets (id, name, public) VALUES ('necxa-filters', 'necxa-filters', false) ON CONFLICT DO NOTHING;
-- CREATE POLICY "Auth download" ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'necxa-filters');
