-- Duels are resolved on the server and both players get the result.
-- Before, a duel was only closed when one of the two opened the app after
-- the next quest started (client-side _resolveDuePvpChallenges), so most
-- duels never finished and nobody learned who won.

-- Closes every accepted duel whose photo time is over and whose voting ended
-- with the start of the current quest. guard_challenge_result picks the
-- winner (and keeps a duel open while voting still runs).
create or replace function internal.resolve_due_duels()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_boundary timestamptz;
  n integer;
begin
  select b.start_utc into v_boundary
  from public.challenge_day_bounds(public.active_challenge_day()) b;

  update public.challenges c
  set completed_at = now() at time zone 'UTC'
  where c.status = 'accepted'
    and c.completed_at is null
    and c.server_created_at < v_boundary
    and coalesce(c.challenger_expires_at, c.expires_at) < now()
    and coalesce(c.challenged_expires_at, c.expires_at) < now();
  get diagnostics n = row_count;
  return n;
end;
$$;

-- "Duell gewonnen / verloren / unentschieden" for both players.
create or replace function internal.push_on_duel_result()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_extra jsonb;
begin
  if old.completed_at is not null or new.completed_at is null then
    return new;
  end if;
  -- Never accepted (declined or expired invite): no result to tell.
  if coalesce(old.challenger_expires_at, old.challenged_expires_at, old.expires_at) is null then
    return new;
  end if;

  v_extra := jsonb_build_object(
    'challenge_id', new.id::text,
    'winner_id', coalesce(new.winner_id::text, ''),
    'had_photos', exists (select 1 from public.photos p where p.challenge_id = new.id)
  );
  perform public.notify_event(
    'duel_result', new.challenged_id, new.challenger_id,
    v_extra || jsonb_build_object('recipient_id', new.challenger_id::text)
  );
  perform public.notify_event(
    'duel_result', new.challenger_id, new.challenged_id,
    v_extra || jsonb_build_object('recipient_id', new.challenged_id::text)
  );
  return new;
end;
$$;

create or replace trigger push_on_duel_result
  after update of completed_at on public.challenges
  for each row execute function internal.push_on_duel_result();

-- Runs at every quest start: first the duels (the winner may get a joker),
-- then the automatic joker and the streak reset.
create or replace function internal.reset_daily_game_flags()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day date := public.active_challenge_day();
  v_active text := to_char(v_day, 'YYYY-MM-DD');
  v_prev text := to_char(v_day - 1, 'YYYY-MM-DD');
  v_before text := to_char(v_day - 2, 'YYYY-MM-DD');
begin
  perform internal.resolve_due_duels();

  update public.users_profile
  set joker_used_today = false
  where joker_used_today
    and last_posted_date is distinct from v_active;

  with saved as (
    update public.users_profile p
    set joker = p.joker - 1,
        flames = coalesce(p.flames, 0) + 1,
        last_posted_date = v_prev
    where coalesce(p.flames, 0) > 0
      and coalesce(p.joker, 0) >= 1
      and p.last_posted_date = v_before
    returning p.id, p.flames, p.joker, p.language
  )
  insert into public.notifications (user_id, type, message, read, created_at)
  select s.id,
         'joker_auto_used',
         case when s.language = 'en'
           then '🃏 A joker saved your ' || s.flames || '-day streak. Jokers left: ' || s.joker
           else '🃏 Ein Joker hat deine Streak gerettet (' || s.flames || ' Tage). Übrige Joker: ' || s.joker
         end,
         false,
         now()
  from saved s;

  update public.users_profile
  set flames = 0
  where coalesce(flames, 0) <> 0
    and (last_posted_date is null or last_posted_date not in (v_active, v_prev));
end;
$$;
