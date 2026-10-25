-- One-time onboarding after account creation.
-- Server-side flag so the intro never re-appears, even after reinstall or
-- on a second device. Existing accounts are backfilled to true -> they
-- never see the onboarding.
--
-- Applied to production via MCP on 2026-06-12.
alter table public.users_profile
  add column if not exists onboarding_completed boolean not null default false;

update public.users_profile set onboarding_completed = true;
