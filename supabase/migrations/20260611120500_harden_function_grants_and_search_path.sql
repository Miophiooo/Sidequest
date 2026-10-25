-- Function hardening:
-- 1. Trigger functions are never called directly -> no EXECUTE for API roles.
-- 2. App RPCs are callable by authenticated only (exception: username check
--    runs during signup, before a session exists).
-- 3. Pin search_path on the functions flagged by the security advisor.
--
-- Applied to production via MCP on 2026-06-11. If `supabase migration list`
-- reports a version mismatch against the remote history, reconcile with
-- `supabase migration repair`.

-- ---- 1. Trigger-only functions ----
revoke execute on function public.award_joker_on_challenge_completion() from public, anon, authenticated;
revoke execute on function public.create_user_streak() from public, anon, authenticated;
revoke execute on function public.enforce_collab_extension_rules() from public, anon, authenticated;
revoke execute on function public.handle_new_user_profile() from public, anon, authenticated;
revoke execute on function public.push_on_challenge_insert() from public, anon, authenticated;
revoke execute on function public.push_on_mention_insert() from public, anon, authenticated;
revoke execute on function public.push_on_message_insert() from public, anon, authenticated;
revoke execute on function public.push_on_message_reaction_insert() from public, anon, authenticated;
revoke execute on function public.push_on_photo_insert() from public, anon, authenticated;
revoke execute on function public.trg_notify_friend_accepted_update() from public, anon, authenticated;
revoke execute on function public.trg_notify_friend_request_insert() from public, anon, authenticated;
revoke execute on function public.trg_notify_message_insert() from public, anon, authenticated;
revoke execute on function public.trg_notify_pvp_challenge_insert() from public, anon, authenticated;
revoke execute on function public.trg_notify_reaction_insert() from public, anon, authenticated;
revoke execute on function public.set_updated_at() from public, anon, authenticated;

-- ---- 2. Internal helpers (service/trigger context only) ----
revoke execute on function public.notify_event(text, uuid, uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.enqueue_sidequest_push(jsonb) from public, anon, authenticated;
revoke execute on function public.tripswap_hints(uuid) from public, anon, authenticated;
revoke execute on function public.tripswap_reveal(uuid) from public, anon, authenticated;

-- ---- 3. App RPCs: authenticated only ----
revoke execute on function public.delete_own_account() from public, anon;
grant execute on function public.delete_own_account() to authenticated;
revoke execute on function public.mark_messages_as_read(uuid, uuid) from public, anon;
grant execute on function public.mark_messages_as_read(uuid, uuid) to authenticated;
revoke execute on function public.sabotage_challenge(uuid, integer) from public, anon;
grant execute on function public.sabotage_challenge(uuid, integer) to authenticated;
revoke execute on function public.create_mention_notifications(uuid[], text, text) from public, anon;
grant execute on function public.create_mention_notifications(uuid[], text, text) to authenticated;
revoke execute on function public.create_mention_notifications_v2(uuid[], text, text, uuid, uuid) from public, anon;
grant execute on function public.create_mention_notifications_v2(uuid[], text, text, uuid, uuid) to authenticated;

-- Username availability is checked during signup (no session yet) -> anon stays.
revoke execute on function public.is_username_available(text, uuid) from public;
grant execute on function public.is_username_available(text, uuid) to anon, authenticated;

-- Used in the unique username index: evaluated by the inserting role.
revoke execute on function public.username_lookup_key(text) from public, anon;
grant execute on function public.username_lookup_key(text) to authenticated;

-- ---- 4. Pin search_path (advisor: function_search_path_mutable) ----
alter function public.award_joker_on_challenge_completion() set search_path = public;
alter function public.create_user_streak() set search_path = public;
alter function public.enforce_collab_extension_rules() set search_path = public;
alter function public.mark_messages_as_read(uuid, uuid) set search_path = public;
alter function public.sabotage_challenge(uuid, integer) set search_path = public;
alter function public.set_updated_at() set search_path = public;
alter function public.username_lookup_key(text) set search_path = public;
