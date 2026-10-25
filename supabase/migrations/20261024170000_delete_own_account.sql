-- Account deletion as a proper migration (it only existed in sql_archive).
-- Called by the delete-account edge function after it removed the user's
-- files from storage.
--
-- Change: reports filed AGAINST the user are kept (reported_user_id becomes
-- null via the FK); they are moderation evidence and expire with the
-- 12-month retention job. Reports the user filed are removed.

create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  delete from public.comment_likes where user_id = uid;
  delete from public.likes where user_id = uid;
  delete from public.dislikes where user_id = uid;
  delete from public.comments where user_id = uid;

  delete from public.challenge_sabotages where saboteur_id = uid;
  delete from public.challenges where challenger_id = uid or challenged_id = uid;

  delete from public.photos where user_id = uid;

  delete from public.message_reactions where user_id = uid;
  delete from public.messages where sender_id = uid or receiver_id = uid;

  delete from public.content_reports where reporter_id = uid;
  delete from public.message_reports where reporter_id = uid;

  delete from public.friends where user_id = uid or friend_id = uid;
  delete from public.friend_invites where inviter_id = uid;
  delete from public.user_blocks where blocker_id = uid or blocked_id = uid;

  delete from public.notifications where user_id = uid;

  delete from public.user_device_tokens where user_id = uid;
  delete from public.user_notification_prefs where user_id = uid;

  delete from public.users_profile where id = uid;

  delete from auth.users where id = uid;
end;
$$;

revoke execute on function public.delete_own_account() from public, anon;
grant execute on function public.delete_own_account() to authenticated;
