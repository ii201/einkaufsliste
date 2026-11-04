-- Kasse: gemeinsame Haushaltskosten mit laufendem Saldo zwischen zwei Personen.
-- Einmal im Supabase SQL Editor ausführen, nach supabase.sql.
--
-- kind:    'ausgabe', 'einnahme' oder 'ausgleich' (Überweisung von paid_by an share)
-- paid_by: wer bezahlt bzw. das Geld bekommen hat
-- share:   wer die Kosten trägt bzw. wem die Einnahme zusteht: 'beide' oder ein Name

create table if not exists public.money_fixed (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('ausgabe', 'einnahme')),
  title text not null check (length(title) between 1 and 80),
  amount numeric(10, 2) not null check (amount > 0),
  paid_by text not null,
  share text not null,
  category text,
  since date not null,   -- erster Monat (immer der 1.)
  until date,            -- letzter Monat, null = läuft weiter
  created_at timestamptz not null default now()
);

create table if not exists public.money_entries (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('ausgabe', 'einnahme', 'ausgleich')),
  title text not null check (length(title) between 1 and 80),
  amount numeric(10, 2) not null check (amount > 0),
  paid_by text not null,
  share text not null,
  category text,
  day date not null,
  fixed_id uuid references public.money_fixed(id) on delete cascade,
  created_by text,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create unique index if not exists money_entries_fixed_month on public.money_entries (fixed_id, day) where fixed_id is not null;

alter table public.money_fixed enable row level security;
alter table public.money_entries enable row level security;
revoke all on public.money_fixed, public.money_entries from anon, authenticated;
grant all on public.money_fixed, public.money_entries to service_role;

create or replace function public._this_month() returns date
language sql stable as $$ select date_trunc('month', (now() at time zone 'Europe/Berlin'))::date $$;

-- Alles laden; Fixkosten bis einschließlich diesem Monat als Einträge anlegen
create or replace function public.get_money(p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  insert into money_entries (kind, title, amount, paid_by, share, category, day, fixed_id, created_by)
  select f.kind, f.title, f.amount, f.paid_by, f.share, f.category, m::date, f.id, 'Fixkosten'
  from money_fixed f,
       generate_series(f.since, least(coalesce(f.until, _this_month()), _this_month()), interval '1 month') m
  on conflict (fixed_id, day) where fixed_id is not null do nothing;

  return json_build_object(
    'entries', coalesce((
      select json_agg(e order by e.day desc, e.created_at desc) from (
        select id, kind, title, amount, paid_by, share, category, day, fixed_id, created_by, created_at
        from money_entries where deleted_at is null
      ) e
    ), '[]'::json),
    'fixed', coalesce((
      select json_agg(f order by f.kind, f.title) from (
        select id, kind, title, amount, paid_by, share, category, since, until
        from money_fixed where until is null or until >= _this_month()
      ) f
    ), '[]'::json),
    'month', _this_month()
  );
end $$;

create or replace function public.save_entry(
  p_pin text, p_id uuid, p_kind text, p_title text, p_amount numeric,
  p_paid_by text, p_share text, p_category text, p_day date, p_by text
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  perform _assert_pin(p_pin);
  if p_id is null then
    insert into money_entries (kind, title, amount, paid_by, share, category, day, created_by)
    values (p_kind, btrim(p_title), round(p_amount, 2), p_paid_by, p_share, nullif(p_category, ''),
            coalesce(p_day, (now() at time zone 'Europe/Berlin')::date), nullif(btrim(coalesce(p_by, '')), ''))
    returning id into v_id;
  else
    -- Fixkosten-Einträge behalten ihren Monat; geändert wird nur dieser eine Monat
    update money_entries set kind = p_kind, title = btrim(p_title), amount = round(p_amount, 2),
      paid_by = p_paid_by, share = p_share, category = nullif(p_category, ''),
      day = case when fixed_id is null then coalesce(p_day, day) else day end
    where id = p_id
    returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function public.delete_entry(p_pin text, p_id uuid, p_restore boolean default false) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  update money_entries set deleted_at = case when p_restore then null else now() end where id = p_id;
end $$;

-- Neue Fixkosten ab p_from (Monat) oder bestehende ab diesem Monat ändern
create or replace function public.save_fixed(
  p_pin text, p_id uuid, p_kind text, p_title text, p_amount numeric,
  p_paid_by text, p_share text, p_category text, p_from date
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  perform _assert_pin(p_pin);
  if p_id is null then
    insert into money_fixed (kind, title, amount, paid_by, share, category, since)
    values (p_kind, btrim(p_title), round(p_amount, 2), p_paid_by, p_share, nullif(p_category, ''),
            date_trunc('month', coalesce(p_from, _this_month()))::date)
    returning id into v_id;
  else
    update money_fixed set kind = p_kind, title = btrim(p_title), amount = round(p_amount, 2),
      paid_by = p_paid_by, share = p_share, category = nullif(p_category, '')
    where id = p_id returning id into v_id;
    update money_entries set kind = p_kind, title = btrim(p_title), amount = round(p_amount, 2),
      paid_by = p_paid_by, share = p_share, category = nullif(p_category, '')
    where fixed_id = p_id and day >= _this_month() and deleted_at is null;
  end if;
  return v_id;
end $$;

-- Fixkosten beenden (dieser Monat zählt noch) oder ganz löschen, falls aus Versehen angelegt
create or replace function public.end_fixed(p_pin text, p_id uuid, p_remove boolean default false) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  if p_remove then
    delete from money_fixed where id = p_id;
  else
    update money_fixed set until = _this_month() where id = p_id;
  end if;
end $$;

revoke execute on function public._this_month() from public, anon, authenticated;
grant execute on function
  public.get_money(text),
  public.save_entry(text, uuid, text, text, numeric, text, text, text, date, text),
  public.delete_entry(text, uuid, boolean),
  public.save_fixed(text, uuid, text, text, numeric, text, text, text, date),
  public.end_fixed(text, uuid, boolean)
to anon, authenticated;
