-- PLAN 8.4b: the security-invoker public wrappers from 1840 need execute on their
-- core functions, as in 1500. Each core function checks the caller's permission.
grant execute on function core.set_member_cpc_rating(text,numeric,integer,text,text),
  core.set_event_participant_cpc_rating(text,numeric,integer,text,text),
  core.initialize_member_cpc_ratings(text), core.snapshot_division_cpc_ratings(text)
  to authenticated, service_role;

notify pgrst, 'reload schema';
