-- Reaction pushes: the core engagement moment ("someone reacted to my photo")
-- had no push at all — likes and comments were silent. Tap routing reuses the
-- existing mention convention: target_tab '2' (leaderboard) for public posts,
-- '0' (feed) otherwise, plus photo_id/comment_id for direct post focus.
--
-- Applied to production via MCP on 2026-06-12 (as push_on_likes_and_comments
-- + fix_comment_push_column_name; this file is the corrected final state).

create function public.push_on_like_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
  v_is_public boolean;
  v_username text;
begin
  select p.user_id, p.is_public
    into v_owner, v_is_public
  from photos p
  where p.id = new.photo_id;

  if v_owner is null or v_owner = new.user_id then
    return new;
  end if;

  select username into v_username from users_profile where id = new.user_id;

  -- A failed push must never break the like itself.
  begin
    perform enqueue_sidequest_push(
      jsonb_build_object(
        'type', 'like',
        'recipient_user_ids', jsonb_build_array(v_owner),
        'title', 'SideQuest',
        'body', '❤️ @' || coalesce(nullif(trim(v_username), ''), 'Jemand')
          || ' gefällt dein Foto',
        'data', jsonb_build_object(
          'kind', 'like',
          'target_tab', case when v_is_public then '2' else '0' end,
          'photo_id', new.photo_id
        )
      )
    );
  exception when others then
    null;
  end;

  return new;
end;
$$;

revoke execute on function public.push_on_like_insert() from public, anon, authenticated;

create trigger trg_push_on_like_insert
  after insert on public.likes
  for each row execute function public.push_on_like_insert();

create function public.push_on_comment_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
  v_is_public boolean;
  v_username text;
  v_preview text;
begin
  select p.user_id, p.is_public
    into v_owner, v_is_public
  from photos p
  where p.id = new.photo_id;

  if v_owner is null or v_owner = new.user_id then
    return new;
  end if;

  select username into v_username from users_profile where id = new.user_id;

  v_preview := coalesce(nullif(trim(new.message), ''), 'Neuer Kommentar');
  if char_length(v_preview) > 140 then
    v_preview := left(v_preview, 137) || '...';
  end if;

  -- A failed push must never break the comment itself.
  begin
    perform enqueue_sidequest_push(
      jsonb_build_object(
        'type', 'comment',
        'recipient_user_ids', jsonb_build_array(v_owner),
        'title', 'SideQuest',
        'body', '💬 @' || coalesce(nullif(trim(v_username), ''), 'Jemand')
          || ': ' || v_preview,
        'data', jsonb_build_object(
          'kind', 'comment',
          'target_tab', case when v_is_public then '2' else '0' end,
          'photo_id', new.photo_id,
          'comment_id', new.id
        )
      )
    );
  exception when others then
    null;
  end;

  return new;
end;
$$;

revoke execute on function public.push_on_comment_insert() from public, anon, authenticated;

create trigger trg_push_on_comment_insert
  after insert on public.comments
  for each row execute function public.push_on_comment_insert();
