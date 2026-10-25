-- Security fixes found during review.
--
-- 1) friends: the INSERT policy only checked user_id = auth.uid(), so a client
--    could insert a row with status = 'accepted' and instantly become "friends"
--    with anyone (gaining access to their friends-only photos). The UPDATE
--    policy let either side change any column, so the requester could accept
--    their own request or re-point user_id/friend_id.
--    Now: requests are always created as 'pending', only the receiver may
--    update, and the participants of a row can never be changed.
--
-- 2) storage.objects: the policy "Allow users to delete own profile pictures"
--    only checked the bucket, so any signed-in user could delete anyone's
--    profile picture. It is now limited to the caller's own file.

alter policy "create friend request" on public.friends
  to authenticated
  with check (
    user_id = (select auth.uid())
    and friend_id <> (select auth.uid())
    and status = 'pending'
  );

alter policy "update own friendships" on public.friends
  to authenticated
  using (friend_id = (select auth.uid()))
  with check (
    friend_id = (select auth.uid())
    and status in ('pending', 'accepted')
  );
alter policy "update own friendships" on public.friends
  rename to "accept received friend requests";

create or replace function public.friends_prevent_participant_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id or new.friend_id is distinct from old.friend_id then
    raise exception 'friends: user_id/friend_id cannot be changed';
  end if;
  return new;
end;
$$;

create or replace trigger friends_prevent_participant_change
before update on public.friends
for each row execute function public.friends_prevent_participant_change();

alter policy "Allow users to delete own profile pictures" on storage.objects
  to authenticated
  using (
    bucket_id = 'profile_pictures'
    and name like ('profile_' || (select auth.uid())::text || '%')
  );
