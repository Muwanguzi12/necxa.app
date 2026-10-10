begin;

insert into public.gift_items (
  id, name, emoji, ncx_value, ugx_value, category, sort_order, is_active
) values
  ('rose', 'Rose', U&'\+01F339', 1, 100, 'standard', 1, true),
  ('clap', 'Clap', U&'\+01F44F', 2, 200, 'standard', 2, true),
  ('heart', 'Heart', U&'\2764', 3, 300, 'standard', 3, true),
  ('coffee', 'Coffee', U&'\2615', 5, 500, 'standard', 4, true),
  ('star', 'Star', U&'\2B50', 5, 500, 'standard', 5, true),
  ('fire', 'Fire', U&'\+01F525', 10, 1000, 'standard', 6, true),
  ('rocket', 'Rocket', U&'\+01F680', 20, 2000, 'rare', 7, true),
  ('crown', 'Crown', U&'\+01F451', 25, 2500, 'rare', 8, true),
  ('diamond', 'Diamond', U&'\+01F48E', 50, 5000, 'rare', 9, true),
  ('trophy', 'Trophy', U&'\+01F3C6', 50, 5000, 'rare', 10, true),
  ('money_bag', 'Money Bag', U&'\+01F4B0', 100, 10000, 'rare', 11, true),
  ('sports_car', 'Sports Car', U&'\+01F3CE', 200, 20000, 'epic', 12, true),
  ('yacht', 'Yacht', U&'\26F5', 500, 50000, 'epic', 13, true),
  ('mansion', 'Mansion', U&'\+01F3F0', 1000, 100000, 'epic', 14, true),
  ('jet', 'Private Jet', U&'\2708', 1500, 150000, 'legendary', 15, true),
  ('globe', 'Globe', U&'\+01F30D', 5000, 500000, 'legendary', 16, true),
  ('stadium', 'Stadium', U&'\+01F3DF', 10000, 1000000, 'legendary', 17, true),
  ('ressort', 'Ressort', U&'\+01F3A2', 50000, 5000000, 'legendary', 18, true)
on conflict (id) do update set
  name = excluded.name,
  emoji = excluded.emoji,
  ncx_value = excluded.ncx_value,
  ugx_value = excluded.ugx_value,
  category = excluded.category,
  sort_order = excluded.sort_order,
  is_active = excluded.is_active;

update public.gift_items
set is_active = false
where id in (
  'moneybag', 'sportscar', 'villa', 'palace', 'galaxy',
  'dragon', 'mansion_old'
)
and id not in (
  'rose', 'clap', 'heart', 'coffee', 'star', 'fire', 'rocket', 'crown',
  'diamond', 'trophy', 'money_bag', 'sports_car', 'yacht', 'mansion',
  'jet', 'globe', 'stadium', 'ressort'
);

commit;
