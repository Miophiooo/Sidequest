-- The legacy database-webhook triggers (hardcoded x-push-secret in the
-- trigger definition) and the newer push_on_* trigger functions both fire on
-- the same inserts. The push_on_* path was silently dead because the vault
-- secrets `project_url`/`push_secret` were missing — now that they exist,
-- keeping both would double-push every message, photo and PvP challenge.
-- The push_on_* functions replicate all three payloads 1:1 (send-push
-- expands friends_posts recipients server-side via data.poster_id).
--
-- NOTE (not in this file, applied manually on 2026-06-12): the vault secrets
-- `project_url` and `push_secret` were created via vault.create_secret(...).
-- The push secret value is intentionally NOT committed — see Supabase Vault.
--
-- Applied to production via MCP on 2026-06-12.
drop trigger if exists "Chatnachricht" on public.messages;
drop trigger if exists "Fotos" on public.photos;
drop trigger if exists "Challenges" on public.challenges;
