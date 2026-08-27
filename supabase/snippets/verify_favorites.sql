-- Read-only verification checklist for the favorites migration.
-- Run after applying migrations to an isolated or target database.

select
  to_regclass('public.favorites') is not null as favorites_table_exists,
  to_regclass('public.favorite_idempotency_keys') is not null
    as favorite_idempotency_table_exists;

select
  c.relrowsecurity as favorites_rls_enabled,
  not has_table_privilege('authenticated', 'public.favorites', 'INSERT')
    as authenticated_insert_revoked,
  not has_table_privilege('authenticated', 'public.favorites', 'UPDATE')
    as authenticated_update_revoked,
  not has_table_privilege('authenticated', 'public.favorites', 'DELETE')
    as authenticated_delete_revoked
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'favorites';

select
  has_function_privilege(
    'authenticated', 'public.add_favorite(uuid,uuid)', 'EXECUTE'
  ) as add_rpc_granted,
  has_function_privilege(
    'authenticated', 'public.remove_favorite(uuid,uuid)', 'EXECUTE'
  ) as remove_rpc_granted,
  has_function_privilege(
    'authenticated', 'public.get_favorite_statuses(uuid[])', 'EXECUTE'
  ) as statuses_rpc_granted,
  has_function_privilege(
    'authenticated', 'public.list_favorites(integer,integer)', 'EXECUTE'
  ) as list_rpc_granted,
  not has_function_privilege(
    'anon', 'public.add_favorite(uuid,uuid)', 'EXECUTE'
  ) as anon_add_revoked;

select
  conname,
  pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.favorites'::regclass
order by conname;
