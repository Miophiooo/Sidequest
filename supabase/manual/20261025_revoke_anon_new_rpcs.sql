-- Run once in the Supabase SQL editor (the migration tool can't run REVOKE).
-- Both functions already do nothing without a signed-in user; this only
-- removes them from the anonymous API (Supabase security advisor warning).
revoke execute on function public.friend_suggestions(text[], text[], integer) from anon, public;
revoke execute on function public.mark_messages_delivered() from anon, public;
