-- Agent security-definer RPCs run with a restricted search_path. pgcrypto is
-- installed in extensions, so include it explicitly for digest/crypt helpers.

alter function public.submit_captain_command(
  uuid,
  varchar(120),
  varchar(2000),
  varchar(2000),
  text,
  jsonb,
  jsonb,
  text,
  text,
  varchar(64)
) set search_path = public, extensions, pg_temp;
