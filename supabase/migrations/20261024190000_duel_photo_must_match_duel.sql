-- A photo with challenge_id must belong to a running duel of the poster.
-- Before, any challenge_id was accepted, so a photo could skip the quest late
-- check by pointing at a random duel. The app no longer retries a failed duel
-- upload without challenge_id (that turned duel photos into quest posts).

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
