-- Wording: "Quest" for the daily task, "Duell" for 1-vs-1 (matches the app).

create or replace function public.push_on_challenge_insert()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
begin
  if new.status is distinct from 'pending'
    or new.challenged_id is null
    or new.challenger_id = new.challenged_id then
    return new;
  end if;

  perform public.enqueue_sidequest_push(
    jsonb_build_object(
      'type', 'challenged',
      'recipient_user_ids', jsonb_build_array(new.challenged_id),
      'title', 'SideQuest ⚔️',
      'body', 'Du wurdest zum Duell herausgefordert! Du hast 2 Stunden zum Annehmen.',
      'data', jsonb_build_object(
        'kind', 'challenged',
        'target_tab', '1',
        'challenger_id', new.challenger_id,
        'challenge_id', new.id
      )
    )
  );

  return new;
end;
$$;
