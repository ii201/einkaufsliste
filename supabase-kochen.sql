-- Einkaufsliste, Teil 2: Kochen mit Cookidoo-Vorschlägen
-- Einmal im Supabase SQL Editor ausführen (nach supabase.sql).

-- Längere Mengen, weil Rezept-Zutaten zusammengefasst werden ("200 g + 1 Stück")
alter table public.items drop constraint if exists items_qty_check;
alter table public.items add constraint items_qty_check check (length(qty) <= 40);
alter table public.items add column if not exists source_recipe text;

create table if not exists public.recipes (
  id text primary key,
  name text not null,
  image text,
  url text not null,
  total_time int,
  source text not null default 'neu',
  ingredients jsonb not null default '[]',
  updated_at timestamptz not null default now()
);

-- Vorschläge pro Woche (week = Montag der Kochwoche)
create table if not exists public.suggestions (
  week date not null,
  recipe_id text not null references public.recipes (id) on delete cascade,
  position int not null default 0,
  primary key (week, recipe_id)
);

create table if not exists public.votes (
  week date not null,
  recipe_id text not null,
  person text not null,
  liked boolean not null,
  voted_at timestamptz not null default now(),
  primary key (week, recipe_id, person)
);

-- Treffer = wird diese Woche gekocht
create table if not exists public.cooked (
  week date not null,
  recipe_id text not null references public.recipes (id) on delete cascade,
  matched_at timestamptz not null default now(),
  primary key (week, recipe_id)
);

-- Was immer im Haus ist und nicht auf die Liste soll
create table if not exists public.pantry (name text primary key);
insert into public.pantry (name) values
  ('Salz'), ('Pfeffer'), ('Wasser'), ('Öl'), ('Zucker'), ('Mehl'),
  ('Gewürzpaste'), ('Paprikapulver'), ('Muskat'), ('Essig'), ('Brühe')
on conflict do nothing;

create table if not exists public.push_subs (
  endpoint text primary key,
  p256dh text not null,
  auth text not null,
  person text,
  created_at timestamptz not null default now()
);

alter table public.recipes enable row level security;
alter table public.suggestions enable row level security;
alter table public.votes enable row level security;
alter table public.cooked enable row level security;
alter table public.pantry enable row level security;
alter table public.push_subs enable row level security;
revoke all on public.recipes, public.suggestions, public.votes, public.cooked, public.pantry, public.push_subs
  from anon, authenticated;
-- Der Samstags-Abruf schreibt mit dem geheimen Schlüssel (service_role)
grant all on public.recipes, public.suggestions, public.votes, public.cooked, public.pantry, public.push_subs, public.items
  to service_role;

create or replace function public.get_cooking(p_pin text, p_person text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare w date;
begin
  perform _assert_pin(p_pin);
  select max(week) into w from suggestions;
  return json_build_object(
    'week', w,
    'recipes', coalesce((
      select json_agg(json_build_object(
        'id', r.id, 'name', r.name, 'image', r.image, 'url', r.url,
        'total_time', r.total_time, 'source', r.source, 'ingredients', r.ingredients,
        'my_vote', (select v.liked from votes v
                    where v.week = w and v.recipe_id = r.id and lower(v.person) = lower(btrim(p_person))),
        'matched', exists (select 1 from cooked c where c.week = w and c.recipe_id = r.id)
      ) order by s.position)
      from suggestions s join recipes r on r.id = s.recipe_id
      where s.week = w
    ), '[]'::json),
    'pantry', coalesce((select json_agg(name order by name) from pantry), '[]'::json)
  );
end $$;

-- Abstimmen. Liefert new_match = true genau einmal, wenn zwei Personen dasselbe Rezept mögen.
create or replace function public.vote(p_pin text, p_person text, p_recipe text, p_liked boolean) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare w date; n int; new_match boolean := false;
begin
  perform _assert_pin(p_pin);
  if coalesce(btrim(p_person), '') = '' then raise exception 'no person'; end if;
  select max(week) into w from suggestions;
  if not exists (select 1 from suggestions where week = w and recipe_id = p_recipe) then
    raise exception 'unknown recipe';
  end if;
  insert into votes (week, recipe_id, person, liked) values (w, p_recipe, btrim(p_person), p_liked)
  on conflict (week, recipe_id, person) do update set liked = excluded.liked, voted_at = now();
  select count(distinct lower(person)) into n from votes where week = w and recipe_id = p_recipe and liked;
  if n >= 2 then
    insert into cooked (week, recipe_id) values (w, p_recipe) on conflict do nothing;
    get diagnostics n = row_count;
    new_match := n > 0;
  end if;
  return json_build_object('new_match', new_match);
end $$;

-- "Trotzdem kochen", auch ohne zweite Stimme
create or replace function public.force_match(p_pin text, p_recipe text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare w date; n int;
begin
  perform _assert_pin(p_pin);
  select max(week) into w from suggestions;
  insert into cooked (week, recipe_id)
    select w, p_recipe where exists (select 1 from suggestions where week = w and recipe_id = p_recipe)
  on conflict do nothing;
  get diagnostics n = row_count;
  return json_build_object('new_match', n > 0);
end $$;

create or replace function public.remove_match(p_pin text, p_recipe text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  delete from cooked where week = (select max(week) from suggestions) and recipe_id = p_recipe;
end $$;

-- Zutaten mehrerer Artikel auf einmal auf die Liste; gleiche Artikel werden zusammengefasst
create or replace function public.add_items_bulk(p_pin text, p_items jsonb, p_by text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare it jsonb; v_name text; v_qty text; v_cat text; v_rec text;
begin
  perform _assert_pin(p_pin);
  for it in select * from jsonb_array_elements(p_items) loop
    v_name := left(btrim(coalesce(it->>'name', '')), 80);
    continue when v_name = '';
    v_qty := left(nullif(btrim(coalesce(it->>'qty', '')), ''), 40);
    v_cat := coalesce(nullif(btrim(coalesce(it->>'category', '')), ''), 'Sonstiges');
    v_rec := left(nullif(btrim(coalesce(it->>'recipe', '')), ''), 80);
    if exists (select 1 from items where lower(name) = lower(v_name) and not checked) then
      update items set
        qty = left(case when qty is null then v_qty when v_qty is null then qty else qty || ' + ' || v_qty end, 40),
        source_recipe = case when source_recipe is null then v_rec
                             when v_rec is null or source_recipe = v_rec then source_recipe
                             else 'mehrere Rezepte' end
      where lower(name) = lower(v_name) and not checked;
    else
      insert into items (name, qty, category, added_by, source_recipe)
      values (v_name, v_qty, v_cat, nullif(btrim(coalesce(p_by, '')), ''), v_rec);
    end if;
  end loop;
end $$;

create or replace function public.set_pantry(p_pin text, p_names text[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  delete from pantry where true;
  insert into pantry (name)
    select distinct left(btrim(n), 40) from unnest(p_names) n where btrim(n) <> ''
  on conflict do nothing;
end $$;

create or replace function public.save_push(p_pin text, p_endpoint text, p_p256dh text, p_auth text, p_person text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  insert into push_subs (endpoint, p256dh, auth, person) values (p_endpoint, p_p256dh, p_auth, p_person)
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, person = excluded.person;
end $$;

grant execute on function
  public.get_cooking(text, text),
  public.vote(text, text, text, boolean),
  public.force_match(text, text),
  public.remove_match(text, text),
  public.add_items_bulk(text, jsonb, text),
  public.set_pantry(text, text[]),
  public.save_push(text, text, text, text, text)
to anon, authenticated;
