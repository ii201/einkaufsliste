-- Einkaufsliste, Teil 3: Rezept-Katalog, Vorschläge und Entscheidungen
-- Ersetzt den zufälligen Wochen-Stapel aus Teil 2. Einmal im SQL Editor ausführen.

alter table public.recipes add column if not exists thumb text;
alter table public.recipes add column if not exists rating numeric;
alter table public.recipes add column if not exists rating_count int;
alter table public.recipes add column if not exists chips text[] not null default '{}';
alter table public.recipes add column if not exists vegetarian boolean not null default false;
alter table public.recipes add column if not exists in_catalog boolean not null default false;

-- Ein Vorschlag: einer schlägt vor, der/die andere entscheidet
create table if not exists public.proposals (
  id uuid primary key default gen_random_uuid(),
  recipe_id text not null references public.recipes (id) on delete cascade,
  proposed_by text not null,
  status text not null default 'offen' check (status in ('offen', 'ja', 'nein')),
  decided_by text,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  cooked_at timestamptz
);
create index if not exists proposals_open on public.proposals (status) where cooked_at is null;

alter table public.proposals enable row level security;
revoke all on public.proposals from anon, authenticated;
grant all on public.proposals to service_role;

-- Alter Wochen-Stapel wird nicht mehr gebraucht
drop function if exists public.get_cooking(text, text);
drop function if exists public.vote(text, text, text, boolean);
drop function if exists public.force_match(text, text);
drop function if exists public.remove_match(text, text);

create or replace function public.get_catalog(p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  return coalesce((
    select json_agg(json_build_object(
      'id', id, 'name', name, 'thumb', coalesce(thumb, image), 'image', image, 'url', url,
      'total_time', total_time, 'rating', rating, 'rating_count', rating_count,
      'chips', chips, 'veg', vegetarian
    ) order by rating desc nulls last, rating_count desc nulls last)
    from recipes where in_catalog
  ), '[]'::json);
end $$;

create or replace function public._proposal_json(p public.proposals) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', p.id, 'recipe_id', p.recipe_id, 'proposed_by', p.proposed_by, 'status', p.status,
    'decided_by', p.decided_by, 'created_at', p.created_at,
    'name', r.name, 'image', r.image, 'thumb', coalesce(r.thumb, r.image), 'url', r.url,
    'total_time', r.total_time, 'rating', r.rating, 'ingredients', r.ingredients
  ) from recipes r where r.id = p.recipe_id
$$;
revoke execute on function public._proposal_json(public.proposals) from public, anon, authenticated;

-- Alles für den Koch-Tab: offene Vorschläge, Plan, Vorrat
create or replace function public.get_kochen(p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  return json_build_object(
    'open', coalesce((select json_agg(_proposal_json(p) order by p.created_at desc)
                      from proposals p where p.status = 'offen'), '[]'::json),
    'plan', coalesce((select json_agg(_proposal_json(p) order by p.decided_at)
                      from proposals p where p.status = 'ja' and p.cooked_at is null), '[]'::json),
    'pantry', coalesce((select json_agg(name order by name) from pantry), '[]'::json)
  );
end $$;

-- Vorschlagen. Hat der/die andere dasselbe schon vorgeschlagen, ist es direkt ein Ja.
create or replace function public.propose(p_pin text, p_person text, p_recipe text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_person text := btrim(coalesce(p_person, '')); p proposals;
begin
  perform _assert_pin(p_pin);
  if v_person = '' then raise exception 'no person'; end if;
  if not exists (select 1 from recipes where id = p_recipe and in_catalog) then raise exception 'unknown recipe'; end if;

  select * into p from proposals
    where recipe_id = p_recipe and cooked_at is null and status in ('offen', 'ja')
    order by created_at desc limit 1;
  if found then
    if p.status = 'offen' and lower(p.proposed_by) <> lower(v_person) then
      update proposals set status = 'ja', decided_by = v_person, decided_at = now()
        where id = p.id returning * into p;
      return json_build_object('result', 'match', 'proposal', _proposal_json(p));
    end if;
    return json_build_object('result', 'exists', 'proposal', _proposal_json(p));
  end if;

  insert into proposals (recipe_id, proposed_by) values (p_recipe, v_person) returning * into p;
  return json_build_object('result', 'proposed', 'proposal', _proposal_json(p));
end $$;

-- Eigenen offenen Vorschlag zurückziehen
create or replace function public.withdraw(p_pin text, p_person text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  delete from proposals where id = p_id and status = 'offen' and lower(proposed_by) = lower(btrim(p_person));
end $$;

-- Über einen Vorschlag der/des anderen entscheiden
create or replace function public.decide(p_pin text, p_person text, p_id uuid, p_yes boolean) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare p proposals;
begin
  perform _assert_pin(p_pin);
  update proposals
    set status = case when p_yes then 'ja' else 'nein' end, decided_by = btrim(p_person), decided_at = now()
    where id = p_id and status = 'offen' and lower(proposed_by) <> lower(btrim(p_person))
    returning * into p;
  if not found then return null; end if;
  return _proposal_json(p);
end $$;

-- Plan: gekocht abhaken oder wieder streichen
create or replace function public.mark_cooked(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  update proposals set cooked_at = now() where id = p_id and status = 'ja';
end $$;

create or replace function public.unplan(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  update proposals set status = 'nein' where id = p_id and status = 'ja' and cooked_at is null;
end $$;

grant execute on function
  public.get_catalog(text),
  public.get_kochen(text),
  public.propose(text, text, text),
  public.withdraw(text, text, uuid),
  public.decide(text, text, uuid, boolean),
  public.mark_cooked(text, uuid),
  public.unplan(text, uuid)
to anon, authenticated;
