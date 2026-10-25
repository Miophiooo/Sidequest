-- Einmal im Supabase-Dashboard ausführen: SQL Editor -> New query -> alles
-- einfügen -> Run. Schließt die Migration 20261022100000_moderation ab
-- (der Rest ist schon live). Dieser Teil enthält Lösch-Funktionen, die das
-- Supabase-Tool nur mit deiner Bestätigung ausführt.
--
-- Die letzte Anweisung macht deinen Account zum Moderator.

-- Deletes a post (likes, comments and its reports go with it via FK
-- cascades) and returns the storage paths the app must remove afterwards;
-- direct deletes from storage.objects are blocked by Supabase.
create or replace function public.moderation_delete_photo(p_photo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin uuid := internal.require_app_admin();
  photo public.photos%rowtype;
  paths jsonb := '[]'::jsonb;
  path text;
begin
  select * into photo from public.photos where id = p_photo_id;
  if not found then
    raise exception 'photo not found' using errcode = 'P0002';
  end if;

  path := nullif(split_part(photo.url, '/storage/v1/object/public/photos/', 2), '');
  if path is not null then
    paths := paths || to_jsonb(path);
  end if;
  if coalesce(photo.live_photo_clip_path, '') <> '' then
    paths := paths || to_jsonb(photo.live_photo_clip_path);
  end if;

  insert into public.moderation_actions (admin_id, action, target_user_id, details)
  values (
    admin, 'delete_photo', photo.user_id,
    jsonb_build_object(
      'photo_id', photo.id,
      'url', photo.url,
      'text', coalesce(photo.post_description, photo.challenge_description),
      'report_ids', (
        select coalesce(jsonb_agg(r.id), '[]'::jsonb)
        from public.content_reports r
        where r.photo_id = photo.id
           or r.comment_id in (select c.id from public.comments c where c.photo_id = photo.id)
      )
    )
  );

  delete from public.photos where id = p_photo_id;

  return jsonb_build_object('storage_paths', paths);
end;
$$;

create or replace function public.moderation_delete_comment(p_comment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin uuid := internal.require_app_admin();
  cmt public.comments%rowtype;
begin
  select * into cmt from public.comments where id = p_comment_id;
  if not found then
    raise exception 'comment not found' using errcode = 'P0002';
  end if;

  insert into public.moderation_actions (admin_id, action, target_user_id, details)
  values (
    admin, 'delete_comment', cmt.user_id,
    jsonb_build_object(
      'comment_id', cmt.id,
      'photo_id', cmt.photo_id,
      'text', cmt.message,
      'report_ids', (
        select coalesce(jsonb_agg(r.id), '[]'::jsonb)
        from public.content_reports r where r.comment_id = cmt.id
      )
    )
  );

  delete from public.comments where id = p_comment_id;
end;
$$;

-- Message reports keep a snapshot (recent_messages), so they stay and are
-- marked as resolved.
create or replace function public.moderation_delete_message(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin uuid := internal.require_app_admin();
  msg public.messages%rowtype;
begin
  select * into msg from public.messages where id = p_message_id;
  if not found then
    raise exception 'message not found' using errcode = 'P0002';
  end if;

  update public.message_reports
    set reviewed_at = now(), reviewed_by = admin, resolution = 'content_removed'
    where message_id = p_message_id and reviewed_at is null;

  insert into public.moderation_actions (admin_id, action, target_user_id, details)
  values (
    admin, 'delete_message', msg.sender_id,
    jsonb_build_object('message_id', msg.id, 'receiver_id', msg.receiver_id, 'text', msg.message)
  );

  delete from public.messages where id = p_message_id;
end;
$$;

-- Bans an account (p_days null = permanently), ends its sessions and
-- resolves its open reports. Access tokens already issued stay valid until
-- they expire (at most 1 hour).
create or replace function public.moderation_ban_user(p_user_id uuid, p_days integer default null)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin uuid := internal.require_app_admin();
  ban_until timestamptz;
begin
  if p_user_id is null or p_user_id = admin then
    raise exception 'cannot ban this user';
  end if;
  if exists (select 1 from public.app_admins a where a.user_id = p_user_id) then
    raise exception 'cannot ban an admin';
  end if;
  if p_days is not null and p_days < 1 then
    raise exception 'p_days must be at least 1';
  end if;

  ban_until := case
    when p_days is null then now() + interval '100 years'
    else now() + make_interval(days => p_days)
  end;

  update auth.users set banned_until = ban_until where id = p_user_id;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;

  delete from auth.sessions where user_id = p_user_id;
  delete from public.user_device_tokens where user_id = p_user_id;

  update public.content_reports
    set reviewed_at = now(), reviewed_by = admin, resolution = 'user_banned'
    where reported_user_id = p_user_id and reviewed_at is null;
  update public.message_reports
    set reviewed_at = now(), reviewed_by = admin, resolution = 'user_banned'
    where reported_user_id = p_user_id and reviewed_at is null;

  insert into public.moderation_actions (admin_id, action, target_user_id, details)
  values (admin, 'ban_user', p_user_id, jsonb_build_object('days', p_days, 'until', ban_until));

  return ban_until;
end;
$$;

revoke execute on function public.is_app_admin() from public, anon;
grant execute on function public.is_app_admin() to authenticated;

revoke execute on function internal.require_app_admin() from public, anon, authenticated;
revoke execute on function internal.guard_report_insert() from public, anon, authenticated;
revoke execute on function internal.push_admins_on_report() from public, anon, authenticated;

do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.moderation_queue(boolean)',
    'public.moderation_dismiss_report(text, uuid)',
    'public.moderation_delete_photo(uuid)',
    'public.moderation_delete_comment(uuid)',
    'public.moderation_delete_message(uuid)',
    'public.moderation_ban_user(uuid, integer)',
    'public.moderation_unban_user(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end;
$$;

-- Admins can view any reported photo (signed URLs) and remove its files.
create policy "photos: admins read any"
  on storage.objects for select to authenticated
  using (bucket_id = 'photos' and (select public.is_app_admin()));

create policy "photos: admins delete any"
  on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (select public.is_app_admin()));

-- Retention promised in the privacy policy: reviewed reports and the
-- moderation log are kept for 12 months.
select cron.schedule(
  'moderation-retention',
  '17 3 * * *',
  $cron$
    delete from public.moderation_actions where created_at < now() - interval '12 months';
    delete from public.content_reports where reviewed_at < now() - interval '12 months';
    delete from public.message_reports where reviewed_at < now() - interval '12 months';
  $cron$
);

insert into public.app_admins (user_id)
values ('3a1188cb-cf63-4cd3-bdd9-17fc73ddaff6')
on conflict do nothing;

insert into supabase_migrations.schema_migrations (version, name, statements)
values ('20261022100000', 'moderation', array[]::text[])
on conflict do nothing;
