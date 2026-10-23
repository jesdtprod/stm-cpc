-- 1260_rank_ladder_functions (PLAN 4.3): two functions for editing a ladder as a whole, and the club's rank rule.
--   reorder_ranks(ladder, [rank ids], key)   sets the order of every active rank in the ladder in one step (the first id is
--                                            the lowest rank). The unique order index forbids swapping rows one by one.
--   set_starting_rank(rank, key)             makes one rank the ladder's starting rank and clears the previous one in
--                                            the same step (a ladder has exactly one).
-- Both need ranks.manage in the ladder's club, take an idempotency key, and are audited.
-- Also seeds the split single elimination rule the club decided (FEATURES 8.3), once, if the club has no rules yet:
--   won the H bracket = up 1, lost the H bracket = retain, won the L bracket = retain, lost the L bracket = down 1.
-- The admin edits or replaces these on the Ranks page; nothing here is code.

create or replace function core.reorder_ranks(p_ladder_id text, p_rank_ids text[], p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_org text;
  v_have text[];
  v_replay jsonb;
  v_response jsonb;
  v_i integer;
begin
  select l.org_id into v_org from public.rank_ladders l where l.id = p_ladder_id and l.deleted_at is null for update;
  if v_org is null then
    raise exception 'ladder not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_org, null, 'ranks.manage') then
    raise exception 'you do not have permission to change ranks' using errcode = '42501';
  end if;
  select coalesce(array_agg(r.id order by r.sort_order), '{}') into v_have
  from public.ranks r where r.ladder_id = p_ladder_id and r.deleted_at is null;
  if p_rank_ids is null or cardinality(p_rank_ids) <> cardinality(v_have)
     or exists (select 1 from unnest(p_rank_ids) x where x <> all (v_have))
     or (select count(distinct x) from unnest(p_rank_ids) x) <> cardinality(v_have) then
    raise exception 'the new order must list every rank of the ladder exactly once' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_key, v_org, 'ranks.reorder',
    jsonb_build_object('ladder', p_ladder_id, 'order', to_jsonb(p_rank_ids)));
  if v_replay is not null then
    return v_replay;
  end if;
  if v_have = p_rank_ids then
    v_response := jsonb_build_object('ok', true, 'ladder_id', p_ladder_id, 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;

  update public.ranks set sort_order = sort_order + 1000000 where ladder_id = p_ladder_id and deleted_at is null;
  for v_i in 1 .. cardinality(p_rank_ids) loop
    update public.ranks set sort_order = v_i - 1 where id = p_rank_ids[v_i];
  end loop;
  perform core.write_audit(v_org, 'ranks.reorder', 'public.rank_ladders', p_ladder_id,
    jsonb_build_object('order', to_jsonb(v_have)), jsonb_build_object('order', to_jsonb(p_rank_ids)));
  v_response := jsonb_build_object('ok', true, 'ladder_id', p_ladder_id);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function core.set_starting_rank(p_rank_id text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_rank public.ranks;
  v_replay jsonb;
  v_response jsonb;
begin
  select * into v_rank from public.ranks r where r.id = p_rank_id and r.deleted_at is null for update;
  if not found then
    raise exception 'rank not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_rank.org_id, null, 'ranks.manage') then
    raise exception 'you do not have permission to change ranks' using errcode = '42501';
  end if;

  v_replay := core.idem_begin(p_key, v_rank.org_id, 'ranks.set_starting', jsonb_build_object('rank', p_rank_id));
  if v_replay is not null then
    return v_replay;
  end if;
  if v_rank.is_starting then
    v_response := jsonb_build_object('ok', true, 'rank_id', p_rank_id, 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;

  update public.ranks set is_starting = false where ladder_id = v_rank.ladder_id and is_starting and deleted_at is null;
  update public.ranks set is_starting = true where id = p_rank_id;
  perform core.write_audit(v_rank.org_id, 'ranks.set_starting', 'public.ranks', p_rank_id, null,
    jsonb_build_object('ladder_id', v_rank.ladder_id, 'rank', v_rank.name));
  v_response := jsonb_build_object('ok', true, 'rank_id', p_rank_id);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function public.reorder_ranks(p_ladder_id text, p_rank_ids text[], p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.reorder_ranks(p_ladder_id, p_rank_ids, p_key) $$;
create or replace function public.set_starting_rank(p_rank_id text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.set_starting_rank(p_rank_id, p_key) $$;

revoke all on function core.reorder_ranks(text, text[], text), core.set_starting_rank(text, text),
  public.reorder_ranks(text, text[], text), public.set_starting_rank(text, text) from public, anon, authenticated;
-- The functions check ranks.manage themselves.
grant execute on function core.reorder_ranks(text, text[], text), core.set_starting_rank(text, text),
  public.reorder_ranks(text, text[], text), public.set_starting_rank(text, text) to authenticated, service_role;

-- The club's split single elimination rule, once.
insert into public.rank_rules (org_id, name, conditions, action, levels, priority)
select o.id, v.name, v.conditions, v.action, v.levels, v.priority
from public.orgs o
cross join (values
  ('Won the H bracket', '{"bracket_tier": "H", "bracket_result": "won"}'::jsonb, 'up', 1, 10),
  ('Lost the H bracket', '{"bracket_tier": "H", "bracket_result": "lost"}'::jsonb, 'retain', 0, 20),
  ('Won the L bracket', '{"bracket_tier": "L", "bracket_result": "won"}'::jsonb, 'retain', 0, 30),
  ('Lost the L bracket', '{"bracket_tier": "L", "bracket_result": "lost"}'::jsonb, 'down', 1, 40)
) as v(name, conditions, action, levels, priority)
where o.code = 'cpc'
  and not exists (select 1 from public.rank_rules r where r.org_id = o.id and r.deleted_at is null);
