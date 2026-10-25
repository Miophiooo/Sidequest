-- Einmal im Supabase-Dashboard ausführen: SQL Editor -> New query -> alles
-- einfügen -> Run. Nimmt nicht eingeloggten Aufrufern (anon) das Recht,
-- interne Funktionen aufzurufen. Die Funktionen prüfen das zwar schon selbst,
-- das hier ist die zusätzliche Absicherung, die der Security Advisor meldet.
--
-- REVOKE kann Claude über das Supabase-Tool nicht selbst ausführen (braucht
-- deine Bestätigung).

revoke execute on function public.edge_secret(text) from public, anon, authenticated;
grant execute on function public.edge_secret(text) to service_role;

revoke execute on function public.has_block_with(uuid) from public, anon;
grant execute on function public.has_block_with(uuid) to authenticated;

revoke execute on function public.create_friend_invite() from public, anon;
grant execute on function public.create_friend_invite() to authenticated;

revoke execute on function public.redeem_friend_invite(text) from public, anon;
grant execute on function public.redeem_friend_invite(text) to authenticated;

revoke execute on function public.is_app_admin() from public, anon;
grant execute on function public.is_app_admin() to authenticated;

do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.moderation_queue(boolean)',
    'public.moderation_dismiss_report(text, uuid)',
    'public.moderation_delete_photo(uuid)',
    'public.moderation_delete_comment(uuid)',
    'public.moderation_delete_message(uuid)',
    'public.moderation_ban_user(uuid, integer)',
    'public.moderation_unban_user(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end;
$$;

revoke execute on function internal.hit_rate_limit(uuid, text, integer, interval) from public, anon, authenticated;
revoke execute on function internal.rate_limit_insert() from public, anon, authenticated;
revoke all on table internal.rate_limits from public, anon, authenticated;
