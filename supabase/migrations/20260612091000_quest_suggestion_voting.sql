-- Community voting on quest suggestions (leaderboard tab board).
-- Votes pre-sort the queue; going live still requires manual approval via
-- approve_quest_suggestion (App-Store moderation requirement).
--
-- Applied to production via MCP on 2026-06-12.

-- Pending suggestions become visible to everyone signed in (was: own only).
create policy "suggestions: read pending for voting"
on public.quest_suggestions for select
to authenticated
using (status = 'pending');

create table public.quest_suggestion_votes (
  suggestion_id uuid not null references public.quest_suggestions(id) on delete cascade,
  user_id uuid not null references public.users_profile(id) on delete cascade,
  value smallint not null check (value in (-1, 1)),
  created_at timestamptz not null default now(),
  primary key (suggestion_id, user_id)
);

alter table public.quest_suggestion_votes enable row level security;

create policy "suggestion votes: insert own on pending"
on public.quest_suggestion_votes for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.quest_suggestions s
    where s.id = suggestion_id and s.status = 'pending'
  )
);

create policy "suggestion votes: update own"
on public.quest_suggestion_votes for update
to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

create policy "suggestion votes: delete own"
on public.quest_suggestion_votes for delete
to authenticated
using (user_id = (select auth.uid()));

create policy "suggestion votes: read own"
on public.quest_suggestion_votes for select
to authenticated
using (user_id = (select auth.uid()));

create index quest_suggestion_votes_suggestion_idx
  on public.quest_suggestion_votes (suggestion_id);

-- Board query: pending suggestions with aggregated votes + caller's own vote.
-- SECURITY DEFINER so individual votes stay private; only aggregates and the
-- caller's own vote leave the database.
create function public.get_quest_suggestion_board(p_limit int default 50)
returns table (
  id uuid,
  title text,
  description text,
  created_at timestamptz,
  author_username text,
  upvotes int,
  downvotes int,
  my_vote int
)
language sql
stable
security definer
set search_path = public
as $$
  select
    s.id,
    s.title,
    s.description,
    s.created_at,
    coalesce(up.username, '?') as author_username,
    coalesce(count(v.value) filter (where v.value = 1), 0)::int as upvotes,
    coalesce(count(v.value) filter (where v.value = -1), 0)::int as downvotes,
    coalesce((
      select vv.value::int
      from quest_suggestion_votes vv
      where vv.suggestion_id = s.id and vv.user_id = auth.uid()
    ), 0) as my_vote
  from quest_suggestions s
  join users_profile up on up.id = s.user_id
  left join quest_suggestion_votes v on v.suggestion_id = s.id
  where s.status = 'pending'
  group by s.id, up.username
  order by
    (count(v.value) filter (where v.value = 1)
      - count(v.value) filter (where v.value = -1)) desc,
    s.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 100))
$$;

revoke execute on function public.get_quest_suggestion_board(int) from public, anon;
grant execute on function public.get_quest_suggestion_board(int) to authenticated;
