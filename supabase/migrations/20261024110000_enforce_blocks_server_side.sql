-- Blocks were only enforced in the app: a blocked user could still insert
-- messages, friend requests and duel invites directly through the API.
-- These policies now refuse any of them between users where either side
-- blocked the other. (Pushes are skipped in the notify-event function.)

-- Only reveals relationships of the calling user, which user_blocks RLS
-- already exposes to them.
create or replace function public.has_block_with(p_other uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_blocks b
    where (b.blocker_id = (select auth.uid()) and b.blocked_id = p_other)
       or (b.blocker_id = p_other and b.blocked_id = (select auth.uid()))
  );
$$;

alter policy "send message as self" on public.messages
  with check (
    sender_id = (select auth.uid())
    and not public.has_block_with(receiver_id)
  );

alter policy "create friend request" on public.friends
  with check (
    user_id = (select auth.uid())
    and friend_id <> (select auth.uid())
    and status = 'pending'
    and not public.has_block_with(friend_id)
  );

alter policy "accept received friend requests" on public.friends
  with check (
    friend_id = (select auth.uid())
    and status = any (array['pending', 'accepted'])
    and not public.has_block_with(user_id)
  );

alter policy "create challenge as challenger" on public.challenges
  with check (
    challenger_id = (select auth.uid())
    and not public.has_block_with(challenged_id)
  );
