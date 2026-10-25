-- Mentions: the entry (and with it the push, which uses the message) is now
-- written in the recipient's language instead of always German. actor_id and
-- data let the app render it in its current language. Blocks are checked in
-- both directions. Still without a limit (decision S3).
create or replace function public.create_mention_notifications_v2(
  p_recipient_ids uuid[],
  p_source_text text,
  p_entity_kind text default 'comment',
  p_photo_id uuid default null,
  p_comment_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_username text;
  v_entity text := case lower(coalesce(p_entity_kind, 'comment'))
    when 'description' then 'description'
    else 'comment'
  end;
  v_preview text;
  v_inserted_count integer := 0;
begin
  if v_actor_id is null then
    return 0;
  end if;

  if coalesce(array_length(p_recipient_ids, 1), 0) = 0 then
    return 0;
  end if;

  select nullif(trim(username), '')
  into v_actor_username
  from public.users_profile
  where id = v_actor_id;

  v_preview := trim(regexp_replace(coalesce(p_source_text, ''), '\s+', ' ', 'g'));
  if char_length(v_preview) > 80 then
    v_preview := left(v_preview, 77) || '...';
  end if;

  insert into public.notifications (
    user_id, photo_id, comment_id, type, message, read, created_at,
    actor_id, data
  )
  select r.recipient_id,
         p_photo_id,
         p_comment_id,
         'mention',
         case when up.language = 'en' then
           coalesce(v_actor_username, 'Someone') || ' mentioned you in a '
             || v_entity
             || case when v_preview <> '' then ': "' || v_preview || '"' else '.' end
         else
           coalesce(v_actor_username, 'Jemand') || ' hat dich in '
             || case v_entity when 'description' then 'einer Beschreibung' else 'einem Kommentar' end
             || ' erwähnt'
             || case when v_preview <> '' then ': "' || v_preview || '"' else '.' end
         end,
         false,
         now() at time zone 'UTC',
         v_actor_id,
         jsonb_build_object('entity', v_entity, 'preview', v_preview)
  from (
    select distinct unnest(p_recipient_ids) as recipient_id
  ) as r
  left join public.users_profile up on up.id = r.recipient_id
  where r.recipient_id is not null
    and r.recipient_id <> v_actor_id
    and not exists (
      select 1
      from public.user_blocks ub
      where (ub.blocker_id = r.recipient_id and ub.blocked_id = v_actor_id)
         or (ub.blocker_id = v_actor_id and ub.blocked_id = r.recipient_id)
    );

  get diagnostics v_inserted_count = row_count;
  return v_inserted_count;
end;
$$;
