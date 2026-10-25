-- 1. Small thumbnails for lists (leaderboard tiles, profile grid): the app
--    uploads a ~320 px copy next to each post and stores it in thumb_url.
-- 2. Security: a post could point at any file in the private photos bucket.
--    "photos: read public post objects" makes every file referenced by a
--    public post readable, so a user could publish someone else's private
--    photo by inserting a post with its URL. Media of a post must now be in
--    the poster's own folder, and the storage policy only opens files from
--    the post owner's folder. (Checked: no existing post points elsewhere.)

alter table public.photos add column if not exists thumb_url text;

create or replace function public.guard_photo_timing()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_own_prefix text;
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  v_own_prefix := '/storage/v1/object/public/photos/' || new.user_id::text || '/';
  if position(v_own_prefix in coalesce(new.url, '')) = 0
     or (new.live_photo_clip_url is not null
         and position(v_own_prefix in new.live_photo_clip_url) = 0)
     or (new.live_photo_clip_path is not null
         and split_part(new.live_photo_clip_path, '/', 1) <> new.user_id::text) then
    raise exception 'invalid_media_url' using errcode = '22023';
  end if;
  if new.thumb_url is not null and position(v_own_prefix in new.thumb_url) = 0 then
    new.thumb_url := null;
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

alter policy "photos: read public post objects" on storage.objects
using (
  bucket_id = 'photos'
  and exists (
    select 1
    from public.photos p
    where p.is_public = true
      and (storage.foldername(storage.objects.name))[1] = p.user_id::text
      and (
        split_part(p.url, '/storage/v1/object/public/photos/', 2) = storage.objects.name
        or p.live_photo_clip_path = storage.objects.name
        or split_part(p.thumb_url, '/storage/v1/object/public/photos/', 2) = storage.objects.name
      )
  )
);
