-- Artikel nachträglich bearbeiten (Name, Menge, Kategorie).
-- Einmal im Supabase SQL Editor ausführen, nach supabase.sql und supabase-kochen.sql.

create or replace function public.update_item(p_pin text, p_id uuid, p_name text, p_qty text, p_category text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_qty text := left(nullif(btrim(coalesce(p_qty, '')), ''), 40);
  v_cat text := coalesce(nullif(btrim(coalesce(p_category, '')), ''), 'Sonstiges');
begin
  perform _assert_pin(p_pin);
  if v_name = '' then raise exception 'empty name'; end if;
  update items set name = v_name, qty = v_qty, category = v_cat where id = p_id;
  -- Kategorie merken, damit der Artikel beim nächsten Mal gleich richtig einsortiert wird
  update favorites set category = v_cat where lower(name) = lower(v_name);
end $$;

grant execute on function public.update_item(text, uuid, text, text, text) to anon, authenticated;
