-- Einkaufsliste: Datenbank-Setup für Supabase (einmal im SQL Editor ausführen)
-- Tabellen sind für die Webseite gesperrt (RLS ohne Policies).
-- Zugriff nur über die Funktionen unten, und jede prüft die gemeinsame PIN.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.app_settings (
  id int primary key default 1 check (id = 1),
  pin_hash text
);

create table if not exists public.items (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 80),
  qty text check (length(qty) <= 20),
  category text not null default 'Sonstiges',
  checked boolean not null default false,
  added_by text check (length(added_by) <= 30),
  created_at timestamptz not null default now(),
  checked_at timestamptz
);

create table if not exists public.favorites (
  name text primary key,
  category text not null default 'Sonstiges',
  uses int not null default 1,
  last_used timestamptz not null default now()
);

alter table public.app_settings enable row level security;
alter table public.items enable row level security;
alter table public.favorites enable row level security;
revoke all on public.app_settings, public.items, public.favorites from anon, authenticated;

-- PIN prüfen (intern)
create or replace function public._assert_pin(p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  select pin_hash into h from app_settings where id = 1;
  if h is null or p_pin is null or crypt(p_pin, h) <> h then
    perform pg_sleep(1);
    raise exception 'invalid pin' using errcode = '28P01';
  end if;
end $$;
revoke execute on function public._assert_pin(text) from public, anon, authenticated;

-- Anmelden. Ist noch keine PIN gesetzt, wird die erste eingegebene zur PIN.
create or replace function public.login(p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  if p_pin is null or length(p_pin) < 4 then
    raise exception 'pin too short';
  end if;
  select pin_hash into h from app_settings where id = 1;
  if h is null then
    insert into app_settings (id, pin_hash) values (1, crypt(p_pin, gen_salt('bf')))
    on conflict (id) do update set pin_hash = excluded.pin_hash where app_settings.pin_hash is null;
    return 'created';
  end if;
  perform _assert_pin(p_pin);
  return 'ok';
end $$;

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
    ), '[]'::json)
  );
end $$;

create or replace function public.add_item(p_pin text, p_name text, p_qty text, p_category text, p_by text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_name text := btrim(p_name);
  v_qty text := nullif(btrim(coalesce(p_qty, '')), '');
  v_cat text := coalesce(nullif(btrim(coalesce(p_category, '')), ''), 'Sonstiges');
begin
  perform _assert_pin(p_pin);
  if v_name = '' then raise exception 'empty name'; end if;

  if exists (select 1 from items where lower(name) = lower(v_name) and not checked) then
    update items set qty = coalesce(v_qty, qty), category = v_cat
    where lower(name) = lower(v_name) and not checked;
  else
    insert into items (name, qty, category, added_by)
    values (v_name, v_qty, v_cat, nullif(btrim(coalesce(p_by, '')), ''));
  end if;

  insert into favorites (name, category) values (v_name, v_cat)
  on conflict (name) do update
    set uses = favorites.uses + 1, last_used = now(), category = excluded.category;
end $$;

create or replace function public.toggle_item(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  update items
    set checked = not checked,
        checked_at = case when checked then null else now() end
  where id = p_id;
end $$;

create or replace function public.delete_item(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  delete from items where id = p_id;
end $$;

create or replace function public.clear_checked(p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  delete from items where checked;
end $$;

create or replace function public.delete_favorite(p_pin text, p_name text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  delete from favorites where name = p_name;
end $$;

-- Nur diese Funktionen sind von der Webseite aus aufrufbar
grant execute on function
  public.login(text),
  public.get_state(text),
  public.add_item(text, text, text, text, text),
  public.toggle_item(text, uuid),
  public.delete_item(text, uuid),
  public.clear_checked(text),
  public.delete_favorite(text, text)
to anon, authenticated;
