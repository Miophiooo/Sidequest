-- Crowd Favorite badge — was designed (sql_archive/ADD_CROWD_FAVORITE_BADGE.sql)
-- but never applied: the daily-scheduler has been calling a missing function,
-- so the badge had never been awarded. Awarded once per London challenge-day
-- to the public photo with the highest (likes - dislikes) in the window.
--
-- Applied to production via MCP on 2026-06-11.

create table if not exists public.crowd_favorite_wins (
  london_date date primary key,
  user_id uuid not null references public.users_profile(id) on delete cascade,
  photo_id uuid not null references public.photos(id) on delete cascade,
  likes_count integer not null,
  dislikes_count integer not null,
  score integer not null,
  created_at timestamptz not null default now()
);

alter table public.crowd_favorite_wins enable row level security;

create policy "crowd favorite wins readable by authenticated"
on public.crowd_favorite_wins for select
to authenticated
using (true);

alter table public.users_profile
  add column if not exists crowd_favorite_count integer not null default 0;

alter table public.users_profile
  add column if not exists crowd_favorite_active_until timestamptz;

create or replace function public.award_crowd_favorite_window(
  london_date_str text,
  start_utc timestamptz,
  end_utc timestamptz
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_london_date date;
  v_photo_id uuid;
  v_user_id uuid;
  v_likes integer;
  v_dislikes integer;
  v_score integer;
  v_inserted integer;
  v_active_until timestamptz;
begin
  v_london_date := london_date_str::date;

  with window_photos as (
    select p.id as photo_id, p.user_id, p.created_at
    from public.photos p
    where p.is_public = true
      and p.created_at >= start_utc
      and p.created_at < end_utc
  ),
  likes_by_photo as (
    select l.photo_id, count(*)::int as likes_count
    from public.likes l
    join window_photos wp on wp.photo_id = l.photo_id
    group by l.photo_id
  ),
  dislikes_by_photo as (
    select d.photo_id, count(*)::int as dislikes_count
    from public.dislikes d
    join window_photos wp on wp.photo_id = d.photo_id
    group by d.photo_id
  ),
  scored as (
    select
      wp.photo_id,
      wp.user_id,
      wp.created_at,
      coalesce(lb.likes_count, 0) as likes_count,
      coalesce(db.dislikes_count, 0) as dislikes_count,
      (coalesce(lb.likes_count, 0) - coalesce(db.dislikes_count, 0))::int as score
    from window_photos wp
    left join likes_by_photo lb on lb.photo_id = wp.photo_id
    left join dislikes_by_photo db on db.photo_id = wp.photo_id
  )
  select s.photo_id, s.user_id, s.likes_count, s.dislikes_count, s.score
    into v_photo_id, v_user_id, v_likes, v_dislikes, v_score
  from scored s
  order by s.score desc, s.likes_count desc, s.created_at asc, s.photo_id asc
  limit 1;

  if v_photo_id is null then
    return json_build_object(
      'ok', true, 'london_date', v_london_date,
      'awarded', false, 'reason', 'no_photos'
    );
  end if;

  insert into public.crowd_favorite_wins (
    london_date, user_id, photo_id, likes_count, dislikes_count, score
  )
  values (v_london_date, v_user_id, v_photo_id, v_likes, v_dislikes, v_score)
  on conflict (london_date) do nothing;

  get diagnostics v_inserted = row_count;

  if v_inserted = 1 then
    v_active_until := end_utc + interval '1 day';

    update public.users_profile
      set crowd_favorite_count = coalesce(crowd_favorite_count, 0) + 1,
          crowd_favorite_active_until = v_active_until,
          joker = coalesce(joker, 0) + 3
      where id = v_user_id;

    return json_build_object(
      'ok', true, 'london_date', v_london_date, 'awarded', true,
      'user_id', v_user_id, 'photo_id', v_photo_id,
      'likes', v_likes, 'dislikes', v_dislikes, 'score', v_score,
      'joker_bonus', 3, 'active_until', v_active_until
    );
  end if;

  select user_id, photo_id, likes_count, dislikes_count, score
    into v_user_id, v_photo_id, v_likes, v_dislikes, v_score
  from public.crowd_favorite_wins
  where london_date = v_london_date;

  return json_build_object(
    'ok', true, 'london_date', v_london_date, 'awarded', false,
    'reason', 'already_awarded', 'user_id', v_user_id, 'photo_id', v_photo_id,
    'likes', v_likes, 'dislikes', v_dislikes, 'score', v_score
  );
end;
$$;

-- Only the scheduler (service role) may award.
revoke execute on function public.award_crowd_favorite_window(text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.award_crowd_favorite_window(text, timestamptz, timestamptz) to service_role;
