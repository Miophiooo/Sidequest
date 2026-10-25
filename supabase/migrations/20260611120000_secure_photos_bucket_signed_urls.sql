-- Lock down the photos bucket: downloads/signing only for owner, accepted
-- friends, or objects that belong to a public post. The app fetches media
-- through signed URLs from now on (lib/core/signed_storage_media.dart).
--
-- Applied to production via MCP on 2026-06-11. If `supabase migration list`
-- reports a version mismatch against the remote history, reconcile with
-- `supabase migration repair`.

-- 1. Replace the world-readable policy with scoped read policies.
drop policy if exists "photos: public read" on storage.objects;

create policy "photos: read own and friends folders"
on storage.objects for select
to authenticated
using (
  bucket_id = 'photos'
  and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or (storage.foldername(name))[1] in (
      select (case when f.user_id = (select auth.uid()) then f.friend_id else f.user_id end)::text
      from public.friends f
      where f.status = 'accepted'
        and ((select auth.uid()) in (f.user_id, f.friend_id))
    )
  )
);

create policy "photos: read public post objects"
on storage.objects for select
to authenticated
using (
  bucket_id = 'photos'
  and exists (
    select 1
    from public.photos p
    where p.is_public = true
      and (
        split_part(p.url, '/storage/v1/object/public/photos/', 2) = storage.objects.name
        or p.live_photo_clip_path = storage.objects.name
      )
  )
);

-- 2. Indexes so the public-post lookup stays cheap as photos grow.
create index if not exists photos_public_storage_path_idx
  on public.photos (split_part(url, '/storage/v1/object/public/photos/', 2))
  where is_public = true;

create index if not exists photos_public_clip_path_idx
  on public.photos (live_photo_clip_path)
  where is_public = true and live_photo_clip_path is not null;

-- 3. profile_pictures: remove listing (public SELECT on storage.objects) and
-- legacy/broken policies. The bucket itself stays public, so avatar URLs keep
-- working; without SELECT policies the objects can no longer be enumerated.
drop policy if exists "Allow public read" on storage.objects;
drop policy if exists "Allow public to read profile pictures" on storage.objects;
drop policy if exists "profile_pictures: public read" on storage.objects;
-- Dead policies: auth.role() never returns 'authenticated_user'.
drop policy if exists "Allow authenticated insert" on storage.objects;
drop policy if exists "Allow authenticated update" on storage.objects;
-- Loose duplicate of "profile_pictures: insert own only" without prefix check.
drop policy if exists "Allow authenticated users to upload profile pictures" on storage.objects;

-- 4. Flip the photos bucket to private. Public URLs stop working from here on.
update storage.buckets set public = false where id = 'photos';
