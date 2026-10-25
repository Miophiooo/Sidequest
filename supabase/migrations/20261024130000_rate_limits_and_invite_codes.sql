-- Rate limits per user and action (fixed window, one row per user/action, so
-- the table never grows beyond users x actions) and stronger invite codes.
--
-- Before: no limits on messages, comments, likes, friend requests, duels or
-- reports - each of them triggers a push. Invite codes were 6 characters
-- from random() with unlimited redeem attempts, and a hit creates an
-- accepted friendship (= access to private photos).

create table if not exists internal.rate_limits (
  user_id uuid not null,
  action text not null,
  window_start timestamptz not null,
  hits integer not null,
  primary key (user_id, action)
);

-- Counts one hit; raises 'rate_limited' once p_max hits fall into the
-- current window. A raised exception rolls the hit back, so blocked
-- attempts don't extend the window.
create or replace function internal.hit_rate_limit(
  p_user uuid,
  p_action text,
  p_max integer,
  p_window interval
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hits integer;
begin
  if p_user is null then
    return 0;
  end if;

  insert into internal.rate_limits as r (user_id, action, window_start, hits)
  values (p_user, p_action, now(), 1)
  on conflict (user_id, action) do update
    set hits = case when r.window_start < now() - p_window then 1 else r.hits + 1 end,
        window_start = case when r.window_start < now() - p_window then now() else r.window_start end
  returning hits into v_hits;

  if v_hits > p_max then
    raise exception 'rate_limited' using hint = p_action;
  end if;
  return v_hits;
end;
$$;

-- Generic BEFORE INSERT trigger: tg_argv[0] = max hits, tg_argv[1] = window.
-- Server-side writes without a user (cron, service role) are not limited.
create or replace function internal.rate_limit_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform internal.hit_rate_limit(
    (select auth.uid()),
    tg_table_name,
    tg_argv[0]::integer,
    tg_argv[1]::interval
  );
  return new;
end;
$$;

create trigger rate_limit_messages
  before insert on public.messages
  for each row execute function internal.rate_limit_insert('120', '1 hour');

create trigger rate_limit_comments
  before insert on public.comments
  for each row execute function internal.rate_limit_insert('60', '1 hour');

create trigger rate_limit_likes
  before insert on public.likes
  for each row execute function internal.rate_limit_insert('300', '1 hour');

create trigger rate_limit_friends
  before insert on public.friends
  for each row execute function internal.rate_limit_insert('30', '1 hour');

create trigger rate_limit_challenges
  before insert on public.challenges
  for each row execute function internal.rate_limit_insert('20', '1 hour');

create trigger rate_limit_content_reports
  before insert on public.content_reports
  for each row execute function internal.rate_limit_insert('20', '1 hour');

create trigger rate_limit_message_reports
  before insert on public.message_reports
  for each row execute function internal.rate_limit_insert('20', '1 hour');

-- Invite codes: 10 characters from a 32-character alphabet (~10^15) drawn
-- from gen_random_bytes. Each byte maps to exactly one character
-- (256 = 8 x 32), so the distribution stays uniform.
create or replace function public.create_friend_invite()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
  -- No 0/O/1/I to avoid typos when the code is typed by hand.
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_attempt integer := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select i.code into v_code
  from public.friend_invites i
  where i.inviter_id = v_uid
    and length(i.code) >= 10
    and i.expires_at > now() + interval '7 days'
    and i.redeemed_count < 50
  order by i.created_at desc
  limit 1;

  if v_code is not null then
    return v_code;
  end if;

  loop
    v_attempt := v_attempt + 1;
    v_bytes := extensions.gen_random_bytes(10);
    select string_agg(substr(v_alphabet, 1 + (get_byte(v_bytes, i) % 32), 1), '' order by i)
    into v_code
    from generate_series(0, 9) as i;

    begin
      insert into public.friend_invites (code, inviter_id) values (v_code, v_uid);
      return v_code;
    exception when unique_violation then
      if v_attempt >= 5 then
        raise;
      end if;
    end;
  end loop;
end;
$$;

-- Redeem: at most 10 attempts per hour. Failures return a status instead of
-- raising, so the attempt stays counted (an exception would roll it back).
create or replace function public.redeem_friend_invite(p_code text)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_invite public.friend_invites%rowtype;
  v_friendship record;
  v_inviter_name text;
  v_hits integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  begin
    v_hits := internal.hit_rate_limit(v_uid, 'redeem_friend_invite', 10, interval '1 hour');
  exception when others then
    return json_build_object('status', 'rate_limited');
  end;

  select * into v_invite
  from public.friend_invites
  where code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'))
  for update;

  if not found or v_invite.expires_at <= now() or v_invite.redeemed_count >= 50 then
    return json_build_object('status', 'invalid_code');
  end if;

  if v_invite.inviter_id = v_uid then
    return json_build_object('status', 'own_code');
  end if;

  if exists (
    select 1 from public.user_blocks b
    where (b.blocker_id = v_uid and b.blocked_id = v_invite.inviter_id)
       or (b.blocker_id = v_invite.inviter_id and b.blocked_id = v_uid)
  ) then
    return json_build_object('status', 'invalid_code');
  end if;

  select username into v_inviter_name
  from public.users_profile where id = v_invite.inviter_id;

  select id, status into v_friendship
  from public.friends f
  where (f.user_id = v_uid and f.friend_id = v_invite.inviter_id)
     or (f.user_id = v_invite.inviter_id and f.friend_id = v_uid)
  limit 1;

  if found and v_friendship.status = 'accepted' then
    return json_build_object('status', 'already_friends', 'username', v_inviter_name);
  end if;

  if found then
    update public.friends set status = 'accepted' where id = v_friendship.id;
  else
    insert into public.friends (user_id, friend_id, status)
    values (v_invite.inviter_id, v_uid, 'accepted');
    -- An accepted insert doesn't fire the "accepted" update trigger.
    perform public.notify_event(
      'friend_accepted', v_uid, v_invite.inviter_id, '{}'::jsonb
    );
  end if;

  update public.friend_invites
  set redeemed_count = redeemed_count + 1
  where code = v_invite.code;

  return json_build_object('status', 'friends', 'username', v_inviter_name);
end;
$$;
