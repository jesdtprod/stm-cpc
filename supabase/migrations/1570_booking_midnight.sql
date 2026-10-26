-- 23:59 is the UI's end-of-day marker, just like 23:59:59 and 24:00.
-- Compare full Manila timestamps so midnight cannot bypass an earlier closing time.
create or replace function core.booking_window_contains(
  p_start timestamp, p_end timestamp, p_opens time, p_closes time
) returns boolean
language sql immutable set search_path = '' as $$
  select p_end > p_start
    and p_start >= p_start::date + p_opens
    and p_end <= case when p_closes >= time '23:59'
      then p_start::date + interval '1 day'
      else p_start::date + p_closes end
$$;
revoke all on function core.booking_window_contains(timestamp, timestamp, time, time)
  from public, anon, authenticated;

-- Replace only the hours predicates, retaining the existing RPC bodies and grants.
-- Fail explicitly if an earlier migration changed either expected predicate.
do $$
declare
  v_definition text;
  v_old text;
begin
  v_definition := pg_get_functiondef('core.request_booking(text,text,timestamptz,integer,text[])'::regprocedure);
  v_old := $predicate$v_local_start::time < v_hours.opens_at or (v_local_end::time > v_hours.closes_at and v_local_end::time <> '00:00')
     or (v_local_end::time = '00:00' and v_hours.closes_at <> '23:59:59' and v_hours.closes_at <> '24:00')$predicate$;
  if strpos(v_definition, v_old) = 0 then
    raise exception 'request_booking hours predicate not found';
  end if;
  execute replace(v_definition, v_old,
    'not core.booking_window_contains(v_local_start, v_local_end, v_hours.opens_at, v_hours.closes_at)');

  v_definition := pg_get_functiondef('core.quote_booking(text,timestamptz,integer)'::regprocedure);
  v_old := $predicate$v_ls::time < v_hours.opens_at or (v_le::time > v_hours.closes_at and v_le::time <> '00:00')$predicate$;
  if strpos(v_definition, v_old) = 0 then
    raise exception 'quote_booking hours predicate not found';
  end if;
  execute replace(v_definition, v_old,
    'not core.booking_window_contains(v_ls, v_le, v_hours.opens_at, v_hours.closes_at)');
end $$;
