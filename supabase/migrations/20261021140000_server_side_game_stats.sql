-- Move game stats (joker, flames, streak day, crowd favorite) and duel results
-- to the server so clients can no longer cheat by writing them directly.
--
-- Backwards compatible on purpose: already installed app builds keep working.
-- Their direct writes to protected columns are silently ignored, and the server
-- computes the same values itself:
--   - flames / last_posted_date: AFTER INSERT trigger on photos (daily post)
--   - joker use ("skip with joker"): the one legit client transition
--     (joker - 1, joker_used_today -> true) is accepted, the rest recomputed
--   - duel winner: computed from challenge photos + likes when a client marks
--     a challenge completed; manual winner_id writes are ignored
--   - duel joker: awarded once per day by the server (fixes double award:
--     trigger +1 and app +1)
--   - daily reset of joker_used_today / broken streaks: cron at challenge start
-- Trusted writers are SECURITY DEFINER functions owned by postgres and
-- service_role (edge functions); only the anon/authenticated roles are guarded.
-- Trigger functions live in the `internal` schema so they aren't exposed via the API.

-- ---------------------------------------------------------------------------
-- Challenge-day helpers (same formula as lib/london_time.dart and
-- lib/daily_challenges.dart).
create or replace function public.challenge_day_bounds(p_day date)
returns table (start_utc timestamptz, end_utc timestamptz)
language sql
stable
set search_path = ''
as $$
  with s as (
    select
      p_day + time '08:00' + make_interval(mins => ((p_day - date '2024-01-01') * 7919) % 120) as start_local,
      case (p_day - date '2024-01-01') % 3 when 1 then 2 else 5 end as duration_hours
  )
  select
    start_local at time zone 'Europe/London',
    least(
      start_local + make_interval(hours => duration_hours),
      p_day + time '23:59'
    ) at time zone 'Europe/London'
  from s;
$$;

