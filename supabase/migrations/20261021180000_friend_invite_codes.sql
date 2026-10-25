-- Friend invite codes: sharing your code is your consent, so whoever redeems
-- it becomes your friend right away (no pending request). A username alone is
-- not enough for that, otherwise anyone could befriend anyone.

create table if not exists public.friend_invites (
  code text primary key,
  inviter_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days',
  redeemed_count integer not null default 0
);

create index if not exists friend_invites_inviter_id_idx on public.friend_invites (inviter_id);

-- Only reachable through the functions below.
alter table public.friend_invites enable row level security;

-- Returns the caller's current invite code, creating one if needed.
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
  v_attempt integer := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select i.code into v_code
  from public.friend_invites i
  where i.inviter_id = v_uid
    and i.expires_at > now() + interval '7 days'
    and i.redeemed_count < 50
  order by i.created_at desc
  limit 1;

  if v_code is not null then
    return v_code;
  end if;

  loop
    v_attempt := v_attempt + 1;
    select string_agg(substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1), '')
    into v_code
    from generate_series(1, 6);

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

-- Redeems a code: caller and inviter become friends immediately.
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
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_invite
  from public.friend_invites
  where code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'))
  for update;

  if not found or v_invite.expires_at <= now() or v_invite.redeemed_count >= 50 then
    raise exception 'invalid_code';
  end if;

  if v_invite.inviter_id = v_uid then
    raise exception 'own_code';
  end if;

  if exists (
    select 1 from public.user_blocks b
    where (b.blocker_id = v_uid and b.blocked_id = v_invite.inviter_id)
       or (b.blocker_id = v_invite.inviter_id and b.blocked_id = v_uid)
  ) then
    raise exception 'invalid_code';
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

-- notify_event had the internal secret inline in its source; read it from
-- Vault instead (same secret as the daily-scheduler cron job).
create or replace function public.notify_event(p_kind text, p_sender_id uuid, p_recipient_id uuid, p_extra jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path to 'public', 'net'
as $$
declare
  v_secret text;
begin
  if p_sender_id is null
     or p_recipient_id is null
     or p_sender_id = p_recipient_id then
    return;
  end if;

  -- Same internal secret as the daily-scheduler cron job (CRON_SECRET).
  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'daily_scheduler_cron_secret';

  perform net.http_post(
    url := 'https://cuvmtajkzgxroedmvfwu.supabase.co/functions/v1/notify-event',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-internal-secret', coalesce(v_secret, '')
    ),
    body := jsonb_build_object(
      'kind', p_kind,
      'sender_id', p_sender_id::text,
      'recipient_id', p_recipient_id::text,
      'extra', p_extra
    )
  );
exception when others then
  -- Push delivery is best-effort. Never let it abort the surrounding tx.
  null;
end;
$$;
