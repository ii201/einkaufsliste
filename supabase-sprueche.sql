-- Liebe Sprüche: einer schreibt, der/die andere sieht einmal am Tag den nächsten.
-- Einmal im Supabase SQL Editor ausführen, nach supabase.sql.

create table if not exists public.love_notes (
  id uuid primary key default gen_random_uuid(),
  text text not null check (length(text) between 1 and 200),
  created_by text not null,
  created_at timestamptz not null default now(),
  shown_at timestamptz
);
alter table public.love_notes enable row level security;
revoke all on public.love_notes from anon, authenticated;
grant all on public.love_notes to service_role;

create or replace function public.add_note(p_pin text, p_text text, p_by text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_text text := btrim(coalesce(p_text, ''));
begin
  perform _assert_pin(p_pin);
  if v_text = '' then raise exception 'empty note'; end if;
  insert into love_notes (text, created_by) values (left(v_text, 200), btrim(coalesce(p_by, '')));
end $$;

-- Eigene Sprüche, die noch nicht gezeigt wurden
create or replace function public.my_notes(p_pin text, p_by text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  return coalesce((
    select json_agg(json_build_object('id', id, 'text', text) order by created_at)
    from love_notes where shown_at is null and lower(created_by) = lower(btrim(coalesce(p_by, '')))
  ), '[]'::json);
end $$;

create or replace function public.delete_note(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _assert_pin(p_pin);
  delete from love_notes where id = p_id and shown_at is null;
end $$;

-- Ältesten noch nicht gezeigten Spruch der anderen Person holen und als gezeigt markieren
create or replace function public.next_note(p_pin text, p_person text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v json;
begin
  perform _assert_pin(p_pin);
  update love_notes n set shown_at = now()
  where n.id = (
    select id from love_notes
    where shown_at is null and lower(created_by) <> lower(btrim(coalesce(p_person, '')))
    order by created_at limit 1
  )
  returning json_build_object('text', n.text, 'by', n.created_by) into v;
  return v;
end $$;

grant execute on function
  public.add_note(text, text, text),
  public.my_notes(text, text),
  public.delete_note(text, uuid),
  public.next_note(text, text)
to anon, authenticated;
