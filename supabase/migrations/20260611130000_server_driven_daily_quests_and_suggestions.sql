-- Server-driven daily quest rotation + community quest suggestions.
-- The app keeps the legacy hardcoded list as offline fallback; rotation
-- anchor (2024-01-01, modulo over active quests ordered by rotation_index)
-- is identical to the legacy client logic so the displayed quest does not
-- change with this migration.
--
-- Applied to production via MCP on 2026-06-11.

-- ---- Community suggestions ----
create table public.quest_suggestions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users_profile(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 3 and 80),
  description text not null check (char_length(btrim(description)) between 10 and 200),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  review_note text,
  created_at timestamptz not null default now()
);

alter table public.quest_suggestions enable row level security;

create policy "suggestions: insert own"
on public.quest_suggestions for insert
to authenticated
with check (user_id = (select auth.uid()));

create policy "suggestions: read own"
on public.quest_suggestions for select
to authenticated
using (user_id = (select auth.uid()));

create index quest_suggestions_user_created_idx
  on public.quest_suggestions (user_id, created_at desc);
create index quest_suggestions_status_idx
  on public.quest_suggestions (status) where status = 'pending';

-- Spam guard: at most 5 suggestions per user per rolling 24h.
create function public.quest_suggestion_rate_limit()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (
    select count(*)
    from quest_suggestions
    where user_id = new.user_id
      and created_at > now() - interval '24 hours'
  ) >= 5 then
    raise exception 'suggestion_rate_limited';
  end if;
  return new;
end;
$$;

revoke execute on function public.quest_suggestion_rate_limit() from public, anon, authenticated;

create trigger trg_quest_suggestion_rate_limit
  before insert on public.quest_suggestions
  for each row execute function public.quest_suggestion_rate_limit();

-- ---- Quest catalog ----
create table public.daily_quests (
  id uuid primary key default gen_random_uuid(),
  rotation_index int not null unique,
  title_de text not null,
  title_en text not null,
  desc_de text not null,
  desc_en text not null,
  emoji text not null default '📸',
  is_active boolean not null default true,
  -- Attribution for community quests ("Quest by @user").
  created_by uuid references public.users_profile(id) on delete set null,
  source_suggestion_id uuid references public.quest_suggestions(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.daily_quests enable row level security;

create policy "daily quests readable by authenticated"
on public.daily_quests for select
to authenticated
using (true);
-- No insert/update/delete policies: catalog is curated via dashboard/service role.

-- ---- Deterministic daily pick ----
-- Same anchor + modulo as the legacy client rotation.
create function public.get_daily_quest(p_london_date date)
returns table (
  id uuid,
  title_de text,
  title_en text,
  desc_de text,
  desc_en text,
  emoji text,
  author_username text
)
language sql
stable
security invoker
set search_path = public
as $$
  with active as (
    select q.*,
      row_number() over (order by q.rotation_index) - 1 as pos,
      count(*) over () as total
    from daily_quests q
    where q.is_active
  )
  select a.id, a.title_de, a.title_en, a.desc_de, a.desc_en, a.emoji, up.username
  from active a
  left join users_profile up on up.id = a.created_by
  where a.pos = mod(p_london_date - date '2024-01-01', a.total)
$$;

revoke execute on function public.get_daily_quest(date) from public, anon;
grant execute on function public.get_daily_quest(date) to authenticated;

-- ---- Approval helper (run via dashboard/service role only) ----
-- Copies an approved suggestion into the rotation with attribution:
--   select approve_quest_suggestion('<id>', 'Titel DE', 'Title EN', 'Desc DE', 'Desc EN', '🌟');
create function public.approve_quest_suggestion(
  p_suggestion_id uuid,
  p_title_de text,
  p_title_en text,
  p_desc_de text,
  p_desc_en text,
  p_emoji text default '📸'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_suggestion quest_suggestions%rowtype;
  v_quest_id uuid;
begin
  select * into v_suggestion from quest_suggestions where id = p_suggestion_id for update;
  if not found then
    raise exception 'suggestion not found';
  end if;

  insert into daily_quests (
    rotation_index, title_de, title_en, desc_de, desc_en, emoji,
    created_by, source_suggestion_id
  )
  values (
    (select coalesce(max(rotation_index), -1) + 1 from daily_quests),
    p_title_de, p_title_en, p_desc_de, p_desc_en, p_emoji,
    v_suggestion.user_id, v_suggestion.id
  )
  returning id into v_quest_id;

  update quest_suggestions set status = 'approved' where id = p_suggestion_id;
  return v_quest_id;
end;
$$;

revoke execute on function public.approve_quest_suggestion(uuid, text, text, text, text, text) from public, anon, authenticated;
