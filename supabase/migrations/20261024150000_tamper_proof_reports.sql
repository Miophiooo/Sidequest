-- Reports could be faked or the evidence changed afterwards:
-- * message_reports.recent_messages came from the client (fabricated chats),
-- * reported_user_id was chosen by the reporter (framing someone else),
-- * senders could rewrite a reported message (text, receiver, timestamp),
-- * comment authors could move a comment to another photo.
--
-- Now the server builds the chat snapshot and the reported user, and client
-- updates can't change message or comment content (the app never edits
-- them; only messages.read stays writable).

create or replace function internal.guard_report_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  new.reviewed_at := null;
  new.reviewed_by := null;
  new.resolution := null;
  new.created_at := now();

  if tg_table_name = 'message_reports' then
    if new.message_id is not null and not exists (
      select 1 from public.messages m
      where m.id = new.message_id
        and (m.sender_id = new.reporter_id or m.receiver_id = new.reporter_id)
    ) then
      raise exception 'invalid_report' using errcode = '22023';
    end if;

    new.reported_user_id := new.conversation_partner_id;
    new.recent_messages := coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at)
      from (
        select m.id, m.sender_id, m.receiver_id, m.message, m.created_at
        from public.messages m
        where (m.sender_id = new.reporter_id and m.receiver_id = new.conversation_partner_id)
           or (m.sender_id = new.conversation_partner_id and m.receiver_id = new.reporter_id)
        order by m.created_at desc
        limit 10
      ) x
    ), '[]'::jsonb);
  elsif new.target_type = 'comment' then
    select c.user_id into new.reported_user_id
    from public.comments c where c.id = new.comment_id;
  else
    select p.user_id into new.reported_user_id
    from public.photos p where p.id = new.photo_id;
  end if;

  return new;
end;
$$;

create or replace function internal.guard_message_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') then
    new.sender_id := old.sender_id;
    new.receiver_id := old.receiver_id;
    new.message := old.message;
    new.created_at := old.created_at;
  end if;
  return new;
end;
$$;

create trigger guard_message_update
  before update on public.messages
  for each row execute function internal.guard_message_update();

create or replace function internal.guard_comment_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') then
    new.photo_id := old.photo_id;
    new.user_id := old.user_id;
    new.message := old.message;
    new.created_at := old.created_at;
  end if;
  return new;
end;
$$;

create trigger guard_comment_update
  before update on public.comments
  for each row execute function internal.guard_comment_update();
