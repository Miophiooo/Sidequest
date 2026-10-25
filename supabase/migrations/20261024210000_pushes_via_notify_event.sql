-- All event pushes go through notify-event, which checks blocks and the
-- recipient's settings and writes the text in their language.
-- * Chat messages and reactions sent two pushes (one directly via send-push,
--   one via notify-event); the direct triggers are switched off.
-- * Duel invites, comments, likes and friends' posts move to notify-event.
-- * New: "duel accepted" push for the challenger, daily reminder for friend
--   requests that are open for more than a day.

alter table public.users_profile add column if not exists language text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'users_profile_language_check'
  ) then
    alter table public.users_profile
      add constraint users_profile_language_check
      check (language is null or language in ('de', 'en'));
  end if;
end;
$$;

alter table public.friends add column if not exists reminder_sent_at timestamptz;

-- friend_post has no single recipient: notify-event sends it to the
-- sender's friends.
create or replace function public.notify_event(
  p_kind text,
  p_sender_id uuid,
  p_recipient_id uuid,
  p_extra jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, net
as $$
declare
  v_secret text;
begin
  if p_sender_id is null then
    return;
  end if;
  if p_kind <> 'friend_post'
     and (p_recipient_id is null or p_sender_id = p_recipient_id) then
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

-- Duplicates of on_messages_insert_notify / on_reactions_insert_notify.
alter table public.messages disable trigger trg_push_on_message_insert;
alter table public.message_reactions disable trigger trg_push_on_message_reaction_insert;
-- Only fired for rows inserted with pvp_challenge_id, which the app never
-- does; push_on_challenge_insert below covers every invite.
alter table public.challenges disable trigger on_challenges_insert_notify;

create or replace function public.push_on_challenge_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status is distinct from 'pending'
     or new.challenged_id is null
     or new.challenger_id = new.challenged_id then
    return new;
  end if;

  perform public.notify_event(
    'duel_invite',
    new.challenger_id,
    new.challenged_id,
    jsonb_build_object('challenge_id', new.id::text)
  );
  return new;
end;
$$;

-- The challenger has 30 minutes from the moment the duel is accepted.
create or replace function internal.push_on_duel_accepted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'pending' and new.status = 'accepted' then
    perform public.notify_event(
      'duel_accepted',
      new.challenged_id,
      new.challenger_id,
      jsonb_build_object('challenge_id', new.id::text)
    );
  end if;
  return new;
end;
$$;

create or replace trigger push_on_duel_accepted
  after update of status on public.challenges
  for each row execute function internal.push_on_duel_accepted();

create or replace function public.push_on_comment_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_is_public boolean;
begin
  select p.user_id, p.is_public
    into v_owner, v_is_public
  from public.photos p
  where p.id = new.photo_id;

  if v_owner is null or v_owner = new.user_id then
    return new;
  end if;

  perform public.notify_event(
    'comment',
    new.user_id,
    v_owner,
    jsonb_build_object(
      'photo_id', new.photo_id::text,
      'comment_id', new.id::text,
      'message', left(coalesce(new.message, ''), 200),
      'is_public', coalesce(v_is_public, false)
    )
  );
  return new;
end;
$$;

create or replace function public.push_on_like_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_is_public boolean;
begin
  select p.user_id, p.is_public
    into v_owner, v_is_public
  from public.photos p
  where p.id = new.photo_id;

  if v_owner is null or v_owner = new.user_id then
    return new;
  end if;

  perform public.notify_event(
    'like',
    new.user_id,
    v_owner,
    jsonb_build_object(
      'photo_id', new.photo_id::text,
      'is_public', coalesce(v_is_public, false)
    )
  );
  return new;
end;
$$;

create or replace function public.push_on_photo_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.user_id is null then
    return new;
  end if;

  perform public.notify_event(
    'friend_post',
    new.user_id,
    null,
    jsonb_build_object(
      'photo_id', new.id::text,
      'is_public', coalesce(new.is_public, false)
    )
  );
  return new;
end;
$$;

-- Once per request: a reminder when it is open for more than a day (but not
-- older than a week, so old requests don't suddenly ping people).
create or replace function internal.send_friend_request_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select f.id, f.user_id, f.friend_id
    from public.friends f
    where f.status = 'pending'
      and f.reminder_sent_at is null
      and f.created_at < now() - interval '1 day'
      and f.created_at > now() - interval '7 days'
    order by f.created_at
    limit 500
    for update skip locked
  loop
    update public.friends set reminder_sent_at = now() where id = r.id;
    perform public.notify_event(
      'friend_request_reminder',
      r.user_id,
      r.friend_id,
      jsonb_build_object('friendship_id', r.id::text)
    );
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Daily in the early evening (18:23 / 19:23 German time).
select cron.schedule(
  'friend-request-reminders',
  '23 17 * * *',
  'select internal.send_friend_request_reminders()'
);
