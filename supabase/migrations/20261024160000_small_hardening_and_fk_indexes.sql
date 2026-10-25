-- Smaller findings from the security audit (2026-10-24):
-- * Public posts, their comments and likes were readable without an account
--   (policies applied "to public", i.e. also the anon key).
-- * challenge_sabotages could be inserted directly, bypassing the
--   sabotage_challenge() RPC (fake events, used-up sabotage slot).
-- * Setting is_challenge_photo without a challenge skipped the late check.
-- * Foreign keys without an index (friends.user_id/friend_id are part of
--   most RLS checks).

alter policy "see public photos" on public.photos to authenticated;
alter policy "see own and friends' photos" on public.photos to authenticated;
alter policy "see comments on visible photos" on public.comments to authenticated;
alter policy "see likes on visible photos" on public.likes to authenticated;
alter policy "Users can view visible dislikes" on public.dislikes to authenticated;
alter policy "see comment likes on visible comments" on public.comment_likes to authenticated;

-- Sabotage goes through public.sabotage_challenge() (security definer).
alter policy "insert sabotage as self" on public.challenge_sabotages
  with check (false);

create or replace function public.guard_photo_timing()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  new.created_at := public.clamp_client_local_timestamp(new.created_at);
  new.server_created_at := now();

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

create index if not exists friends_user_id_idx on public.friends (user_id);
create index if not exists friends_friend_id_idx on public.friends (friend_id);
create index if not exists messages_sender_id_idx on public.messages (sender_id);
create index if not exists likes_user_id_idx on public.likes (user_id);
create index if not exists photos_challenge_id_idx on public.photos (challenge_id);
create index if not exists challenges_challenger_id_idx on public.challenges (challenger_id);
create index if not exists challenges_winner_id_idx on public.challenges (winner_id);
create index if not exists comment_likes_user_id_idx on public.comment_likes (user_id);
create index if not exists content_reports_photo_id_idx on public.content_reports (photo_id);
create index if not exists content_reports_comment_id_idx on public.content_reports (comment_id);
create index if not exists message_reports_message_id_idx on public.message_reports (message_id);
create index if not exists crowd_favorite_wins_user_id_idx on public.crowd_favorite_wins (user_id);
create index if not exists crowd_favorite_wins_photo_id_idx on public.crowd_favorite_wins (photo_id);
create index if not exists notifications_challenge_id_idx on public.notifications (challenge_id);
create index if not exists challenge_sabotages_saboteur_id_idx on public.challenge_sabotages (saboteur_id);
create index if not exists challenge_sabotages_target_id_idx on public.challenge_sabotages (target_id);
create index if not exists quest_suggestion_votes_user_id_idx on public.quest_suggestion_votes (user_id);
