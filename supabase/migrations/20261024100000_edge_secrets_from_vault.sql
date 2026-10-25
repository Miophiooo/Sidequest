-- Edge functions read their shared secrets from Supabase Vault instead of
-- function env vars, so the database (cron, triggers) and the functions can
-- never drift apart and a rotation is a single vault.update_secret call.
--
-- Only callable with the service role key (auth.role() = 'service_role').

create or replace function public.edge_secret(p_name text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_name not in ('daily_scheduler_cron_secret', 'push_secret') then
    raise exception 'unknown secret %', p_name;
  end if;
  return (
    select s.decrypted_secret
    from vault.decrypted_secrets s
    where s.name = p_name
    limit 1
  );
end;
$$;

-- Rotation (2026-10-24): the old cron secret had been committed to the repo
-- (sql_archive/SCHEDULE_DAILY_SCHEDULER_PG_CRON.sql) and push_secret was only
-- 12 characters. Both get fresh 32-byte random values that never leave the
-- database.
select vault.update_secret(
  s.id,
  encode(extensions.gen_random_bytes(32), 'hex')
)
from vault.secrets s
where s.name in ('daily_scheduler_cron_secret', 'push_secret');
