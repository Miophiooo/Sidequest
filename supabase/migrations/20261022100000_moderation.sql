-- Moderation: admins review reports, remove content and ban users.
--
-- * public.app_admins lists the moderators (managed by hand in SQL).
-- * Reports get a review status; regular users can't set it.
-- * All moderator actions go through SECURITY DEFINER RPCs that check
--   public.is_app_admin() and are written to public.moderation_actions
--   (kept even when the reported content - and with it the report - is gone).
-- * New reports send a push to all admins.

create table if not exists public.app_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.app_admins enable row level security;

create table if not exists public.moderation_actions (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid references auth.users(id) on delete set null,
  action text not null check (action in (
    'dismiss', 'delete_photo', 'delete_comment', 'delete_message', 'ban_user', 'unban_user'
  )),
  target_user_id uuid references auth.users(id) on delete set null,
  report_kind text check (report_kind in ('content', 'message')),
  report_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.moderation_actions enable row level security;
create index if not exists moderation_actions_created_at_idx
  on public.moderation_actions (created_at desc);

alter table public.content_reports
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references auth.users(id) on delete set null,
  add column if not exists resolution text
    check (resolution in ('dismissed', 'content_removed', 'user_banned'));
alter table public.message_reports
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references auth.users(id) on delete set null,
  add column if not exists resolution text
    check (resolution in ('dismissed', 'content_removed', 'user_banned'));

create index if not exists content_reports_open_idx
  on public.content_reports (created_at desc) where reviewed_at is null;
create index if not exists message_reports_open_idx
  on public.message_reports (created_at desc) where reviewed_at is null;

create or replace function public.is_app_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.app_admins a where a.user_id = (select auth.uid())
  );
$$;
revoke execute on function public.is_app_admin() from public, anon;
grant execute on function public.is_app_admin() to authenticated;

-- Reporters can't pre-fill the review fields or backdate a report.
create or replace function internal.guard_report_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') then
    new.reviewed_at := null;
    new.reviewed_by := null;
    new.resolution := null;
    new.created_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists guard_content_report_insert on public.content_reports;
create trigger guard_content_report_insert
  before insert on public.content_reports
  for each row execute function internal.guard_report_insert();

drop trigger if exists guard_message_report_insert on public.message_reports;
create trigger guard_message_report_insert
  before insert on public.message_reports
  for each row execute function internal.guard_report_insert();

-- Push to all admins on a new report.
create or replace function internal.push_admins_on_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin_ids jsonb;
  what text;
begin
  select jsonb_agg(a.user_id) into admin_ids
  from public.app_admins a
  where a.user_id is distinct from new.reporter_id;
  if admin_ids is null then
    return new;
  end if;

  if tg_table_name = 'message_reports' then
    what := 'eine Nachricht';
  elsif new.target_type = 'comment' then
    what := 'einen Kommentar';
  else
    what := 'einen Post';
  end if;

  perform public.enqueue_sidequest_push(
    jsonb_build_object(
      'type', 'moderation',
      'recipient_user_ids', admin_ids,
      'title', 'SideQuest 🛡️',
      'body', 'Neue Meldung: Jemand hat ' || what || ' gemeldet.',
      'data', jsonb_build_object('kind', 'moderation', 'report_id', new.id)
    )
  );
  return new;
end;
$$;

drop trigger if exists push_admins_on_content_report on public.content_reports;
create trigger push_admins_on_content_report
  after insert on public.content_reports
  for each row execute function internal.push_admins_on_report();

drop trigger if exists push_admins_on_message_report on public.message_reports;
create trigger push_admins_on_message_report
  after insert on public.message_reports
  for each row execute function internal.push_admins_on_report();

create or replace function internal.require_app_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null or not exists (select 1 from public.app_admins a where a.user_id = uid) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return uid;
end;
$$;

