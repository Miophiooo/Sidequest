-- created_at of photos, challenges, likes, comments, comment_likes and
-- notifications is "timestamp without time zone" holding UTC (server code
-- like award_crowd_favorite_window compares it as UTC). Clients sent a mix of
-- UTC and device time, so shown times were off by 1-2 hours (more abroad).
-- Client inserts now always get the server time; the app reads values
-- without offset as UTC (parseUtcTimestamp).

create or replace function internal.set_created_at_utc()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') then
    new.created_at := now() at time zone 'UTC';
  end if;
  return new;
end;
$$;

create or replace trigger set_created_at_utc
  before insert on public.comments
  for each row execute function internal.set_created_at_utc();
create or replace trigger set_created_at_utc
  before insert on public.comment_likes
  for each row execute function internal.set_created_at_utc();
create or replace trigger set_created_at_utc
  before insert on public.notifications
  for each row execute function internal.set_created_at_utc();

create or replace function public.guard_photo_timing()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  new.created_at := now() at time zone 'UTC';
  new.server_created_at := now();

  if new.challenge_id is not null and not exists (
    select 1
    from public.challenges c
    where c.id = new.challenge_id
      and new.user_id in (c.challenger_id, c.challenged_id)
      and c.status = 'accepted'
      and c.completed_at is null
  ) then
    raise exception 'invalid_duel_photo' using errcode = '22023';
  end if;

  -- Only real duel photos (with a duel attached) skip the quest late check.
  if new.challenge_id is null then
    new.is_challenge_photo := false;
  end if;

  if new.challenge_id is null
     and not coalesce(new.is_collab_extension, false) then
    new.is_late := now() > public.challenge_late_cutoff(public.active_challenge_day());
  end if;

  return new;
end;
$$;

create or replace function public.guard_like_timing()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') then
    new.created_at := now() at time zone 'UTC';
    new.server_created_at := now();
  end if;
  return new;
end;
$$;

create or replace function public.guard_challenge_timers()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.status := 'pending';
    new.winner_id := null;
    new.completed_at := null;
    new.created_at := now() at time zone 'UTC';
    new.server_created_at := now();
    new.expires_at := null;
    new.challenger_expires_at := null;
    new.challenged_expires_at := null;
    return new;
  end if;

  new.created_at := old.created_at;
  new.server_created_at := old.server_created_at;

  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    if old.status = 'pending'
       and old.challenged_id = (select auth.uid())
       and old.server_created_at > now() - interval '2 hours' then
      new.expires_at := now() + interval '30 minutes';
      new.challenger_expires_at := new.expires_at;
      new.challenged_expires_at := new.expires_at;
      return new;
    end if;
    new.status := old.status;
  end if;

  new.expires_at := old.expires_at;
  new.challenger_expires_at := old.challenger_expires_at;
  new.challenged_expires_at := old.challenged_expires_at;
  return new;
end;
$$;

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

  if old.completed_at is not null then
    new.completed_at := old.completed_at;
    new.winner_id := old.winner_id;
    return new;
  end if;

  if new.completed_at is null then
    new.winner_id := old.winner_id;
    return new;
  end if;

  v_challenger_expires := coalesce(old.challenger_expires_at, old.expires_at);
  v_challenged_expires := coalesce(old.challenged_expires_at, old.expires_at);

  -- Never accepted: it may be closed, but nobody wins.
  if v_challenger_expires is null and v_challenged_expires is null then
    new.winner_id := null;
    new.completed_at := now() at time zone 'UTC';
    return new;
  end if;

  if (v_challenger_expires is not null and now() < v_challenger_expires)
     or (v_challenged_expires is not null and now() < v_challenged_expires) then
    new.completed_at := null;
    new.winner_id := old.winner_id;
    new.status := old.status;
    return new;
  end if;

  select ph.id into v_challenger_photo
  from public.photos ph
  where ph.challenge_id = old.id
    and ph.user_id = old.challenger_id
    and (v_challenger_expires is null or ph.server_created_at <= v_challenger_expires + interval '5 minutes')
  order by ph.server_created_at desc
  limit 1;

  select ph.id into v_challenged_photo
  from public.photos ph
  where ph.challenge_id = old.id
    and ph.user_id = old.challenged_id
    and (v_challenged_expires is null or ph.server_created_at <= v_challenged_expires + interval '5 minutes')
  order by ph.server_created_at desc
  limit 1;

  if v_challenger_photo is not null and v_challenged_photo is not null then
    select b.start_utc into v_boundary
    from public.challenge_day_bounds(public.active_challenge_day()) b;

    if old.server_created_at >= v_boundary then
      new.completed_at := null;
      new.winner_id := old.winner_id;
      new.status := old.status;
      return new;
    end if;

    select count(*) into v_challenger_likes
    from public.likes l
    where l.photo_id = v_challenger_photo and l.server_created_at < v_boundary;

    select count(*) into v_challenged_likes
    from public.likes l
    where l.photo_id = v_challenged_photo and l.server_created_at < v_boundary;

    new.winner_id := case
      when v_challenger_likes > v_challenged_likes then old.challenger_id
      when v_challenged_likes > v_challenger_likes then old.challenged_id
      else null
    end;
  elsif v_challenger_photo is not null then
    new.winner_id := old.challenger_id;
  elsif v_challenged_photo is not null then
    new.winner_id := old.challenged_id;
  else
    new.winner_id := null;
  end if;

  new.completed_at := now() at time zone 'UTC';
  return new;
end;
$$;

-- Old rows written in device time: server_created_at has the real time.
update public.challenges
  set created_at = server_created_at at time zone 'UTC'
  where server_created_at is not null
    and abs(extract(epoch from (created_at - (server_created_at at time zone 'UTC')))) > 60;

update public.likes
  set created_at = server_created_at at time zone 'UTC'
  where server_created_at is not null
    and abs(extract(epoch from (created_at - (server_created_at at time zone 'UTC')))) > 60;

update public.photos
  set created_at = server_created_at at time zone 'UTC'
  where server_created_at is not null
    and abs(extract(epoch from (created_at - (server_created_at at time zone 'UTC')))) > 60;
