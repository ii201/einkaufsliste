-- 📍-Erinnerung: markierte Artikel, die ein iPhone-Kurzbefehl bei Ankunft an einem Ort abfragt.
-- Einmal im Supabase SQL Editor ausführen, nach supabase.sql und supabase-bearbeiten.sql.

alter table public.items add column if not exists remind boolean not null default false;
alter table public.app_settings add column if not exists remind_token text;
update public.app_settings set remind_token = encode(extensions.gen_random_bytes(16), 'hex')
where id = 1 and remind_token is null;

-- add_item bekommt p_remind (Standard aus, damit ältere App-Stände weiter funktionieren)
drop function if exists public.add_item(text, text, text, text, text);
create or replace function public.add_item(p_pin text, p_name text, p_qty text, p_category text, p_by text, p_remind boolean default false) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_name text := btrim(p_name);
  v_qty text := nullif(btrim(coalesce(p_qty, '')), '');
  v_cat text := coalesce(nullif(btrim(coalesce(p_category, '')), ''), 'Sonstiges');
begin
  perform _assert_pin(p_pin);
  if v_name = '' then raise exception 'empty name'; end if;

  if exists (select 1 from items where lower(name) = lower(v_name) and not checked) then
    update items set qty = coalesce(v_qty, qty), category = v_cat, remind = remind or coalesce(p_remind, false)
    where lower(name) = lower(v_name) and not checked;
  else
    insert into items (name, qty, category, added_by, remind)
    values (v_name, v_qty, v_cat, nullif(btrim(coalesce(p_by, '')), ''), coalesce(p_remind, false));
  end if;

  insert into favorites (name, category) values (v_name, v_cat)
  on conflict (name) do update
    set uses = favorites.uses + 1, last_used = now(), category = excluded.category;
end $$;

create or replace function public.set_remind(p_pin text, p_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  update items set remind = coalesce(p_on, false) where id = p_id;
end $$;

-- Schlüssel für den Kurzbefehl, nur mit PIN abrufbar
create or replace function public.remind_token(p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  return (select remind_token from app_settings where id = 1);
end $$;

-- Vom Kurzbefehl per GET aufgerufen: nur Namen der offenen 📍-Artikel, sonst nichts
create or replace function public.erinnerung(p_token text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if p_token is null or p_token is distinct from (select remind_token from app_settings where id = 1) then
    raise exception 'invalid token' using errcode = '28P01';
  end if;
  return (
    select json_build_object(
      'text', string_agg(name || coalesce(' (' || qty || ')', ''), ', ' order by created_at),
      'anzahl', count(*)
    )
    from items where remind and not checked
  );
end $$;

grant execute on function
  public.add_item(text, text, text, text, text, boolean),
  public.set_remind(text, uuid, boolean),
  public.remind_token(text),
  public.erinnerung(text)
to anon, authenticated;
