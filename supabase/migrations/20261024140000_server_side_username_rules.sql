-- Usernames were only validated in the app: through the API anyone could
-- pick "SideQuest", "admin" or offensive names, and accounts created via
-- Google/Apple got their email local-part as public username.
--
-- Mirrors lib/username_filter.dart (length 3-10, letters/digits/_/umlauts,
-- reserved names, blocked substrings). Existing names stay untouched until
-- they are changed.

create or replace function public.username_is_allowed(p_name text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_key text := lower(coalesce(p_name, ''));
  v_compact text := replace(lower(coalesce(p_name, '')), '_', '');
  v_reserved constant text[] := array[
    'admin', 'administrator', 'support', 'help', 'hilfe', 'kontakt', 'contact',
    'mod', 'moderator', 'system', 'root', 'owner', 'official', 'team', 'staff',
    'api', 'backend', 'service', 'null', 'undefined', 'guest', 'test',
    'sidequest', 'info', 'abuse', 'security', 'noreply', 'postmaster',
    'webmaster', 'bot', 'automod', 'delete', 'deleted', 'anonymous'
  ];
  v_blocked constant text[] := array[
    'fick', 'ficken', 'scheisse', 'hurensohn', 'arschloch', 'nazi', 'hitler',
    'heil', 'vergasen', 'fuck', 'shit', 'bitch', 'asshole', 'nigger', 'nigga',
    'whore', 'slut', 'cunt', 'faggot', 'retard', 'rape', 'kys', 'missgeburt',
    'schwuchtel', 'kanake', 'spast', 'fotze', 'wichser', 'nutte', 'mongo'
  ];
begin
  if coalesce(p_name, '') !~ '^[A-Za-z0-9_ÄÖÜßäöüẞ]{3,10}$' then
    return false;
  end if;
  if v_key = any (v_reserved) or v_compact = any (v_reserved) then
    return false;
  end if;
  if exists (select 1 from unnest(v_blocked) b where strpos(v_compact, b) > 0) then
    return false;
  end if;
  return true;
end;
$$;

-- Client writes (anon/authenticated) must pass the rules; server-side
-- writers (signup trigger, admins in SQL) are not blocked here.
create or replace function public.guard_username()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.username is not distinct from old.username then
    return new;
  end if;
  if not public.username_is_allowed(new.username) then
    raise exception 'invalid_username' using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger guard_username
  before insert or update of username on public.users_profile
  for each row execute function public.guard_username();

-- Signup: use the chosen username if it is allowed and free, otherwise a
-- neutral "user123456" (never the email address). A taken name used to make
-- the whole signup fail on the unique index.
create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_name text := nullif(btrim(new.raw_user_meta_data->>'username'), '');
  v_try integer := 0;
begin
  if v_name is null
     or not public.username_is_allowed(v_name)
     or exists (
       select 1 from public.users_profile p
       where public.username_lookup_key(p.username) = public.username_lookup_key(v_name)
     ) then
    loop
      v_try := v_try + 1;
      v_name := 'user' || lpad(floor(random() * 1000000)::int::text, 6, '0');
      exit when v_try > 20 or not exists (
        select 1 from public.users_profile p
        where public.username_lookup_key(p.username) = public.username_lookup_key(v_name)
      );
    end loop;
  end if;

  insert into public.users_profile (id, username, joker, flames)
  values (new.id, v_name, 2, 0)
  on conflict (id) do nothing;

  return new;
end;
$$;
