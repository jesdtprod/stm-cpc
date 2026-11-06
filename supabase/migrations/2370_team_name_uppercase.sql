-- Team names are stored in capitals.
create or replace function core.team_name_clean(p_name text) returns text
language sql immutable set search_path = '' as $$
  select nullif(upper(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'))), '')
$$;
