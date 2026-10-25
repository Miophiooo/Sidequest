-- Leaderboard in one request, ranked over all quest posts of the active quest.
-- Before, the app loaded the 80 newest public posts plus likes, dislikes,
-- comments and profiles in five requests and ranked only those, so older
-- posts with many likes could fall out of the ranking.
-- Like BeReal, the ranking is only visible after posting yourself: until then
-- has_posted is false and items stays empty.
-- security invoker: RLS decides what the caller may see (anon sees nothing).
create or replace function public.leaderboard_active_quest(p_limit integer default 50)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with me as (
    select auth.uid() as id
  ),
  bounds as (
    select b.start_utc
    from public.challenge_day_bounds(public.active_challenge_day()) b
  ),
  blocked as (
    select case when ub.blocker_id = me.id then ub.blocked_id else ub.blocker_id end as user_id
    from public.user_blocks ub, me
    where ub.blocker_id = me.id or ub.blocked_id = me.id
  ),
  posted as (
    select exists (
      select 1
      from public.photos p, bounds, me
      where p.user_id = me.id
        and p.challenge_id is null
        and not coalesce(p.is_collab_extension, false)
        and p.server_created_at >= bounds.start_utc
    ) as v
  ),
  quest_photos as (
    select p.*
    from public.photos p, bounds, posted
    where posted.v
      and p.is_public = true
      and p.challenge_id is null
      and not coalesce(p.is_collab_extension, false)
      and p.collab_base_photo_id is null
      and p.server_created_at >= bounds.start_utc
      and p.user_id not in (select b.user_id from blocked b)
  ),
  scored as (
    select
      qp.id, qp.user_id, qp.url, qp.thumb_url, qp.created_at, qp.is_public,
      qp.is_late, qp.post_description, qp.is_collab_extension,
      qp.collab_base_photo_id, qp.media_kind, qp.live_photo_clip_url,
      qp.live_photo_duration_ms, qp.live_photo_pre_capture_ms,
      l.n as likes_count,
      d.n as dislikes_count,
      c.n as comments_count,
      l.n - d.n as score,
      l.n + d.n as reaction_count,
      up.username,
      up.profile_picture as avatar,
      exists (
        select 1 from public.likes x, me
        where x.photo_id = qp.id and x.user_id = me.id
      ) as is_liked,
      exists (
        select 1 from public.dislikes x, me
        where x.photo_id = qp.id and x.user_id = me.id
      ) as is_disliked,
      exists (
        select 1 from public.crowd_favorite_wins w where w.photo_id = qp.id
      ) as is_crowd_favorite
    from quest_photos qp
    left join public.users_profile up on up.id = qp.user_id
    cross join lateral (
      select count(*)::int as n from public.likes x where x.photo_id = qp.id
    ) l
    cross join lateral (
      select count(*)::int as n from public.dislikes x where x.photo_id = qp.id
    ) d
    cross join lateral (
      select count(*)::int as n
      from public.comments x
      where x.photo_id = qp.id
        and x.user_id not in (select b.user_id from blocked b)
    ) c
  ),
  ranked as (
    select s.*
    from scored s
    order by s.score desc, s.reaction_count desc, s.comments_count desc, s.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
  )
  select jsonb_build_object(
    'has_posted', (select v from posted),
    'items', coalesce(
      (
        select jsonb_agg(to_jsonb(r) order by r.score desc, r.reaction_count desc, r.comments_count desc, r.created_at desc)
        from ranked r
      ),
      '[]'::jsonb
    )
  );
$$;
