-- 1400_registration_withdrawals (PLAN 6.3): withdrawals, refunds and the waitlist.
--   * withdraw_registration: a member withdraws their own registration, or staff withdraw one with a reason, until the
--     division is drawn. Withdrawing twice is safe. A confirmed registration's fee charge is reversed in the ledger once
--     (a refund entry that points at the charge); money already paid stays on the member's account until an admin voids
--     the payment, exactly as for court bookings. The division entry is withdrawn with it.
--   * The waitlist is first come, first served (oldest first). A freed place (withdrawal, rejection, a bigger limit, or
--     no limit) promotes the oldest waitlisted registration back to "requested", where the club's approval and payment
--     rules apply as for anyone else. A waitlisted registration may now move to requested.
--   * Cancelling a division withdraws and refunds everyone registered in it (cancelling an event cancels its divisions).

-- waitlisted -> requested is the promotion.
create or replace function core.tg_registrations_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.event_id, old.division_id, old.member_id, old.fee_snapshot, old.payload_hash)
     is distinct from
     (new.event_id, new.division_id, new.member_id, new.fee_snapshot, new.payload_hash) then
    raise exception 'a registration''s event, division, member, fee and hash cannot change' using errcode = '42501';
  end if;
  perform core.check_transition('registration', old.status, new.status, '{
    "requested": ["confirmed", "waitlisted", "rejected", "withdrawn"],
    "confirmed": ["withdrawn"],
    "waitlisted": ["requested", "confirmed", "withdrawn"]
  }'::jsonb);
  return new;
end $$;

-- Promotes waitlisted registrations (oldest first) while the division has free places. Returns how many moved.
create or replace function core.promote_waitlist(p_division_id text) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions;
  v_taken integer;
  v_next public.registrations;
  v_moved integer := 0;
begin
  select * into dv from public.divisions where id = p_division_id for update;
  if not found or dv.status <> 'open' then
    return 0;
  end if;
  loop
    select count(*)::integer into v_taken from public.registrations r
    where r.division_id = dv.id and r.status in ('requested', 'confirmed');
    exit when dv.max_entries is not null and v_taken >= dv.max_entries;
    select * into v_next from public.registrations r
    where r.division_id = dv.id and r.status = 'waitlisted'
    order by r.created_at, r.id limit 1 for update;
    exit when not found;
    update public.registrations set status = 'requested', status_reason = 'Promoted from the waitlist' where id = v_next.id;
    perform core.try_confirm_registration(v_next.id);
    v_moved := v_moved + 1;
  end loop;
  return v_moved;
end $$;
revoke all on function core.promote_waitlist(text) from public, anon, authenticated;
grant execute on function core.promote_waitlist(text) to service_role;

-- Ends a registration: the entry is withdrawn and a posted fee is reversed once. Callers check who may do this.
create or replace function core.release_registration(p_registration_id text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r public.registrations;
  v_charge text;
begin
  select * into r from public.registrations where id = p_registration_id for update;
  if r.status not in ('requested', 'confirmed', 'waitlisted') then
    return;
  end if;
  update public.entries set status = 'withdrawn' where registration_id = r.id and status = 'active';
  if r.status = 'confirmed' and r.fee_snapshot > 0 then
    select e.id into v_charge from public.ledger_entries e
    where e.org_id = r.org_id and e.source_type = 'event_registration' and e.source_id = r.id and e.client_ref = 'charge';
    if v_charge is not null then
      perform core.post_ledger(r.org_id, r.member_id, r.fee_snapshot, 'event_registration', r.id, 'refund',
        'Event registration withdrawn', v_charge);
    end if;
  end if;
  update public.registrations set status = 'withdrawn', status_reason = p_reason where id = r.id;
end $$;
revoke all on function core.release_registration(text, text) from public, anon, authenticated;
grant execute on function core.release_registration(text, text) to service_role;

create or replace function core.withdraw_registration(p_registration_id text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r public.registrations;
  dv public.divisions;
  v_me public.members;
  v_own boolean;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into r from public.registrations x where x.id = p_registration_id for update;
  if not found then
    raise exception 'registration not found' using errcode = '22023';
  end if;
  select * into v_me from public.members m where m.profile_id = core.current_profile_id() and m.deleted_at is null;
  v_own := v_me.id is not null and v_me.id = r.member_id;
  if not v_own and not core.has_permission(r.org_id, null, 'registrations.manage') then
    raise exception 'you can only withdraw your own registration' using errcode = '42501';
  end if;
  if r.status = 'withdrawn' then
    return jsonb_build_object('id', r.id, 'status', 'withdrawn', 'unchanged', true);
  end if;
  if r.status not in ('requested', 'confirmed', 'waitlisted') then
    raise exception 'a registration that is % cannot be withdrawn', r.status using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;
  if not v_own and (v_reason is null or char_length(v_reason) < 3) then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  select * into dv from public.divisions where id = r.division_id;
  if dv.status <> 'open' then
    raise exception 'the draw has been made; ask the club to remove you' using errcode = '22023';
  end if;
  perform core.release_registration(r.id, coalesce(v_reason, 'Withdrawn by the member'));
  perform core.write_audit(r.org_id, 'registration.withdraw', 'public.registrations', r.id,
    jsonb_build_object('status', r.status), jsonb_build_object('status', 'withdrawn', 'reason', v_reason, 'by_member', v_own));
  return jsonb_build_object('id', r.id, 'status', 'withdrawn', 'refunded', r.status = 'confirmed' and r.fee_snapshot > 0);
end $$;

-- A place frees up when a requested or confirmed registration ends.
create or replace function core.tg_registrations_freed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('requested', 'confirmed') and new.status in ('rejected', 'withdrawn') then
    perform core.promote_waitlist(new.division_id);
  end if;
  return null;
end $$;
revoke all on function core.tg_registrations_freed() from public, anon, authenticated;
create trigger z_registrations_freed after update on public.registrations
  for each row execute function core.tg_registrations_freed();

-- A bigger (or removed) entry limit frees places too.
create or replace function core.tg_divisions_limit_raised() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'open' and (new.max_entries is null or new.max_entries > old.max_entries) then
    perform core.promote_waitlist(new.id);
  end if;
  return null;
end $$;
revoke all on function core.tg_divisions_limit_raised() from public, anon, authenticated;
create trigger z_divisions_limit_raised after update of max_entries on public.divisions
  for each row execute function core.tg_divisions_limit_raised();

-- A cancelled division releases everyone in it (and refunds those who had paid the fee charge).
create or replace function core.tg_divisions_cancelled() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_id text;
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    for v_id in
      select r.id from public.registrations r where r.division_id = new.id and r.status in ('requested', 'confirmed', 'waitlisted')
      order by r.created_at, r.id
    loop
      perform core.release_registration(v_id, 'Division cancelled');
    end loop;
  end if;
  return null;
end $$;
revoke all on function core.tg_divisions_cancelled() from public, anon, authenticated;
create trigger z_divisions_cancelled after update of status on public.divisions
  for each row execute function core.tg_divisions_cancelled();

-- ---- public wrapper
create or replace function public.withdraw_registration(p_registration_id text, p_reason text default null) returns jsonb
language sql security invoker set search_path = '' as $$ select core.withdraw_registration(p_registration_id, p_reason) $$;
revoke all on function core.withdraw_registration(text, text), public.withdraw_registration(text, text) from public, anon, authenticated;
grant execute on function core.withdraw_registration(text, text), public.withdraw_registration(text, text) to authenticated, service_role;