-- The challenge day that is active at p_now (before today's start it is still
-- yesterday's challenge day).
create or replace function public.active_challenge_day(p_now timestamptz default now())
returns date
language sql
stable
set search_path = ''
as $$
  select case
    when p_now < (select b.start_utc from public.challenge_day_bounds(d) b) then d - 1
    else d
  end
  from (select (p_now at time zone 'Europe/London')::date as d) x;
$$;

-- ---------------------------------------------------------------------------
-- users_profile: protect game stats from client writes.
create or replace function public.guard_users_profile_game_stats()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_active text;
  v_prev text;
  v_joker_use boolean;
begin
  -- Not SECURITY DEFINER on purpose: current_user is the caller here, or the
  -- owner of a trusted SECURITY DEFINER function that issued the write.
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- Same starting values as handle_new_user_profile().
    new.joker := 1;
    new.joker_used_today := false;
    new.flames := 0;
    new.last_posted_date := null;
    new.crowd_favorite_count := 0;
    new.crowd_favorite_active_until := null;
    return new;
  end if;

  v_active := to_char(public.active_challenge_day(), 'YYYY-MM-DD');
  v_prev := to_char(public.active_challenge_day() - 1, 'YYYY-MM-DD');

  -- "Skip with joker": spend exactly one joker, once per challenge day.
  v_joker_use :=
    coalesce(old.joker, 0) >= 1
    and new.joker = old.joker - 1
    and coalesce(new.joker_used_today, false)
    and not (coalesce(old.joker_used_today, false) and old.last_posted_date = v_active);

  new.joker := old.joker;
  new.joker_used_today := old.joker_used_today;
  new.flames := old.flames;
  new.last_posted_date := old.last_posted_date;
  new.crowd_favorite_count := old.crowd_favorite_count;
  new.crowd_favorite_active_until := old.crowd_favorite_active_until;

  if v_joker_use then
    new.joker := old.joker - 1;
    new.joker_used_today := true;
    new.flames := case
      when old.last_posted_date = v_active then old.flames
      when old.last_posted_date = v_prev then coalesce(old.flames, 0) + 1
      else 1
    end;
    new.last_posted_date := v_active;
  end if;

  return new;
end;
$$;

create or replace trigger guard_users_profile_game_stats
before insert or update on public.users_profile
for each row execute function public.guard_users_profile_game_stats();

-- ---------------------------------------------------------------------------
-- photos: a daily post (not late, not a duel/collab photo) advances the streak.
create or replace function internal.apply_streak_on_daily_post()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active date := public.active_challenge_day();
  v_end timestamptz;
begin
  if new.challenge_id is not null
     or coalesce(new.is_challenge_photo, false)
     or coalesce(new.is_collab_extension, false)
     or coalesce(new.is_late, false) then
    return new;
  end if;

  select b.end_utc into v_end from public.challenge_day_bounds(v_active) b;
  if now() > v_end then
    return new; -- posted after the window: late, no flames
  end if;

  update public.users_profile p
  set
    flames = case
      when p.last_posted_date = to_char(v_active, 'YYYY-MM-DD') then p.flames
      when p.last_posted_date = to_char(v_active - 1, 'YYYY-MM-DD') then coalesce(p.flames, 0) + 1
      else 1
    end,
    last_posted_date = to_char(v_active, 'YYYY-MM-DD')
  where p.id = new.user_id;

  return new;
end;
$$;

create or replace trigger apply_streak_on_daily_post
after insert on public.photos
for each row execute function internal.apply_streak_on_daily_post();

-- ---------------------------------------------------------------------------
-- challenges: winner is computed by the server.
create or replace function internal.guard_challenge_result()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_challenger_expires timestamptz;
  v_challenged_expires timestamptz;
  v_challenger_photo uuid;
  v_challenged_photo uuid;
  v_boundary timestamptz;
  v_challenger_likes integer;
  v_challenged_likes integer;
begin
  if tg_op = 'INSERT' then
    new.completed_at := null;
    new.winner_id := null;
    return new;
  end if;

  -- Results are final once set.
  if old.completed_at is not null then
    new.completed_at := old.completed_at;
    new.winner_id := old.winner_id;
    return new;
  end if;

  if new.completed_at is null then
    new.winner_id := old.winner_id;
    return new;
  end if;

  -- A client asks to complete the challenge: only once both upload windows
  -- closed (missing timers count as closed, like the app does).
  v_challenger_expires := coalesce(old.challenger_expires_at, old.expires_at);
  v_challenged_expires := coalesce(old.challenged_expires_at, old.expires_at);
  if (v_challenger_expires is not null and now() < v_challenger_expires)
     or (v_challenged_expires is not null and now() < v_challenged_expires) then
    new.completed_at := null;
    new.winner_id := old.winner_id;
    new.status := old.status;
    return new;
  end if;

  select ph.id into v_challenger_photo
  from public.photos ph
  where ph.challenge_id = old.id and ph.user_id = old.challenger_id
  order by ph.created_at desc
  limit 1;

  select ph.id into v_challenged_photo
  from public.photos ph
  where ph.challenge_id = old.id and ph.user_id = old.challenged_id
  order by ph.created_at desc
  limit 1;

  if v_challenger_photo is not null and v_challenged_photo is not null then
    -- Both posted: likes count until the next challenge day starts.
    select b.start_utc into v_boundary
    from public.challenge_day_bounds(public.active_challenge_day()) b;

    if old.created_at >= v_boundary then
      new.completed_at := null;
      new.winner_id := old.winner_id;
      new.status := old.status;
      return new;
    end if;

    select count(*) into v_challenger_likes
    from public.likes l
    where l.photo_id = v_challenger_photo and l.created_at < v_boundary;

    select count(*) into v_challenged_likes
    from public.likes l
    where l.photo_id = v_challenged_photo and l.created_at < v_boundary;

    new.winner_id := case
      when v_challenger_likes > v_challenged_likes then old.challenger_id
      when v_challenged_likes > v_challenger_likes then old.challenged_id
      else null -- tie
    end;
  elsif v_challenger_photo is not null then
    new.winner_id := old.challenger_id;
  elsif v_challenged_photo is not null then
    new.winner_id := old.challenged_id;
  else
    new.winner_id := null;
  end if;

  new.completed_at := now();
  return new;
end;
$$;

create or replace trigger guard_challenge_result
before insert or update on public.challenges
for each row execute function internal.guard_challenge_result();

-- The award trigger function moves to the internal schema (trigger functions
-- don't belong in the API schema); the trigger keeps pointing at it.
alter function public.award_joker_on_challenge_completion() set schema internal;

-- Award at most one duel joker per day (and none if a joker was used today).
-- Replaces the old version, which ran with the caller's rights and stacked
-- with the app's own +1.
create or replace function internal.award_joker_on_challenge_completion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today_start timestamptz := ((now() at time zone 'Europe/London')::date)::timestamp
    at time zone 'Europe/London';
begin
  if new.completed_at is not null
     and old.completed_at is null
     and new.winner_id is not null
     and not exists (
       select 1 from public.challenges c
       where c.winner_id = new.winner_id
         and c.id <> new.id
         and c.completed_at >= v_today_start
     )
     and not exists (
       select 1 from public.users_profile p
       where p.id = new.winner_id and coalesce(p.joker_used_today, false)
     ) then
    update public.users_profile
    set joker = coalesce(joker, 0) + 1
    where id = new.winner_id;
  end if;
  return new;
end;
$$;

-- Sabotage spends a joker: it has to be a trusted writer now. It already
-- checks auth.uid() and participation itself.
alter function public.sabotage_challenge(uuid, integer) security definer;

-- ---------------------------------------------------------------------------
-- Daily reset (was done by each app on start): runs one minute after the
-- challenge starts, scheduled by the daily-scheduler planner.
create or replace function internal.reset_daily_game_flags()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active text := to_char(public.active_challenge_day(), 'YYYY-MM-DD');
  v_prev text := to_char(public.active_challenge_day() - 1, 'YYYY-MM-DD');
begin
  update public.users_profile
  set joker_used_today = false
  where joker_used_today
    and last_posted_date is distinct from v_active;

  update public.users_profile
  set flames = 0
  where coalesce(flames, 0) <> 0
    and (last_posted_date is null or last_posted_date not in (v_active, v_prev));
end;
$$;

revoke all on function internal.reset_daily_game_flags() from public, anon, authenticated;

create or replace function internal.plan_daily_scheduler_runs()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_job record;
begin
  select * into r from internal.daily_scheduler_times(now());

  for v_job in
    select * from (values
      ('daily-scheduler-challenge-start', r.start_utc, 'select internal.invoke_daily_scheduler()'),
      ('daily-scheduler-challenge-ending', r.ending_soon_utc, 'select internal.invoke_daily_scheduler()'),
      ('daily-scheduler-crowd-favorite', r.award_utc, 'select internal.invoke_daily_scheduler()'),
      ('daily-game-reset', r.start_utc + interval '1 minute', 'select internal.reset_daily_game_flags()')
    ) as j(name, at_utc, command)
  loop
    -- pg_cron runs in GMT (cron.timezone), so use UTC components.
    -- A job that already passed today would only fire again next year on the
    -- same date, but it is re-planned (overwritten) every day before that.
    perform cron.schedule(
      v_job.name,
      format(
        '%s %s %s %s *',
        extract(minute from v_job.at_utc at time zone 'UTC')::int,
        extract(hour from v_job.at_utc at time zone 'UTC')::int,
        extract(day from v_job.at_utc at time zone 'UTC')::int,
        extract(month from v_job.at_utc at time zone 'UTC')::int
      ),
      v_job.command
    );
  end loop;
end;
$$;

revoke all on function internal.plan_daily_scheduler_runs() from public, anon, authenticated;

select internal.plan_daily_scheduler_runs();
