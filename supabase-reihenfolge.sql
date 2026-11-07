-- Gemeinsame Reihenfolge der Kategorien (Weg durch den Laden).
-- Einmal im Supabase SQL Editor ausführen, nach supabase.sql.

alter table public.app_settings add column if not exists cat_order text[];

create or replace function public.get_state(p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  return json_build_object(
    'items', coalesce((select json_agg(i order by i.created_at) from items i), '[]'::json),
    'favorites', coalesce((
      select json_agg(f) from (
        select * from favorites order by uses desc, last_used desc limit 40
      ) f
    ), '[]'::json),
    'cat_order', (select cat_order from app_settings where id = 1)
  );
end $$;

create or replace function public.set_cat_order(p_pin text, p_order text[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  update app_settings set cat_order = case when cardinality(p_order) > 0 then p_order[1:30] end where id = 1;
end $$;

grant execute on function public.set_cat_order(text, text[]) to anon, authenticated;
