-- Reliable server timestamps for photos, challenges and likes.
--
-- photos/challenges/likes.created_at are `timestamp without time zone` and the
-- app writes the device's *local* wall time there (and reads it back as local
-- time). 20261021150000 overwrote created_at with server time (UTC), which
-- would shift these rows by the device's UTC offset in the app.
-- Now: created_at keeps the app's value (clamped to a plausible range), and
-- the server checks (late flag, duel timers, invite expiry, like cutoff) use a
-- separate server_created_at the client can't set.

alter table public.photos add column if not exists server_created_at timestamptz default now();
alter table public.challenges add column if not exists server_created_at timestamptz default now();
alter table public.likes add column if not exists server_created_at timestamptz default now();

-- Existing rows: best effort from created_at (time zone of the writer unknown).
update public.photos set server_created_at = created_at at time zone 'UTC'
where created_at is not null and server_created_at is distinct from created_at at time zone 'UTC'
  and server_created_at >= now() - interval '1 minute';
update public.challenges set server_created_at = created_at at time zone 'UTC'
where created_at is not null and server_created_at is distinct from created_at at time zone 'UTC'
  and server_created_at >= now() - interval '1 minute';
update public.likes set server_created_at = created_at at time zone 'UTC'
where created_at is not null and server_created_at is distinct from created_at at time zone 'UTC'
  and server_created_at >= now() - interval '1 minute';

-- The app sends local wall time. Every time zone is within ±14h of UTC, so
-- anything further away is replaced by the current UTC wall time.
create or replace function public.clamp_client_local_timestamp(p_value timestamp)
returns timestamp
language sql
stable
set search_path = ''
as $$
  select case
    when p_value is null
      or p_value < (now() at time zone 'UTC') - interval '15 hours'
      or p_value > (now() at time zone 'UTC') + interval '15 hours'
    then (now() at time zone 'UTC')
    else p_value
  end;
$$;

create or replace function public.guard_photo_timing()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  new.created_at := public.clamp_client_local_timestamp(new.created_at);
  new.server_created_at := now();

  if new.challenge_id is null
     and not coalesce(new.is_challenge_photo, false)
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
    new.created_at := public.clamp_client_local_timestamp(new.created_at);
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
  -- Not SECURITY DEFINER on purpose: trusted writers (sabotage_challenge,
  -- service_role) run as another role and may change timers.
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.created_at := public.clamp_client_local_timestamp(new.created_at);
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

create or replace function internal.expire_duel_invites()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.challenges
  set status = 'declined'
  where status = 'pending'
    and server_created_at < now() - interval '2 hours';
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

  -- Results are final once set.
  if old.completed_at is not null then
    new.completed_at := old.completed_at;
    new.winner_id := old.winner_id;
    return new;
  end if;

  if new.completed_at is null then
    new.winner_id := old.winner_id;
    return new;
  end if;

  -- A client asks to complete the challenge: only once both upload windows
  -- closed (missing timers count as closed, like the app does).
  v_challenger_expires := coalesce(old.challenger_expires_at, old.expires_at);
  v_challenged_expires := coalesce(old.challenged_expires_at, old.expires_at);
  if (v_challenger_expires is not null and now() < v_challenger_expires)
     or (v_challenged_expires is not null and now() < v_challenged_expires) then
    new.completed_at := null;
    new.winner_id := old.winner_id;
    new.status := old.status;
    return new;
  end if;

  -- Duel photos only count if uploaded within the player's own timer
  -- (5 minutes grace for slow uploads).
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
    -- Both posted: likes count until the next challenge day starts.
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
      else null -- tie
    end;
  elsif v_challenger_photo is not null then
    new.winner_id := old.challenger_id;
  elsif v_challenged_photo is not null then
    new.winner_id := old.challenged_id;
  else
    new.winner_id := null;
  end if;

  -- completed_at follows the app's convention (wall time without zone);
  -- the server only needs it to be non-null.
  new.completed_at := public.clamp_client_local_timestamp(new.completed_at);
  return new;
end;
$$;
