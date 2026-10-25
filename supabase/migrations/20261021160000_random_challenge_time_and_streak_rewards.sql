-- Random challenge start time, streak rewards, streak warning, duel invite
-- expiry. Keep the time formula identical to lib/london_time.dart and
-- supabase/functions/daily-scheduler/index.ts.

-- ---------------------------------------------------------------------------
-- Challenge times.
-- From day index 1030 (2026-10-27) the challenge starts at a pseudo-random
-- time between 09:00 and 18:59 London; before that between 08:00 and 09:59.
create or replace function public.challenge_bounds_for_index(p_day date, p_index integer)
returns table (start_utc timestamptz, end_utc timestamptz)
language sql
stable
set search_path = ''
as $$
  with s as (
    select
      p_day + make_interval(mins => case
        when p_index < 1030 then 8 * 60 + (p_index * 7919) % 120
        else 9 * 60 + (p_index * p_index * 31 + p_index * 7919 + 101) % 600
      end) as start_local,
      case p_index % 3 when 1 then 2 else 5 end as duration_hours
  )
  select
    start_local at time zone 'Europe/London',
    least(
      start_local + make_interval(hours => duration_hours),
      p_day + time '23:59'
    ) at time zone 'Europe/London'
  from s;
$$;

create or replace function public.challenge_day_bounds(p_day date)
returns table (start_utc timestamptz, end_utc timestamptz)
language sql
stable
set search_path = ''
as $$
  select b.start_utc, b.end_utc
  from public.challenge_bounds_for_index(p_day, p_day - date '2024-01-01') b;
$$;

-- Deadline for an on-time daily post. Before the cutover, app builds on
-- devices in DST time zones counted the day index one day short in summer
-- (start minute and window length shifted), so accept the later of both ends.
create or replace function public.challenge_late_cutoff(p_day date)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select case
    when p_day - date '2024-01-01' < 1030 then greatest(
      (select b.end_utc from public.challenge_bounds_for_index(p_day, p_day - date '2024-01-01') b),
      (select b.end_utc from public.challenge_bounds_for_index(p_day, p_day - date '2024-01-01' - 1) b)
    )
    else (select b.end_utc from public.challenge_day_bounds(p_day) b)
  end;
$$;

create or replace function internal.daily_scheduler_times(p_now timestamptz default now())
returns table (
  london_date date,
  start_utc timestamptz,
  ending_soon_utc timestamptz,
  award_utc timestamptz
)
language sql
stable
set search_path = ''
as $$
  select
    d.day,
    b.start_utc,
    b.end_utc - interval '10 minutes',
    b.end_utc + interval '1 minute'
  from (select (p_now at time zone 'Europe/London')::date as day) d
  cross join lateral public.challenge_day_bounds(d.day) b;
$$;

-- Late flag and streak use the (lenient) cutoff.
create or replace function public.guard_photo_timing()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  new.created_at := now();

  if new.challenge_id is null
     and not coalesce(new.is_challenge_photo, false)
     and not coalesce(new.is_collab_extension, false) then
    new.is_late := now() > public.challenge_late_cutoff(public.active_challenge_day());
  end if;

  return new;
end;
$$;

create or replace function internal.apply_streak_on_daily_post()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active date := public.active_challenge_day();
begin
  if new.challenge_id is not null
     or coalesce(new.is_challenge_photo, false)
     or coalesce(new.is_collab_extension, false)
     or coalesce(new.is_late, false) then
    return new;
  end if;

  if now() > public.challenge_late_cutoff(v_active) then
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

-- ---------------------------------------------------------------------------
-- New users start with 2 jokers.
create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
begin
  insert into public.users_profile (id, username, joker, flames)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1)),
    2,
    0
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

alter table public.users_profile alter column joker set default 2;

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
    -- Same starting values as handle_new_user_profile() (2 jokers).
    new.joker := 2;
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

-- ---------------------------------------------------------------------------
-- Streak milestones: reaching a 3 and a 7 day streak earns a joker.
create or replace function internal.award_streak_milestone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(new.flames, 0) > coalesce(old.flames, 0)
     and new.flames in (3, 7) then
    update public.users_profile
    set joker = coalesce(joker, 0) + 1
    where id = new.id;

    insert into public.notifications (user_id, type, message, read, created_at)
    values (
      new.id,
      'streak_milestone',
      '🔥 ' || new.flames || ' Tage Streak! Du bekommst einen Joker 🃏',
      false,
      now()
    );
  end if;
  return new;
end;
$$;

-- Not "update of flames": the guard trigger changes flames on updates that
-- don't list the column (joker use), so compare the values instead.
create or replace trigger award_streak_milestone
after update on public.users_profile
for each row
when (new.flames is distinct from old.flames)
execute function internal.award_streak_milestone();

-- ---------------------------------------------------------------------------
-- Duel invites expire after 2 hours.
create or replace function public.guard_challenge_timers()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Not SECURITY DEFINER on purpose: trusted writers (sabotage_challenge,
  -- service_role) run as another role and may change timers.
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.created_at := now();
    new.expires_at := null;
    new.challenger_expires_at := null;
    new.challenged_expires_at := null;
    return new;
  end if;

  new.created_at := old.created_at;

  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    if old.status = 'pending'
       and old.challenged_id = (select auth.uid())
       and old.created_at > now() - interval '2 hours' then
      -- Accepting starts the same 30 minute window for both players.
      new.expires_at := now() + interval '30 minutes';
      new.challenger_expires_at := new.expires_at;
      new.challenged_expires_at := new.expires_at;
      return new;
    end if;
    -- Only the challenged player can accept, only a pending invite, and only
    -- within 2 hours.
    new.status := old.status;
  end if;

  new.expires_at := old.expires_at;
  new.challenger_expires_at := old.challenger_expires_at;
  new.challenged_expires_at := old.challenged_expires_at;
  return new;
end;
$$;

create or replace function public.push_on_challenge_insert()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
begin
  if new.status is distinct from 'pending'
    or new.challenged_id is null
    or new.challenger_id = new.challenged_id then
    return new;
  end if;

  perform public.enqueue_sidequest_push(
    jsonb_build_object(
      'type', 'challenged',
      'recipient_user_ids', jsonb_build_array(new.challenged_id),
      'title', 'SideQuest ⚔️',
      'body', 'Du wurdest herausgefordert! Du hast 2 Stunden zum Annehmen.',
      'data', jsonb_build_object(
        'kind', 'challenged',
        'target_tab', '1',
        'challenger_id', new.challenger_id,
        'challenge_id', new.id
      )
    )
  );

  return new;
end;
$$;

-- Expired invites are declined once a day (runs with the planner).
create or replace function internal.expire_duel_invites()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.challenges
  set status = 'declined'
  where status = 'pending'
    and created_at < now() - interval '2 hours';
$$;

-- (internal schema: no usage for anon/authenticated, so no extra revokes)

-- ---------------------------------------------------------------------------
-- Planner: also schedule the streak warning (1 hour before end) and expire
-- old duel invites.
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
  perform internal.expire_duel_invites();

  select * into r from internal.daily_scheduler_times(now());

  for v_job in
    select * from (values
      ('daily-scheduler-challenge-start', r.start_utc, 'select internal.invoke_daily_scheduler()'),
      ('daily-scheduler-streak-warning', r.ending_soon_utc - interval '50 minutes', 'select internal.invoke_daily_scheduler()'),
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
