-- Chat ticks like WhatsApp: sent / delivered / read.
-- * messages.delivered_at: set once the receiver's app has loaded the message
--   (mark_messages_delivered) or read it (mark_messages_as_read).
-- * read and delivered_at can only change through these RPCs; before, the
--   sender could update "read" on their own messages.

alter table public.messages add column if not exists delivered_at timestamptz;

-- Messages that were already read count as delivered.
update public.messages
  set delivered_at = created_at
  where read and delivered_at is null;

create index if not exists idx_messages_undelivered
  on public.messages (receiver_id)
  where delivered_at is null;

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
    new.read := old.read;
    new.delivered_at := old.delivered_at;
  end if;
  return new;
end;
$$;

-- Marks all messages to the caller as delivered. Returns the number of rows.
create or replace function public.mark_messages_delivered()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  changed integer;
begin
  if me is null then
    return 0;
  end if;

  update public.messages
    set delivered_at = now()
    where receiver_id = me
      and delivered_at is null;
  get diagnostics changed = row_count;
  return changed;
end;
$$;

create or replace function public.mark_messages_as_read(p_receiver_id uuid, p_sender_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Only the actual receiver may mark their own messages as read.
  if auth.uid() is null or auth.uid() <> p_receiver_id then
    raise exception 'not_authorized: caller must be the receiver';
  end if;

  update public.messages
    set read = true,
        delivered_at = coalesce(delivered_at, now())
    where receiver_id = p_receiver_id
      and sender_id = p_sender_id
      and read = false;
end;
$$;
