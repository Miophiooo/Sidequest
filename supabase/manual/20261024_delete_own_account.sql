-- Einmal im Supabase-Dashboard ausführen: SQL Editor -> New query -> alles
-- einfügen -> Run. Aktualisiert die Kontolöschung (Meldungen GEGEN einen
-- gelöschten Nutzer bleiben als Beweis erhalten) und trägt die Migration ein.
-- Enthält DELETE-Anweisungen, deshalb kann Claude sie nicht selbst ausführen.

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

insert into supabase_migrations.schema_migrations (version, name, statements)
values ('20261024170000', 'delete_own_account', array[]::text[])
on conflict do nothing;
