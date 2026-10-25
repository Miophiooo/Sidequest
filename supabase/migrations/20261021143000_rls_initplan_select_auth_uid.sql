-- Performance: wrap auth.uid() in RLS policies as (select auth.uid()) so
-- Postgres evaluates it once per query instead of once per row
-- (Supabase advisor "auth_rls_initplan"). Semantics are unchanged.
do $$
declare
  r record;
begin
  for r in
    select
      schemaname,
      tablename,
      policyname,
      qual,
      with_check,
      replace(replace(replace(qual, '( SELECT auth.uid() AS uid)', '§§'), 'auth.uid()', '( SELECT auth.uid() AS uid)'), '§§', '( SELECT auth.uid() AS uid)') as new_qual,
      replace(replace(replace(with_check, '( SELECT auth.uid() AS uid)', '§§'), 'auth.uid()', '( SELECT auth.uid() AS uid)'), '§§', '( SELECT auth.uid() AS uid)') as new_check
    from pg_policies
    where schemaname in ('public', 'storage')
      and (coalesce(qual, '') ~ 'auth\.uid\(\)' or coalesce(with_check, '') ~ 'auth\.uid\(\)')
  loop
    if r.new_qual is distinct from r.qual or r.new_check is distinct from r.with_check then
      execute format('alter policy %I on %I.%I', r.policyname, r.schemaname, r.tablename)
        || coalesce(' using (' || r.new_qual || ')', '')
        || coalesce(' with check (' || r.new_check || ')', '');
    end if;
  end loop;
end $$;
