-- 1220_fix_my_dashboard (PLAN 3.6): events is a document table with no deleted_at; otherwise as 1210.
-- The numbers behind the role-aware home page.
-- One read-only call. A section appears only when the caller holds the matching permission, so the page
-- cannot show staff figures to a member (the permission is checked here, not in the browser).
--   member : own member card, current rank, upcoming bookings, open event registrations, unread notices
--   staff  : members waiting for approval, payment proofs to verify, bookings to approve, today's bookings
--            (Asia/Manila), events in progress
create or replace function core.my_dashboard() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_profile text := core.current_profile_id();
  v_org text;
  v_member text;
  v_out jsonb := '{}'::jsonb;
  v_role record;
  v_next record;
  v_rank record;
  v_day_start timestamptz := (date_trunc('day', now() at time zone 'Asia/Manila')) at time zone 'Asia/Manila';
begin
  if v_profile is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  select p.org_id into v_org from public.profiles p where p.id = v_profile;
  select r.code, r.name into v_role from public.org_members om join public.roles r on r.id = om.role_id
    where om.profile_id = v_profile and om.is_active and om.deleted_at is null limit 1;
  v_out := jsonb_build_object('role_code', v_role.code, 'role_name', v_role.name);

  select m.id into v_member from public.members m
    where m.profile_id = v_profile and m.deleted_at is null limit 1;
  if v_member is not null then
    select c.name as category, rk.name as rank_name into v_rank
      from public.member_ranks mr join public.ranks rk on rk.id = mr.rank_id
      join public.rank_ladders l on l.id = rk.ladder_id join public.categories c on c.id = l.category_id
      where mr.member_id = v_member and mr.deleted_at is null limit 1;
    select b.court_name_snapshot as court, lower(b.during) as starts_at, b.status into v_next
      from public.bookings b
      where b.requested_by_member_id = v_member and b.status in ('pending_approval', 'confirmed')
        and upper(b.during) > now()
      order by lower(b.during) limit 1;
    v_out := v_out || jsonb_build_object('member', jsonb_build_object(
      'rank', case when v_rank.rank_name is null then null
                   else jsonb_build_object('category', v_rank.category, 'name', v_rank.rank_name) end,
      'upcoming_bookings', (select count(*) from public.bookings b
        where b.requested_by_member_id = v_member and b.status in ('pending_approval', 'confirmed')
          and upper(b.during) > now()),
      'next_booking', case when v_next.starts_at is null then null
        else jsonb_build_object('court', v_next.court, 'starts_at', v_next.starts_at, 'status', v_next.status) end,
      'open_registrations', (select count(*) from public.registrations g join public.events e on e.id = g.event_id
        where g.member_id = v_member and g.status in ('requested', 'confirmed', 'waitlisted')
          and e.status not in ('completed', 'cancelled')),
      'unread_notices', (select count(*) from public.notifications n
        where n.recipient_profile_id = v_profile and n.channel = 'in_app' and n.read_at is null)));
  end if;

  if core.has_permission(v_org, null, 'members.approve') then
    v_out := v_out || jsonb_build_object('pending_members',
      (select count(*) from public.members m where m.org_id = v_org and m.status = 'pending_approval' and m.deleted_at is null));
  end if;
  if core.has_permission(v_org, null, 'payments.verify') then
    v_out := v_out || jsonb_build_object('pending_proofs',
      (select count(*) from public.payment_submissions s where s.org_id = v_org and s.status = 'submitted'));
  end if;
  if core.has_permission(v_org, null, 'bookings.approve') then
    v_out := v_out || jsonb_build_object('pending_bookings',
      (select count(*) from public.bookings b where b.org_id = v_org and b.status = 'pending_approval' and upper(b.during) > now()));
  end if;
  if core.has_permission(v_org, null, 'bookings.read_all') then
    v_out := v_out || jsonb_build_object('todays_bookings',
      (select count(*) from public.bookings b where b.org_id = v_org and b.status in ('confirmed', 'checked_in', 'completed')
         and b.during && tstzrange(v_day_start, v_day_start + interval '1 day', '[)')));
  end if;
  if core.has_permission(v_org, null, 'events.manage') then
    v_out := v_out || jsonb_build_object('active_events',
      (select count(*) from public.events e where e.org_id = v_org
         and e.status in ('registration_open', 'registration_closed', 'drawn', 'in_progress')));
  end if;
  return v_out;
end $$;

create or replace function public.my_dashboard() returns jsonb
language sql stable security invoker set search_path = '' as $$ select core.my_dashboard() $$;

revoke all on function core.my_dashboard(), public.my_dashboard() from public, anon, authenticated;
grant execute on function core.my_dashboard(), public.my_dashboard() to authenticated, service_role;