-- Open (or, with p_include_reviewed, all) reports with everything needed to
-- decide: the reported content, both usernames and how often it was reported.
create or replace function public.moderation_queue(p_include_reviewed boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  perform internal.require_app_admin();

  with items as (
    select
      'content'::text as kind,
      r.id as report_id,
      r.created_at,
      r.target_type,
      r.reporter_id,
      r.reported_user_id,
      r.reviewed_at,
      r.resolution,
      r.photo_id,
      r.comment_id,
      null::uuid as message_id,
      coalesce(p.url, cp.url) as photo_url,
      coalesce(p.post_description, p.challenge_description) as photo_text,
      c.message as comment_text,
      null::text as message_text,
      null::jsonb as recent_messages,
      (
        select count(*) from public.content_reports r2
        where r2.reviewed_at is null
          and (r2.photo_id = r.photo_id or r2.comment_id = r.comment_id)
      ) as open_reports_on_target
    from public.content_reports r
    left join public.photos p on p.id = r.photo_id
    left join public.comments c on c.id = r.comment_id
    left join public.photos cp on cp.id = c.photo_id
    where p_include_reviewed or r.reviewed_at is null
    union all
    select
      'message',
      r.id,
      r.created_at,
      'message',
      r.reporter_id,
      r.reported_user_id,
      r.reviewed_at,
      r.resolution,
      null,
      null,
      r.message_id,
      null,
      null,
      null,
      m.message,
      r.recent_messages,
      (
        select count(*) from public.message_reports r2
        where r2.reviewed_at is null and r2.message_id = r.message_id
      )
    from public.message_reports r
    left join public.messages m on m.id = r.message_id
    where p_include_reviewed or r.reviewed_at is null
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'kind', i.kind,
      'report_id', i.report_id,
      'created_at', i.created_at,
      'target_type', i.target_type,
      'reporter_id', i.reporter_id,
      'reporter_name', rp.username,
      'reported_user_id', i.reported_user_id,
      'reported_name', up.username,
      'reported_banned_until', au.banned_until,
      'reviewed_at', i.reviewed_at,
      'resolution', i.resolution,
      'photo_id', i.photo_id,
      'comment_id', i.comment_id,
      'message_id', i.message_id,
      'photo_url', i.photo_url,
      'photo_text', i.photo_text,
      'comment_text', i.comment_text,
      'message_text', i.message_text,
      'recent_messages', i.recent_messages,
      'open_reports_on_target', i.open_reports_on_target
    )
    order by i.reviewed_at is not null, i.created_at desc
  ), '[]'::jsonb)
  into result
  from (select * from items order by created_at desc limit 200) i
  left join public.users_profile rp on rp.id = i.reporter_id
  left join public.users_profile up on up.id = i.reported_user_id
  left join auth.users au on au.id = i.reported_user_id;

  return result;
end;
$$;

create or replace function public.moderation_dismiss_report(p_kind text, p_report_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin uuid := internal.require_app_admin();
  target uuid;
begin
  if p_kind = 'content' then
    update public.content_reports
      set reviewed_at = now(), reviewed_by = admin, resolution = 'dismissed'
      where id = p_report_id
      returning reported_user_id into target;
  elsif p_kind = 'message' then
    update public.message_reports
      set reviewed_at = now(), reviewed_by = admin, resolution = 'dismissed'
      where id = p_report_id
      returning reported_user_id into target;
  else
    raise exception 'unknown report kind %', p_kind;
  end if;

  if not found then
    raise exception 'report not found' using errcode = 'P0002';
  end if;

  insert into public.moderation_actions (admin_id, action, target_user_id, report_kind, report_id)
  values (admin, 'dismiss', target, p_kind, p_report_id);
end;
$$;

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

create or replace function public.moderation_unban_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin uuid := internal.require_app_admin();
begin
  update auth.users set banned_until = null where id = p_user_id;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;

  insert into public.moderation_actions (admin_id, action, target_user_id)
  values (admin, 'unban_user', p_user_id);
end;
$$;

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
