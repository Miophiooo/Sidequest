-- Run once in the Supabase SQL editor (the migration tool can't run this).
-- Removes a user's contact hash together with their account.
alter table internal.contact_hashes
  add constraint contact_hashes_user_id_fkey
  foreign key (user_id) references auth.users (id) on delete cascade;
