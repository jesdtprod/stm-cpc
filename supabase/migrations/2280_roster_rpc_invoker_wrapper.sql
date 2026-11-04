-- Match the existing RPC convention: exposed invoker wrapper, protected core implementation.
alter function public.edit_division_roster(text,text,text,text,text,integer,integer,text,text,jsonb) set schema core;
create function public.edit_division_roster(p_key text,p_division_id text,p_action text,p_source_id text,
  p_target_id text default null,p_source_player integer default null,p_target_player integer default null,
  p_replacement text default null,p_reason text default null,p_versions jsonb default '{}'::jsonb)
returns jsonb language sql security invoker set search_path = '' as $$
  select core.edit_division_roster(p_key,p_division_id,p_action,p_source_id,p_target_id,
    p_source_player,p_target_player,p_replacement,p_reason,p_versions)
$$;
revoke all on function public.edit_division_roster(text,text,text,text,text,integer,integer,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.edit_division_roster(text,text,text,text,text,integer,integer,text,text,jsonb) to authenticated;
notify pgrst,'reload schema';
