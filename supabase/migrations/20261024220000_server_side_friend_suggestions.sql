-- Friend suggestions are computed on the server.
-- Before, the app loaded 350 arbitrary profiles and compared their usernames
-- with the names in the phone's contacts; anyone outside those 350 was never
-- found, and mutual friends were always 0 (RLS hides other people's
-- friendships from the app).
--
-- Now the app sends SHA-256 hashes of its contacts' e-mail addresses (never
-- the addresses) plus name tokens, and public.friend_suggestions() matches
-- them against all accounts that allow contact discovery, adds friends of
-- friends and falls back to recently active public posters.

-- The foreign key to auth.users (removing the row with the account) is added
-- by supabase/manual/20261024_contact_hashes_fk.sql. Until then rows of
-- removed accounts never match: suggestions join users_profile.
create table if not exists internal.contact_hashes (
  user_id uuid primary key,
  email_hash text not null
);

create index if not exists contact_hashes_email_hash_idx
  on internal.contact_hashes (email_hash);

create or replace function internal.email_hash(p_email text)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    encode(pg_catalog.sha256(convert_to(lower(trim(p_email)), 'UTF8')), 'hex'),
    ''
  );
$$;

create or replace function internal.sync_contact_hash()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into internal.contact_hashes (user_id, email_hash)
  values (new.id, internal.email_hash(new.email))
  on conflict (user_id) do update set email_hash = excluded.email_hash;
  return new;
exception when others then
  -- Never block a sign-up or an e-mail change because of suggestions.
  return new;
end;
$$;

create or replace trigger sync_contact_hash
  after insert or update of email on auth.users
  for each row execute function internal.sync_contact_hash();

insert into internal.contact_hashes (user_id, email_hash)
select u.id, internal.email_hash(u.email)
from auth.users u
on conflict (user_id) do update set email_hash = excluded.email_hash;

create or replace function public.friend_suggestions(
  p_email_hashes text[] default '{}',
  p_name_tokens text[] default '{}',
  p_limit integer default 30
)
returns table (
  id uuid,
  username text,
  profile_picture text,
  matched_contact boolean,
  mutual_friends integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_hashes text[] := coalesce(p_email_hashes[1:2000], '{}');
  v_tokens text[];
begin
  if me is null then
    return;
  end if;

  select coalesce(array_agg(distinct lower(t)), '{}')
    into v_tokens
  from unnest(coalesce(p_name_tokens[1:1000], '{}')) as t
  where length(t) >= 3;

  -- A match tells whether an address has an account: limit the lookups.
  -- Over the limit the call still works, just without contact matching.
  if cardinality(v_hashes) > 0 or cardinality(v_tokens) > 0 then
    begin
      perform internal.hit_rate_limit(me, 'contact_match', 30, interval '1 hour');
    exception when others then
      v_hashes := '{}';
      v_tokens := '{}';
    end;
  end if;

  return query
  with my_rel as (
    select case when f.user_id = me then f.friend_id else f.user_id end as other,
           f.status
    from public.friends f
    where f.user_id = me or f.friend_id = me
  ),
  excluded as (
    select me as uid
    union select r.other from my_rel r
    union select b.blocked_id from public.user_blocks b where b.blocker_id = me
    union select b.blocker_id from public.user_blocks b where b.blocked_id = me
  ),
  mutual as (
    select case when f.user_id = r.other then f.friend_id else f.user_id end as cand,
           count(*)::integer as n
    from my_rel r
    join public.friends f
      on f.status = 'accepted' and r.other in (f.user_id, f.friend_id)
    where r.status = 'accepted'
    group by 1
  ),
  contact as (
    select h.user_id as cand, 80 as points
    from internal.contact_hashes h
    where h.email_hash = any (v_hashes)
    union all
    select up.id, 40
    from public.users_profile up
    where lower(up.username) = any (v_tokens)
  ),
  recent as (
    select p.user_id as cand, max(p.server_created_at) as last_post
    from public.photos p
    where p.is_public and p.server_created_at > now() - interval '14 days'
    group by p.user_id
  ),
  scored as (
    select up.id,
           up.username,
           up.profile_picture,
           coalesce(c.points, 0) > 0 as matched_contact,
           coalesce(m.n, 0) as mutual_friends,
           coalesce(m.n, 0) * 100 + coalesce(c.points, 0) as score,
           rc.last_post
    from public.users_profile up
    left join mutual m on m.cand = up.id
    left join (
      select contact.cand, max(contact.points) as points
      from contact group by contact.cand
    ) c on c.cand = up.id and up.allow_contact_discovery is not false
    left join recent rc on rc.cand = up.id
    where up.id not in (select e.uid from excluded e)
      and coalesce(trim(up.username), '') <> ''
      and (m.n is not null or c.points is not null or rc.cand is not null)
  )
  select s.id, s.username, s.profile_picture, s.matched_contact, s.mutual_friends
  from scored s
  order by s.score desc, s.last_post desc nulls last, lower(s.username)
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
end;
$$;
