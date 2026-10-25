-- Jokers are used automatically: whoever missed exactly the previous quest
-- and still has a joker keeps the streak (same effect as using it by hand:
-- joker -1, streak +1, the missed day counts). Before, the streak was reset
-- at the next quest start unless the app happened to be open at the right
-- moment to use the joker manually.

create or replace function internal.reset_daily_game_flags()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day date := public.active_challenge_day();
  v_active text := to_char(v_day, 'YYYY-MM-DD');
  v_prev text := to_char(v_day - 1, 'YYYY-MM-DD');
  v_before text := to_char(v_day - 2, 'YYYY-MM-DD');
begin
  update public.users_profile
  set joker_used_today = false
  where joker_used_today
    and last_posted_date is distinct from v_active;

  with saved as (
    update public.users_profile p
    set joker = p.joker - 1,
        flames = coalesce(p.flames, 0) + 1,
        last_posted_date = v_prev
    where coalesce(p.flames, 0) > 0
      and coalesce(p.joker, 0) >= 1
      and p.last_posted_date = v_before
    returning p.id, p.flames, p.joker, p.language
  )
  insert into public.notifications (user_id, type, message, read, created_at)
  select s.id,
         'joker_auto_used',
         case when s.language = 'en'
           then '🃏 A joker saved your ' || s.flames || '-day streak. Jokers left: ' || s.joker
           else '🃏 Ein Joker hat deine Streak gerettet (' || s.flames || ' Tage). Übrige Joker: ' || s.joker
         end,
         false,
         now()
  from saved s;

  update public.users_profile
  set flames = 0
  where coalesce(flames, 0) <> 0
    and (last_posted_date is null or last_posted_date not in (v_active, v_prev));
end;
$$;
