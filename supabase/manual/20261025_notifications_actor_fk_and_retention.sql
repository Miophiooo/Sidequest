-- Run once in the Supabase SQL editor (the migration tool can't run these
-- statements). Both are optional housekeeping for the notification center.

-- 1. When an account is deleted, entries it caused for other people
--    ("@max gefällt dein Foto") go with it.
alter table public.notifications
  add constraint notifications_actor_id_fkey
  foreign key (actor_id) references auth.users (id) on delete cascade;

-- 2. Keep the center small: entries older than 60 days are removed nightly.
select cron.schedule(
  'notifications-retention',
  '29 3 * * *',
  $$delete from public.notifications
    where created_at < (now() at time zone 'UTC') - interval '60 days'$$
);
