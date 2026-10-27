-- One reservation of at most one hour per requesting member per Manila day.
-- Existing reservations remain intact, and idempotent retries still replay them.
create index bookings_requester_day_lookup_idx
  on public.bookings (requested_by_member_id, (lower(during)))
  where status in ('pending_approval', 'confirmed', 'checked_in', 'completed', 'no_show');

create or replace function core.booking_daily_limit_problem(
  p_member_id text, p_starts_at timestamptz, p_minutes integer
) returns text
language sql stable set search_path = '' as $$
  select case
    when p_minutes > 60 then 'A booking can be at most 1 hour. Only 1 booking is allowed per day.'
    when exists (
      select 1 from public.bookings b
      where b.requested_by_member_id = p_member_id
        and b.status in ('pending_approval', 'confirmed', 'checked_in', 'completed', 'no_show')
        and not (b.status = 'pending_approval' and b.expires_at is not null and b.expires_at <= now())
        and lower(b.during) >= ((p_starts_at at time zone 'Asia/Manila')::date::timestamp at time zone 'Asia/Manila')
        and lower(b.during) < (((p_starts_at at time zone 'Asia/Manila')::date + 1)::timestamp at time zone 'Asia/Manila')
    ) then 'You already have a booking for this day. Only 1 booking of up to 1 hour is allowed per day.'
    else null
  end
$$;
revoke all on function core.booking_daily_limit_problem(text, timestamptz, integer)
  from public, anon, authenticated;

-- Patch the current definitions so the midnight fix and existing permissions stay intact.
do $$
declare
  v_definition text;
  v_old text;
begin
  v_definition := pg_get_functiondef('core.request_booking(text,text,timestamptz,integer,text[])'::regprocedure);
  v_old := '  -- The same request again returns the same booking; another request under the same ID is refused.';
  if strpos(v_definition, v_old) = 0 then raise exception 'request_booking replay marker not found'; end if;
  v_definition := replace(v_definition, v_old, $patch$
  -- Serialize all requests by this member, including concurrent retries of one ID.
  perform 1 from public.members m where m.id = v_member.id for update;
$patch$ || v_old);
  v_old := '  perform core.expire_bookings();';
  if strpos(v_definition, v_old) = 0 then raise exception 'request_booking expiry marker not found'; end if;
  v_definition := replace(v_definition, v_old, v_old || $patch$
  v_other := core.booking_daily_limit_problem(v_member.id, p_starts_at, p_minutes);
  if v_other is not null then
    raise exception '%', v_other using errcode = '22023';
  end if;
$patch$);
  execute v_definition;

  v_definition := pg_get_functiondef('core.quote_booking(text,timestamptz,integer)'::regprocedure);
  v_old := '  v_org := v_me.org_id;';
  if strpos(v_definition, v_old) = 0 then raise exception 'quote_booking member marker not found'; end if;
  execute replace(v_definition, v_old, v_old || $patch$
  v_problem := core.booking_daily_limit_problem(v_me.id, p_starts_at, p_minutes);
  if v_problem is not null then
    return jsonb_build_object('ok', false, 'problem', v_problem);
  end if;
$patch$);
end $$;
