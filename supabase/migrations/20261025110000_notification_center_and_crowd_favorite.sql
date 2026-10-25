-- 1. Notification center: besides mentions, likes, comments, friend
--    requests, duels and the Crowd Favorite title now get an entry in
--    public.notifications. notify_event writes it, so every event that sends
--    a push also lands in the center. The app builds the text from type,
--    actor_id and data in its current language; message stays as a fallback
--    for older app versions.
-- 2. Crowd Favorite: only real quest posts count, the winner gets a push
--    ("+3 Joker") and an entry. Before, the award was silent.

alter table public.notifications add column if not exists actor_id uuid;
alter table public.notifications add column if not exists data jsonb not null default '{}'::jsonb;

create index if not exists notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

create or replace function internal.record_notification(
  p_kind text,
  p_actor uuid,
  p_recipient uuid,
  p_extra jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type text := case p_kind when 'pvp_challenge' then 'duel_invite' else p_kind end;
  v_extra jsonb := coalesce(p_extra, '{}'::jsonb);
  v_photo uuid := nullif(v_extra->>'photo_id', '')::uuid;
  v_comment uuid := nullif(v_extra->>'comment_id', '')::uuid;
  v_challenge uuid := nullif(v_extra->>'challenge_id', '')::uuid;
  v_data jsonb := '{}'::jsonb;
  v_en boolean;
  v_who text;
  v_winner text;
  v_message text;
begin
  if p_actor is null or p_recipient is null then
    return;
  end if;
  if v_type not in (
    'like', 'comment', 'friend_request', 'friend_accepted',
    'duel_invite', 'duel_accepted', 'duel_result', 'crowd_favorite'
  ) then
    return;
  end if;
  if v_type <> 'crowd_favorite' and p_actor = p_recipient then
    return;
  end if;
  if exists (
    select 1 from public.user_blocks b
    where (b.blocker_id = p_actor and b.blocked_id = p_recipient)
       or (b.blocker_id = p_recipient and b.blocked_id = p_actor)
  ) then
    return;
  end if;

  -- Like/unlike/like or request/cancel/request: one entry per day is enough.
  if exists (
    select 1 from public.notifications n
    where n.user_id = p_recipient
      and n.type = v_type
      and n.actor_id = p_actor
      and n.photo_id is not distinct from v_photo
      and n.comment_id is not distinct from v_comment
      and n.challenge_id is not distinct from v_challenge
      and n.created_at > (now() at time zone 'UTC') - interval '24 hours'
  ) then
    return;
  end if;

  if v_type = 'comment' then
    v_data := jsonb_build_object('message', left(coalesce(v_extra->>'message', ''), 120));
  elsif v_type = 'duel_result' then
    v_winner := coalesce(v_extra->>'winner_id', '');
    v_data := jsonb_build_object(
      'winner_id', v_winner,
      'had_photos', coalesce((v_extra->>'had_photos')::boolean, false)
    );
  elsif v_type = 'crowd_favorite' then
    v_data := jsonb_build_object(
      'likes', coalesce((v_extra->>'likes')::int, 0),
      'joker_bonus', coalesce((v_extra->>'joker_bonus')::int, 0)
    );
  end if;

  select u.language = 'en' into v_en from public.users_profile u where u.id = p_recipient;
  v_en := coalesce(v_en, false);
  select '@' || nullif(trim(u.username), '') into v_who from public.users_profile u where u.id = p_actor;
  v_who := coalesce(v_who, case when v_en then 'Someone' else 'Jemand' end);

  v_message := case v_type
    when 'like' then case when v_en then v_who || ' liked your photo' else v_who || ' gefällt dein Foto' end
    when 'comment' then case when v_en then v_who || ' commented on your photo' else v_who || ' hat dein Foto kommentiert' end
    when 'friend_request' then case when v_en then v_who || ' sent you a friend request' else v_who || ' möchte mit dir befreundet sein' end
    when 'friend_accepted' then case when v_en then v_who || ' is now your friend' else v_who || ' ist jetzt mit dir befreundet' end
    when 'duel_invite' then case when v_en then v_who || ' challenged you to a duel' else v_who || ' fordert dich zum Duell heraus' end
    when 'duel_accepted' then case when v_en then v_who || ' accepted your duel' else v_who || ' hat dein Duell angenommen' end
    when 'duel_result' then
      case
        when v_winner = p_recipient::text then case when v_en then 'You won the duel against ' || v_who else 'Du hast das Duell gegen ' || v_who || ' gewonnen' end
        when v_winner <> '' then case when v_en then v_who || ' won the duel' else v_who || ' hat das Duell gewonnen' end
        else case when v_en then 'Your duel against ' || v_who || ' is over' else 'Dein Duell gegen ' || v_who || ' ist vorbei' end
      end
    when 'crowd_favorite' then case when v_en then 'You are Crowd Favorite! +3 jokers' else 'Du bist Crowd Favorite! +3 Joker' end
  end;

  insert into public.notifications (
    user_id, type, message, read, created_at,
    photo_id, comment_id, challenge_id, actor_id, data
  )
  values (
    p_recipient, v_type, v_message, false, now() at time zone 'UTC',
    v_photo, v_comment, v_challenge, p_actor, v_data
  );
end;
$$;

create or replace function public.notify_event(
  p_kind text,
  p_sender_id uuid,
  p_recipient_id uuid,
  p_extra jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path to 'public', 'net'
as $$
declare
  v_secret text;
begin
  if p_sender_id is null then
    return;
  end if;
  -- crowd_favorite is a system event: the winner is sender and recipient.
  if p_kind = 'crowd_favorite' then
    if p_recipient_id is null then
      return;
    end if;
  elsif p_kind <> 'friend_post'
     and (p_recipient_id is null or p_sender_id = p_recipient_id) then
    return;
  end if;

  begin
    perform internal.record_notification(p_kind, p_sender_id, p_recipient_id, p_extra);
  exception when others then
    -- The entry is a nice-to-have; the push still goes out.
    null;
  end;

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

-- Same ranking as before (likes minus dislikes, then likes, then earliest),
-- but only quest posts of the window count: no duel photos, no collab
-- extensions. The window uses server_created_at (timestamptz), so it no
-- longer depends on the session time zone.
create or replace function public.award_crowd_favorite_window(
  london_date_str text,
  start_utc timestamptz,
  end_utc timestamptz
)
returns json
language plpgsql
security definer
set search_path = ''
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
    select p.id as photo_id, p.user_id, p.server_created_at
    from public.photos p
    where p.is_public = true
      and p.challenge_id is null
      and not coalesce(p.is_collab_extension, false)
      and p.server_created_at >= start_utc
      and p.server_created_at < end_utc
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
      wp.server_created_at,
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
  order by s.score desc, s.likes_count desc, s.server_created_at asc, s.photo_id asc
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

    perform public.notify_event(
      'crowd_favorite', v_user_id, v_user_id,
      jsonb_build_object(
        'photo_id', v_photo_id::text,
        'likes', v_likes,
        'joker_bonus', 3,
        'is_public', true
      )
    );

    return json_build_object(
      'ok', true, 'london_date', v_london_date, 'awarded', true,
      'user_id', v_user_id, 'photo_id', v_photo_id,
      'likes', v_likes, 'dislikes', v_dislikes, 'score', v_score,
      'joker_bonus', 3, 'active_until', v_active_until
    );
  end if;

  select w.user_id, w.photo_id, w.likes_count, w.dislikes_count, w.score
    into v_user_id, v_photo_id, v_likes, v_dislikes, v_score
  from public.crowd_favorite_wins w
  where w.london_date = v_london_date;

  return json_build_object(
    'ok', true, 'london_date', v_london_date, 'awarded', false,
    'reason', 'already_awarded', 'user_id', v_user_id, 'photo_id', v_photo_id,
    'likes', v_likes, 'dislikes', v_dislikes, 'score', v_score
  );
end;
$$;
