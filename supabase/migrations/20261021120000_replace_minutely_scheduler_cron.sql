-- Replace the every-minute `daily-scheduler` cron job with precise daily runs.
--
-- Why: the job `daily-scheduler-every-minute` fired 1440x/day. Every run writes
-- 1 insert + 4 updates into cron.job_run_details (cron.log_run cannot be turned
-- off on Supabase) plus a pg_net request/response row. That was by far the
-- largest source of Disk IO on the project, even though the edge function only
-- does real work ~3 times per day.
--
-- Now: a planner runs twice a day, computes today's event times (same formula
-- as lib/london_time.dart + supabase/functions/daily-scheduler) and schedules
-- exactly one cron run per event:
--   - challenge start
--   - 10 minutes before challenge end
--   - crowd favorite award (1 minute after end)
-- The edge function itself is unchanged; it still decides what to do based on
-- the current time and is idempotent via push_cron_runs.

create schema if not exists internal;
revoke all on schema internal from public, anon, authenticated;

-- The x-cron-secret lives in Vault instead of in the cron command text.
-- On the existing project it is copied from the old job, so it never lands in git.
-- On a fresh project create it manually:
--   select vault.create_secret('<CRON_SECRET>', 'daily_scheduler_cron_secret');
do $$
declare
  v_secret text;
begin
  if exists (select 1 from vault.secrets where name = 'daily_scheduler_cron_secret') then
    return;
  end if;

  select substring(command from '''x-cron-secret'',\s*''([^'']+)''')
  into v_secret
  from cron.job
  where jobname = 'daily-scheduler-every-minute';

  if v_secret is null then
    raise notice 'Vault secret daily_scheduler_cron_secret missing; create it manually.';
    return;
  end if;

  perform vault.create_secret(
    v_secret,
    'daily_scheduler_cron_secret',
    'x-cron-secret header for the daily-scheduler edge function'
  );
end $$;

-- Today's event times in UTC. Keep in sync with lib/london_time.dart and
-- lib/daily_challenges.dart (kDailyChallengeDifficulties: medium, easy, medium).
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
  with d as (
    select (p_now at time zone 'Europe/London')::date as day
  ),
  s as (
    select day, (day - date '2024-01-01') as n from d
  ),
  t as (
    select
      day,
      day + time '08:00' + make_interval(mins => (n * 7919) % 120) as start_local,
      case n % 3 when 1 then 2 else 5 end as duration_hours
    from s
  )
  select
    day,
    start_local at time zone 'Europe/London',
    (start_local + make_interval(hours => duration_hours) - interval '10 minutes')
      at time zone 'Europe/London',
    (start_local + make_interval(hours => duration_hours) + interval '1 minute')
      at time zone 'Europe/London'
  from t;
$$;

create or replace function internal.invoke_daily_scheduler()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'daily_scheduler_cron_secret';

  if v_secret is null then
    raise exception 'Vault secret daily_scheduler_cron_secret is missing';
  end if;

  -- cron fires right at the minute boundary; give the edge function a few
  -- seconds so its "now >= target" check can never land just before the target.
  perform pg_sleep(5);

  return net.http_post(
    url := 'https://cuvmtajkzgxroedmvfwu.supabase.co/functions/v1/daily-scheduler',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-cron-secret', v_secret
    ),
    body := '{}'::jsonb
  );
end;
$$;

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
      ('daily-scheduler-challenge-start', r.start_utc),
      ('daily-scheduler-challenge-ending', r.ending_soon_utc),
      ('daily-scheduler-crowd-favorite', r.award_utc)
    ) as j(name, at_utc)
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
      'select internal.invoke_daily_scheduler()'
    );
  end loop;
end;
$$;

revoke all on function internal.daily_scheduler_times(timestamptz) from public, anon, authenticated;
revoke all on function internal.invoke_daily_scheduler() from public, anon, authenticated;
revoke all on function internal.plan_daily_scheduler_runs() from public, anon, authenticated;

-- Drop the minutely job.
select cron.unschedule(jobid) from cron.job where jobname = 'daily-scheduler-every-minute';

-- Plan at 00:05 UTC (before the earliest possible start, 07:00 UTC in summer)
-- and again at 06:00 UTC as a retry in case the first run failed.
select cron.schedule(
  'daily-scheduler-planner',
  '5 0,6 * * *',
  'select internal.plan_daily_scheduler_runs()'
);

-- Plan today right away.
select internal.plan_daily_scheduler_runs();
