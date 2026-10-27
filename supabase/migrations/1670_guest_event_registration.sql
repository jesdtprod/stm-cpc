-- PLAN 6.2b. Guests share the registration, payment and entry lifecycle; they
-- never acquire memberships. Guest roster rows are separate from entry_members,
-- so member rank movement and member notifications continue to address members.
alter table public.events add column allow_guest_players boolean not null default false;
alter table public.registrations
  alter column member_id drop not null,
  add column guest_participant_id text collate "C" references public.event_participants(id) on delete restrict,
  add column guest_partner_participant_id text collate "C" references public.event_participants(id) on delete restrict,
  add column guest_rank_id text collate "C" references public.ranks(id) on delete restrict,
  add column guest_partner_rank_id text collate "C" references public.ranks(id) on delete restrict,
  add column guest_name_snapshot text,
  add column guest_partner_name_snapshot text,
  add constraint registrations_person_kind_chk check ((member_id is null) <> (guest_participant_id is null));
create index registrations_guest_idx on public.registrations(guest_participant_id);
create index registrations_guest_partner_idx on public.registrations(guest_partner_participant_id);
create index registrations_guest_rank_idx on public.registrations(guest_rank_id);
create index registrations_guest_partner_rank_idx on public.registrations(guest_partner_rank_id);
create unique index registrations_guest_live_uq on public.registrations(division_id, guest_participant_id)
  where status in ('requested', 'confirmed', 'waitlisted');
alter table public.payment_submissions
  alter column payer_member_id drop not null,
  add column payer_person_id text collate "C" references public.persons(id) on delete restrict,
  add column payer_name_snapshot text,
  add constraint payment_submissions_payer_kind_chk check ((payer_member_id is null) <> (payer_person_id is null));
create index payment_submissions_person_idx on public.payment_submissions(payer_person_id);
alter table public.ledger_accounts drop constraint ledger_accounts_owner_type_chk;
alter table public.ledger_accounts add constraint ledger_accounts_owner_type_chk check (owner_type in ('member', 'guest'));

create table public.entry_guests (
  id text collate "C" primary key default core.ulid(),
  org_id text collate "C" not null references public.orgs(id) on delete restrict,
  unit_id text collate "C" references public.org_units(id) on delete restrict,
  entry_id text collate "C" not null references public.entries(id) on delete restrict,
  participant_id text collate "C" not null references public.event_participants(id) on delete restrict,
  display_name_snapshot text not null,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  version integer not null default 1,
  meta jsonb not null default '{}'::jsonb,
  constraint entry_guests_person_uq unique(entry_id, participant_id)
);
comment on table public.entry_guests is 'class: document. Guest entry roster snapshots; frozen after creation. Names only; no contact data. No CPC member rank changes.';
create index entry_guests_org_idx on public.entry_guests(org_id);
create index entry_guests_unit_idx on public.entry_guests(unit_id);
create index entry_guests_participant_idx on public.entry_guests(participant_id);
select core.attach_standard('public.entry_guests', 'document');
select core.enable_standard_rls('public.entry_guests', 'org', 'events');
drop policy entry_guests_select on public.entry_guests;
drop policy entry_guests_insert on public.entry_guests;
drop policy entry_guests_update on public.entry_guests;
create policy entry_guests_select on public.entry_guests for select to authenticated using (
  core.has_permission(org_id, unit_id, 'events.manage') or
  core.has_permission(org_id, unit_id, 'registrations.manage') or exists (
    select 1 from public.entries e join public.divisions d on d.id = e.division_id
    where e.id = entry_id and d.status in ('drawn', 'in_progress', 'finalized')));
revoke all on public.entry_guests from public, anon, authenticated;
grant select on public.entry_guests to authenticated;
create trigger c2_entry_guests_frozen before update on public.entry_guests
  for each row execute function core.tg_entry_members_frozen();

-- Return the real debtor without assigning a guest fee to a staff member.
create function core.registration_payer(p_id text) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(r.member_id, ep.person_id) from public.registrations r
  left join public.event_participants ep on ep.id = r.guest_participant_id where r.id = p_id
$$;
revoke all on function core.registration_payer(text) from public, anon, authenticated;

create function public.set_event_guest_policy(p_event_id text, p_allow boolean, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare ev public.events; replay jsonb; result jsonb;
begin
  select * into ev from public.events where id = p_event_id for update;
  if not found or not core.has_permission(ev.org_id, ev.unit_id, 'events.manage') then
    raise exception 'You do not have permission to manage this event' using errcode = '42501';
  end if;
  if p_allow is null then raise exception 'Choose whether to allow guests' using errcode = '22023'; end if;
  replay := core.idem_begin(p_key, ev.org_id, 'event.guest_policy', jsonb_build_object('event',p_event_id,'allow',p_allow));
  if replay is not null then return replay; end if;
  if ev.status <> 'draft' then raise exception 'Guest registration policy is locked after draft' using errcode = '22023'; end if;
  update public.events set allow_guest_players = p_allow where id = ev.id and allow_guest_players is distinct from p_allow;
  result := jsonb_build_object('id', ev.id, 'allow_guest_players', p_allow);
  perform core.idem_complete(p_key, result);
  return result;
end $$;
revoke all on function public.set_event_guest_policy(text,boolean,text) from public, anon, authenticated;
grant execute on function public.set_event_guest_policy(text,boolean,text) to authenticated;

create function core.tg_event_guest_policy() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.allow_guest_players is distinct from old.allow_guest_players and old.status <> 'draft' then
    raise exception 'Guest registration policy is locked after draft' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_event_guest_policy() from public, anon, authenticated;
create trigger c_guest_policy before update on public.events for each row execute function core.tg_event_guest_policy();

create function core.guest_registration_problem(p_participant text, p_division text, p_rank text, p_confirm boolean default false) returns text
language plpgsql stable security definer set search_path = '' as $$
declare ep public.event_participants; pe public.persons; dv public.divisions; ev public.events;
  rk record; lo integer; hi integer; age_years integer; grp text;
begin
  select * into ep from public.event_participants where id = p_participant and deleted_at is null;
  if not found or ep.member_id is not null then return 'Choose a guest participant.'; end if;
  select * into dv from public.divisions where id = p_division;
  if not found or dv.event_id <> ep.event_id or dv.org_id <> ep.org_id then return 'That participant belongs to another event.'; end if;
  select * into ev from public.events where id = dv.event_id;
  if not ev.allow_guest_players then return 'This event does not allow guest players.'; end if;
  if ev.dupr_rated then return 'DUPR guest eligibility is not available yet.'; end if;
  if dv.status <> 'open' or (ev.status <> 'registration_open' and not (p_confirm and ev.status = 'registration_closed')) then return 'Registration is not open.'; end if;
  if not p_confirm and ((ev.registration_opens_at is not null and now() < ev.registration_opens_at)
    or (ev.registration_closes_at is not null and now() >= ev.registration_closes_at)) then return 'Outside the registration window.'; end if;
  select * into pe from public.persons where id = ep.person_id and kind = 'guest' and deleted_at is null;
  if not found or exists(select 1 from public.members where person_id = pe.id) then return 'Choose an active guest identity.'; end if;
  select r.sort_order, l.category_id into rk from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
    join public.categories c on c.id = l.category_id
    where r.id = p_rank and r.deleted_at is null and l.deleted_at is null and c.deleted_at is null and r.org_id = ep.org_id;
  if not found or rk.category_id <> dv.category_id then return 'Assess the guest at a rank in this division category.'; end if;
  select sort_order into lo from public.ranks where id = dv.min_rank_id;
  select sort_order into hi from public.ranks where id = dv.max_rank_id;
  if rk.sort_order < lo or rk.sort_order > hi then return 'The guest rank is outside this division rank band.'; end if;
  if dv.gender in ('male','female') and pe.gender is distinct from dv.gender then return 'The guest does not meet this division gender requirement.'; end if;
  grp := btrim(coalesce(dv.age_group,''));
  if grp ~ '^\d{1,2}\+$' or grp ~ '^\d{1,2}\s*-\s*\d{1,2}$' then
    if pe.date_of_birth is null then return 'The guest birth date is required for this age group.'; end if;
    age_years := extract(year from age(ev.starts_on, pe.date_of_birth))::integer;
    if age_years < substring(grp from '^\d+')::integer
      or (grp !~ '\+$' and age_years > substring(grp from '(\d+)$')::integer) then return 'The guest does not meet this division age requirement.'; end if;
  end if;
  return null;
end $$;
revoke all on function core.guest_registration_problem(text,text,text,boolean) from public, anon, authenticated;

create function public.register_guest_for_event(p_id text, p_division_id text, p_participant_id text,
  p_rank_id text, p_partner_participant_id text default null, p_partner_rank_id text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare dv public.divisions; ev public.events; ep public.event_participants; partner public.event_participants;
  existing public.registrations; problem text; payload text; taken integer; reg_status text;
  guest_partner text; member_partner text; guest_name text; partner_name text;
begin
  select * into dv from public.divisions where id = p_division_id for update;
  if not found or not core.has_permission(dv.org_id, dv.unit_id, 'events.manage')
    or not core.has_permission(dv.org_id, dv.unit_id, 'registrations.manage') then
    raise exception 'You do not have permission to register guest players' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then raise exception 'A registration ID is required' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('registration:' || p_id,0));
  payload := core.hash_of(jsonb_build_object('division',p_division_id,'guest',p_participant_id,'rank',p_rank_id,
    'partner',p_partner_participant_id,'partner_rank',p_partner_rank_id));
  select * into existing from public.registrations where id = p_id;
  if found then
    if existing.org_id <> dv.org_id or existing.payload_hash <> payload then
      raise exception 'This registration ID was used for a different request' using errcode = 'CP422';
    end if;
    return jsonb_build_object('id',p_id,'status',existing.status,'fee',existing.fee_snapshot,'replayed',true);
  end if;
  select * into ev from public.events where id = dv.event_id;
  problem := core.guest_registration_problem(p_participant_id,dv.id,p_rank_id);
  if problem is not null then raise exception '%',problem using errcode = '22023'; end if;
  select * into ep from public.event_participants where id = p_participant_id;
  select display_name into guest_name from public.persons where id = ep.person_id;
  if dv.format = 'doubles' then
    if p_partner_participant_id is null or p_partner_participant_id = ep.id then
      raise exception 'Choose another participant as the doubles partner' using errcode = '22023';
    end if;
    select * into partner from public.event_participants where id = p_partner_participant_id
      and event_id = ev.id and org_id = ev.org_id and deleted_at is null;
    if not found then raise exception 'Choose a partner from this event' using errcode = '22023'; end if;
    if partner.member_id is not null then
      if p_partner_rank_id is not null then raise exception 'Member rank comes from their profile' using errcode = '22023'; end if;
      problem := core.registration_problem(partner.member_id,dv.id,true);
      member_partner := partner.member_id;
    else
      problem := core.guest_registration_problem(partner.id,dv.id,p_partner_rank_id);
      guest_partner := partner.id;
      select display_name into partner_name from public.persons where id = partner.person_id;
    end if;
    if problem is not null then raise exception 'Partner cannot join: %',problem using errcode = '22023'; end if;
  elsif p_partner_participant_id is not null or p_partner_rank_id is not null then
    raise exception 'Singles take no partner' using errcode = '22023';
  end if;
  if exists(select 1 from public.registrations r where r.division_id = dv.id and r.status in ('requested','confirmed','waitlisted')
    and (r.guest_participant_id in (ep.id,guest_partner) or r.guest_partner_participant_id in (ep.id,guest_partner)
      or (member_partner is not null and (r.member_id = member_partner or r.meta->>'partner_member_id' = member_partner)))) then
    raise exception 'A player already has an entry or pending registration in this division' using errcode = '22023';
  end if;
  select count(*) into taken from public.registrations where division_id = dv.id and status in ('requested','confirmed');
  reg_status := 'requested';
  if dv.max_entries is not null and taken >= dv.max_entries then
    if not core.setting_bool(ev.org_id,'events.waitlist_enabled',true) then raise exception 'This division is full' using errcode = '22023'; end if;
    reg_status := 'waitlisted';
  end if;
  insert into public.registrations(id,org_id,unit_id,event_id,division_id,member_id,fee_snapshot,payload_hash,
    guest_participant_id,guest_partner_participant_id,guest_rank_id,guest_partner_rank_id,guest_name_snapshot,guest_partner_name_snapshot,meta)
    values(p_id,ev.org_id,dv.unit_id,ev.id,dv.id,null,ev.fee,payload,ep.id,guest_partner,p_rank_id,p_partner_rank_id,guest_name,partner_name,
      case when member_partner is not null then jsonb_build_object('partner_member_id',member_partner) else '{}'::jsonb end);
  if reg_status = 'waitlisted' then update public.registrations set status = 'waitlisted' where id = p_id;
  else perform core.try_confirm_registration(p_id); end if;
  select * into existing from public.registrations where id = p_id;
  return jsonb_build_object('id',p_id,'status',existing.status,'fee',existing.fee_snapshot,'replayed',false);
end $$;
revoke all on function public.register_guest_for_event(text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.register_guest_for_event(text,text,text,text,text,text) to authenticated;



-- Adapt existing lifecycle functions without changing member behavior.

create or replace function core.tg_ledger_accounts_owner() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.owner_type = 'member' and not exists (
    select 1 from public.members m where m.id = new.owner_id and m.org_id = new.org_id
  ) then
    raise exception 'the account owner is not a member of this club' using errcode = '22023';
  end if;
  if new.owner_type = 'guest' and not exists(select 1 from public.persons p where p.id = new.owner_id
    and p.org_id = new.org_id and p.kind = 'guest' and p.deleted_at is null
    and not exists(select 1 from public.members m where m.person_id = p.id)) then
    raise exception 'The account owner is not a guest of this club' using errcode = '22023';
  end if;
  return new;
end $$;


create or replace function core.tg_payments_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  yr integer := extract(year from (now() at time zone 'Asia/Manila'))::integer;
begin
  if new.status <> 'submitted' then
    raise exception 'a new payment starts as submitted' using errcode = '22023';
  end if;
  if new.payer_person_id is not null then
    select display_name into new.payer_name_snapshot from public.persons where id = new.payer_person_id;
    if new.source_type <> 'event_registration' or not exists(select 1 from public.registrations r
      join public.event_participants ep on ep.id = r.guest_participant_id
      where r.id = new.source_id and r.org_id = new.org_id and ep.person_id = new.payer_person_id
      and r.member_id is null and ep.member_id is null) then
      raise exception 'Guest payments must belong to that guest registration' using errcode = '22023';
    end if;
  elsif not exists (select 1 from public.members m where m.id = new.payer_member_id and m.org_id = new.org_id and m.status = 'active' and m.deleted_at is null) then
    raise exception 'only an active member can submit a payment' using errcode = '22023';
  end if;
  if new.source_type = 'booking' and not exists (
    select 1 from public.bookings b where b.id = new.source_id and b.org_id = new.org_id
  ) then
    raise exception 'the booking being paid does not exist' using errcode = '22023';
  end if;
  if new.source_type = 'event_registration' and not exists (
    select 1 from public.registrations r where r.id = new.source_id and r.org_id = new.org_id
  ) then
    raise exception 'the registration being paid does not exist' using errcode = '22023';
  end if;
  if new.doc_no is null or new.doc_no = '' then
    new.doc_no := format('PAY-%s-%s', yr, lpad(core.next_number(new.org_id, null, 'payment-' || yr)::text, 5, '0'));
  end if;
  return new;
end $$;


create or replace function core.tg_payments_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.doc_no, old.payer_member_id, old.payer_person_id, old.payer_name_snapshot, old.source_type, old.source_id, old.method, old.reference_no, old.amount, old.file_id, old.payload_hash)
     is distinct from
     (new.doc_no, new.payer_member_id, new.payer_person_id, new.payer_name_snapshot, new.source_type, new.source_id, new.method, new.reference_no, new.amount, new.file_id, new.payload_hash) then
    raise exception 'a payment''s payer, source, method, reference, amount, proof and hash cannot change; void it and submit again' using errcode = '42501';
  end if;
  if new.status <> old.status and not (
       (old.status = 'submitted' and new.status in ('verified', 'rejected'))
    or (old.status = 'verified' and new.status = 'void')
  ) then
    raise exception 'payment status cannot change from % to %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end $$;


create or replace function core.decide_payment(p_payment_id text, p_action text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_pay public.payment_submissions;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_replay jsonb;
  v_response jsonb;
  v_target text;
begin
  if p_action not in ('verify', 'reject') then
    raise exception 'unknown action' using errcode = '22023';
  end if;
  select * into v_pay from public.payment_submissions p where p.id = p_payment_id for update;
  if not found then
    raise exception 'payment not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_pay.org_id, null, 'payments.verify') then
    raise exception 'you do not have permission to % payments', p_action using errcode = '42501';
  end if;
  if p_action = 'reject' and (v_reason is null or char_length(v_reason) < 3) then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_key, v_pay.org_id, 'payment.' || p_action, jsonb_build_object('payment_id', p_payment_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  v_target := case p_action when 'verify' then 'verified' else 'rejected' end;
  if v_pay.status = v_target then
    v_response := jsonb_build_object('ok', true, 'payment_id', v_pay.id, 'status', v_pay.status, 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;
  if v_pay.status <> 'submitted' then
    raise exception 'a payment that is % cannot be %', v_pay.status, v_target using errcode = '22023';
  end if;

  if p_action = 'verify' then
    update public.payment_submissions set status = 'verified', verified_at = now(), verified_by = coalesce(core.current_profile_id(), 'system')
    where id = v_pay.id;
    perform core.post_ledger(v_pay.org_id, coalesce(v_pay.payer_member_id, v_pay.payer_person_id), v_pay.amount, 'payment', v_pay.id, 'verify', 'Payment ' || v_pay.doc_no);
    if v_pay.source_type = 'booking' then
      perform core.try_confirm_booking(v_pay.source_id);
    end if;
  else
    update public.payment_submissions set status = 'rejected', reject_reason = v_reason where id = v_pay.id;
  end if;
  perform core.write_audit(v_pay.org_id, 'payment.' || p_action, 'public.payment_submissions', v_pay.id,
    jsonb_build_object('status', v_pay.status), jsonb_build_object('status', v_target, 'reason', v_reason, 'amount', v_pay.amount));
  v_response := jsonb_build_object('ok', true, 'payment_id', v_pay.id, 'status', v_target);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;


create or replace function core.void_payment(p_payment_id text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_pay public.payment_submissions;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_credit text;
  v_replay jsonb;
  v_response jsonb;
begin
  select * into v_pay from public.payment_submissions p where p.id = p_payment_id for update;
  if not found then
    raise exception 'payment not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_pay.org_id, null, 'payments.void') then
    raise exception 'you do not have permission to void payments' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) < 3 then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_key, v_pay.org_id, 'payment.void', jsonb_build_object('payment_id', p_payment_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  if v_pay.status = 'void' then
    v_response := jsonb_build_object('ok', true, 'payment_id', v_pay.id, 'status', 'void', 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;
  if v_pay.status <> 'verified' then
    raise exception 'only a verified payment can be voided (this one is %)', v_pay.status using errcode = '22023';
  end if;

  update public.payment_submissions set status = 'void', void_at = now(), void_by = coalesce(core.current_profile_id(), 'system'), void_reason = v_reason
  where id = v_pay.id;
  select e.id into v_credit from public.ledger_entries e
  where e.org_id = v_pay.org_id and e.source_type = 'payment' and e.source_id = v_pay.id and e.client_ref = 'verify';
  if v_credit is not null then
    perform core.post_ledger(v_pay.org_id, coalesce(v_pay.payer_member_id, v_pay.payer_person_id), -v_pay.amount, 'payment', v_pay.id, 'void', 'Voided ' || v_pay.doc_no, v_credit);
  end if;
  perform core.write_audit(v_pay.org_id, 'payment.void', 'public.payment_submissions', v_pay.id,
    jsonb_build_object('status', 'verified'), jsonb_build_object('status', 'void', 'reason', v_reason, 'amount', v_pay.amount));
  v_response := jsonb_build_object('ok', true, 'payment_id', v_pay.id, 'status', 'void');
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;


create or replace function core.tg_registrations_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions;
begin
  if new.status <> 'requested' then
    raise exception 'a new registration starts as requested' using errcode = '22023';
  end if;
  select * into dv from public.divisions where id = new.division_id;
  if not found or dv.event_id <> new.event_id or dv.org_id <> new.org_id then
    raise exception 'the division does not belong to that event' using errcode = '22023';
  end if;
  if dv.status <> 'open' then
    raise exception 'the division is not open for registration' using errcode = '22023';
  end if;
  if new.guest_participant_id is not null then
    if core.guest_registration_problem(new.guest_participant_id,new.division_id,new.guest_rank_id) is not null then
      raise exception 'Guest is not eligible for this division' using errcode = '22023';
    end if;
  elsif not exists (select 1 from public.members m where m.id = new.member_id and m.org_id = new.org_id and m.status = 'active' and m.deleted_at is null) then
    raise exception 'only an active member can register' using errcode = '22023';
  end if;
  return new;
end $$;


create or replace function core.tg_registrations_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.event_id, old.division_id, old.member_id, old.fee_snapshot, old.payload_hash, old.guest_participant_id, old.guest_partner_participant_id, old.guest_rank_id, old.guest_partner_rank_id, old.guest_name_snapshot, old.guest_partner_name_snapshot)
     is distinct from
     (new.event_id, new.division_id, new.member_id, new.fee_snapshot, new.payload_hash, new.guest_participant_id, new.guest_partner_participant_id, new.guest_rank_id, new.guest_partner_rank_id, new.guest_name_snapshot, new.guest_partner_name_snapshot) then
    raise exception 'a registration''s event, division, member, fee and hash cannot change' using errcode = '42501';
  end if;
  perform core.check_transition('registration', old.status, new.status, '{
    "requested": ["confirmed", "waitlisted", "rejected", "withdrawn"],
    "confirmed": ["withdrawn"],
    "waitlisted": ["requested", "confirmed", "withdrawn"]
  }'::jsonb);
  return new;
end $$;


create or replace function core.confirm_registration_row(p_registration_id text, p_actor text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r public.registrations;
  v_entry text;
  v_partner text;
begin
  select * into r from public.registrations where id = p_registration_id for update;
  if r.status not in ('requested', 'waitlisted') then
    return;
  end if;
  if r.guest_participant_id is not null then
    if core.guest_registration_problem(r.guest_participant_id,r.division_id,r.guest_rank_id,true) is not null then
      raise exception 'Guest eligibility changed; review this registration' using errcode = '22023';
    end if;
    if r.guest_partner_participant_id is not null and core.guest_registration_problem(r.guest_partner_participant_id,r.division_id,r.guest_partner_rank_id,true) is not null then
      raise exception 'Guest partner eligibility changed; review this registration' using errcode = '22023';
    end if;
    if r.meta->>'partner_member_id' is not null and not exists(select 1 from public.members m where m.id = r.meta->>'partner_member_id' and m.status = 'active' and m.deleted_at is null) then
      raise exception 'Member partner eligibility changed; review this registration' using errcode = '22023';
    end if;
  end if;
  update public.registrations set status = 'confirmed', status_reason = null where id = r.id;
  if r.fee_snapshot > 0 then
    perform core.post_ledger(r.org_id, core.registration_payer(r.id), -r.fee_snapshot, 'event_registration', r.id, 'charge',
      'Event registration fee');
  end if;
  insert into public.entries (org_id, division_id, registration_id) values (r.org_id, r.division_id, r.id)
  returning id into v_entry;
  if r.member_id is not null then
    insert into public.entry_members (org_id, entry_id, member_id) values (r.org_id, v_entry, r.member_id);
  else
    insert into public.entry_guests(org_id,unit_id,entry_id,participant_id,display_name_snapshot)
      values(r.org_id,r.unit_id,v_entry,r.guest_participant_id,r.guest_name_snapshot);
    if r.guest_partner_participant_id is not null then
      insert into public.entry_guests(org_id,unit_id,entry_id,participant_id,display_name_snapshot)
        values(r.org_id,r.unit_id,v_entry,r.guest_partner_participant_id,r.guest_partner_name_snapshot);
    end if;
  end if;
  v_partner := r.meta ->> 'partner_member_id';
  if v_partner is not null then
    insert into public.entry_members (org_id, entry_id, member_id) values (r.org_id, v_entry, v_partner);
  end if;
end $$;


create or replace function core.tg_entry_members_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  en public.entries;
  fmt text;
  n integer;
  lim integer := 1;
begin
  select * into en from public.entries where id = new.entry_id for update;
  if not found or en.org_id <> new.org_id then
    raise exception 'the entry does not exist' using errcode = '22023';
  end if;
  if en.status <> 'active' then
    raise exception 'members can be added only to an active entry' using errcode = '22023';
  end if;
  new.division_id := en.division_id;
  select d.format into fmt from public.divisions d where d.id = en.division_id;
  select (select count(*) from public.entry_members where entry_id = new.entry_id) + (select count(*) from public.entry_guests where entry_id = new.entry_id) into n;
  if fmt = 'doubles' then lim := 2; end if;
  if n >= lim then
    raise exception 'a % entry has at most % member(s)', fmt, lim using errcode = '22023';
  end if;
  if not exists (select 1 from public.members m where m.id = new.member_id and m.status = 'active' and m.deleted_at is null) then
    raise exception 'every entry member must be an active member' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.entry_members x join public.entries e on e.id = x.entry_id
    where x.division_id = en.division_id and x.member_id = new.member_id and e.status = 'active'
  ) then
    raise exception 'the member is already in an active entry of this division' using errcode = '23505';
  end if;
  return new;
end $$;


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
      perform core.post_ledger(r.org_id, core.registration_payer(r.id), r.fee_snapshot, 'event_registration', r.id, 'refund',
        'Event registration withdrawn', v_charge);
    end if;
  end if;
  update public.registrations set status = 'withdrawn', status_reason = p_reason where id = r.id;
end $$;


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
  v_own := coalesce(v_me.id is not null and v_me.id = r.member_id, false);
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


create or replace function core.submit_event_payment(p_id text, p_registration_id text, p_method text, p_reference_no text,
  p_amount numeric, p_proof_path text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.members;
  v_reg public.registrations;
  v_ref text := nullif(btrim(coalesce(p_reference_no, '')), '');
  v_proof text := nullif(btrim(coalesce(p_proof_path, '')), '');
  v_hash text;
  v_existing public.payment_submissions;
  v_methods jsonb;
  v_live numeric;
  v_file_id text;
  v_object record;
  v_payment public.payment_submissions;
begin
  select * into v_member from public.members m where m.profile_id = core.current_profile_id() and m.deleted_at is null;
  if not found or v_member.status <> 'active' then
    raise exception 'only an active member can submit a payment' using errcode = '42501';
  end if;
  if not core.has_permission(v_member.org_id, null, 'payments.submit') then
    raise exception 'you do not have permission to submit a payment' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then
    raise exception 'the payment needs an ID made when the form opened' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) or p_amount > 1000000 then
    raise exception 'enter an amount above zero with at most two decimals' using errcode = '22023';
  end if;
  if v_ref is not null and char_length(v_ref) > 64 then
    raise exception 'the reference number is too long' using errcode = '22023';
  end if;

  v_hash := core.hash_of(jsonb_build_object('registration', p_registration_id, 'method', p_method, 'ref', v_ref,
    'amount', p_amount, 'proof', v_proof, 'member', v_member.id));
  select * into v_existing from public.payment_submissions p where p.id = p_id;
  if found then
    if v_existing.payload_hash = v_hash and v_existing.payer_member_id = v_member.id then
      return jsonb_build_object('id', v_existing.id, 'doc_no', v_existing.doc_no, 'status', v_existing.status, 'replayed', true);
    end if;
    raise exception 'this payment ID was already used for a different request' using errcode = 'CP422';
  end if;

  select * into v_reg from public.registrations r where r.id = p_registration_id for update;
  if not found or v_reg.member_id is distinct from v_member.id then
    raise exception 'you can only pay for your own registration' using errcode = '42501';
  end if;
  if v_reg.status not in ('requested', 'confirmed', 'waitlisted') then
    raise exception 'a registration that is % cannot be paid', v_reg.status using errcode = '22023';
  end if;
  v_methods := coalesce(core.setting_value(v_member.org_id, 'payments.methods'), '["cash"]'::jsonb);
  if p_method is null or not (v_methods ? p_method) then
    raise exception 'the club does not accept that payment method' using errcode = '22023';
  end if;
  if p_method <> 'cash' and v_proof is null and core.setting_bool(v_member.org_id, 'payments.proof_required_non_cash', true) then
    raise exception 'attach the proof of payment' using errcode = '22023';
  end if;
  select coalesce(sum(p.amount), 0) into v_live from public.payment_submissions p
  where p.source_type = 'event_registration' and p.source_id = p_registration_id and p.status in ('submitted', 'verified');
  if v_live + p_amount > v_reg.fee_snapshot then
    raise exception 'that is more than the fee (%.2f still to pay)', greatest(v_reg.fee_snapshot - v_live, 0) using errcode = '22023';
  end if;

  if v_ref is not null and exists (
    select 1 from public.payment_submissions p
    where p.org_id = v_member.org_id and p.method = p_method and p.reference_no = v_ref and p.status in ('submitted', 'verified')
  ) then
    raise exception 'that reference number was already used for another payment' using errcode = '23505';
  end if;
  if v_proof is not null then
    if split_part(v_proof, '/', 1) <> v_member.org_id or split_part(v_proof, '/', 2) <> core.current_profile_id() then
      raise exception 'the proof must be uploaded to your own folder' using errcode = '42501';
    end if;
    if exists (select 1 from public.files f where f.bucket = 'payment-proofs' and f.storage_path = v_proof and f.deleted_at is null) then
      raise exception 'that proof file was already used for another payment; upload a new one' using errcode = '22023';
    end if;
    select o.name, o.metadata into v_object from storage.objects o where o.bucket_id = 'payment-proofs' and o.name = v_proof;
    if not found then
      raise exception 'the proof file was not found; upload it again' using errcode = '22023';
    end if;
    insert into public.files (org_id, owner_table, owner_id, kind, bucket, storage_path, content_type, size_bytes)
    values (v_member.org_id, 'payment_submissions', p_id, 'payment_proof', 'payment-proofs', v_proof,
      v_object.metadata ->> 'mimetype', coalesce((v_object.metadata ->> 'size')::bigint, 0))
    returning id into v_file_id;
  end if;

  begin
    insert into public.payment_submissions (id, org_id, payer_member_id, source_type, source_id, method, reference_no, amount, file_id, payload_hash)
    values (p_id, v_member.org_id, v_member.id, 'event_registration', p_registration_id, p_method, v_ref, p_amount, v_file_id, v_hash)
    returning * into v_payment;
  exception when unique_violation then
    raise exception 'that reference number was already used for another payment' using errcode = '23505';
  end;
  perform core.write_audit(v_member.org_id, 'payment.submit', 'public.payment_submissions', p_id, null,
    jsonb_build_object('registration', p_registration_id, 'method', p_method, 'amount', p_amount));
  return jsonb_build_object('id', v_payment.id, 'doc_no', v_payment.doc_no, 'status', v_payment.status);
end $$;


create or replace function public.submit_guest_event_payment(p_id text, p_registration_id text, p_method text, p_reference_no text,
  p_amount numeric, p_proof_path text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.members;
  v_reg public.registrations;
  v_ref text := nullif(btrim(coalesce(p_reference_no, '')), '');
  v_proof text := nullif(btrim(coalesce(p_proof_path, '')), '');
  v_hash text;
  v_existing public.payment_submissions;
  v_methods jsonb;
  v_live numeric;
  v_file_id text;
  v_object record;
  v_payment public.payment_submissions;
begin
  select * into v_member from public.members m where m.profile_id = core.current_profile_id() and m.deleted_at is null;
  if not found or v_member.status <> 'active' then
    raise exception 'only an active member can submit a payment' using errcode = '42501';
  end if;
  if not core.has_permission(v_member.org_id, null, 'payments.submit') or not core.has_permission(v_member.org_id, null, 'events.manage') then
    raise exception 'you do not have permission to submit a payment' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then
    raise exception 'the payment needs an ID made when the form opened' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) or p_amount > 1000000 then
    raise exception 'enter an amount above zero with at most two decimals' using errcode = '22023';
  end if;
  if v_ref is not null and char_length(v_ref) > 64 then
    raise exception 'the reference number is too long' using errcode = '22023';
  end if;

  v_hash := core.hash_of(jsonb_build_object('registration', p_registration_id, 'method', p_method, 'ref', v_ref,
    'amount', p_amount, 'proof', v_proof, 'member', v_member.id));
  select * into v_existing from public.payment_submissions p where p.id = p_id;
  if found then
    if v_existing.payload_hash = v_hash then
      return jsonb_build_object('id', v_existing.id, 'doc_no', v_existing.doc_no, 'status', v_existing.status, 'replayed', true);
    end if;
    raise exception 'this payment ID was already used for a different request' using errcode = 'CP422';
  end if;

  select * into v_reg from public.registrations r where r.id = p_registration_id for update;
  if not found or v_reg.org_id <> v_member.org_id or v_reg.guest_participant_id is null then
    raise exception 'Choose a guest registration in this club' using errcode = '42501';
  end if;
  if v_reg.status not in ('requested', 'confirmed', 'waitlisted') then
    raise exception 'a registration that is % cannot be paid', v_reg.status using errcode = '22023';
  end if;
  v_methods := coalesce(core.setting_value(v_member.org_id, 'payments.methods'), '["cash"]'::jsonb);
  if p_method is null or not (v_methods ? p_method) then
    raise exception 'the club does not accept that payment method' using errcode = '22023';
  end if;
  if p_method <> 'cash' and v_proof is null and core.setting_bool(v_member.org_id, 'payments.proof_required_non_cash', true) then
    raise exception 'attach the proof of payment' using errcode = '22023';
  end if;
  select coalesce(sum(p.amount), 0) into v_live from public.payment_submissions p
  where p.source_type = 'event_registration' and p.source_id = p_registration_id and p.status in ('submitted', 'verified');
  if v_live + p_amount > v_reg.fee_snapshot then
    raise exception 'that is more than the fee (%.2f still to pay)', greatest(v_reg.fee_snapshot - v_live, 0) using errcode = '22023';
  end if;

  if v_ref is not null and exists (
    select 1 from public.payment_submissions p
    where p.org_id = v_member.org_id and p.method = p_method and p.reference_no = v_ref and p.status in ('submitted', 'verified')
  ) then
    raise exception 'that reference number was already used for another payment' using errcode = '23505';
  end if;
  if v_proof is not null then
    if split_part(v_proof, '/', 1) <> v_member.org_id or split_part(v_proof, '/', 2) <> core.current_profile_id() then
      raise exception 'the proof must be uploaded to your own folder' using errcode = '42501';
    end if;
    if exists (select 1 from public.files f where f.bucket = 'payment-proofs' and f.storage_path = v_proof and f.deleted_at is null) then
      raise exception 'that proof file was already used for another payment; upload a new one' using errcode = '22023';
    end if;
    select o.name, o.metadata into v_object from storage.objects o where o.bucket_id = 'payment-proofs' and o.name = v_proof;
    if not found then
      raise exception 'the proof file was not found; upload it again' using errcode = '22023';
    end if;
    insert into public.files (org_id, owner_table, owner_id, kind, bucket, storage_path, content_type, size_bytes)
    values (v_member.org_id, 'payment_submissions', p_id, 'payment_proof', 'payment-proofs', v_proof,
      v_object.metadata ->> 'mimetype', coalesce((v_object.metadata ->> 'size')::bigint, 0))
    returning id into v_file_id;
  end if;

  begin
    insert into public.payment_submissions (id, org_id, payer_person_id, source_type, source_id, method, reference_no, amount, file_id, payload_hash)
    values (p_id, v_member.org_id, core.registration_payer(v_reg.id), 'event_registration', p_registration_id, p_method, v_ref, p_amount, v_file_id, v_hash)
    returning * into v_payment;
  exception when unique_violation then
    raise exception 'that reference number was already used for another payment' using errcode = '23505';
  end;
  perform core.write_audit(v_member.org_id, 'payment.submit', 'public.payment_submissions', p_id, null,
    jsonb_build_object('registration', p_registration_id, 'method', p_method, 'amount', p_amount));
  return jsonb_build_object('id', v_payment.id, 'doc_no', v_payment.doc_no, 'status', v_payment.status);
end $$;


create or replace function core.stage_standings(p_stage_id text)
returns table (group_label text, entry_id text, entry_name text, played integer, wins integer, losses integer,
  games_won integer, games_lost integer, points_for integer, points_against integer, place integer, tied boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  st public.division_stages;
  v_criteria text[];
  v_order text[];
  v_group text;
  v_entries text[];
  v_split jsonb;
  v_tier jsonb;
  v_pos integer;
begin
  select * into st from public.division_stages where id = p_stage_id;
  if not found then
    return;
  end if;
  -- Wins always come first; the rest follow the stage's own order.
  select coalesce(array_agg(x order by ord), '{}') into v_order
  from jsonb_array_elements_text(coalesce(st.scoring_rule_snapshot -> 'tiebreak_order', '["match_wins","head_to_head","point_diff"]'::jsonb))
    with ordinality as t(x, ord)
  where x <> 'match_wins';
  v_criteria := array['match_wins'] || v_order;

  for v_group in
    select distinct m.group_label from public.matches m
    where m.division_stage_id = p_stage_id and m.status <> 'void' and m.group_label is not null
    union
    select null::text where not exists (
      select 1 from public.matches m where m.division_stage_id = p_stage_id and m.status <> 'void' and m.group_label is not null)
    order by 1
  loop
    select coalesce(array_agg(distinct x), '{}') into v_entries from (
      select m.entry_a_id x from public.matches m
      where m.division_stage_id = p_stage_id and m.status <> 'void' and m.group_label is not distinct from v_group
      union
      select m.entry_b_id from public.matches m
      where m.division_stage_id = p_stage_id and m.status <> 'void' and m.group_label is not distinct from v_group) q
    where x is not null;
    if cardinality(v_entries) = 0 then
      continue;
    end if;
    v_split := core.tb_split(p_stage_id, v_group, v_entries, v_criteria);
    v_pos := 1;
    for v_tier in select * from jsonb_array_elements(v_split) loop
      return query
      select v_group, t.eid,
        core.entry_name(t.eid),
        coalesce(s.played, 0), coalesce(s.wins, 0), coalesce(s.played, 0) - coalesce(s.wins, 0),
        coalesce(s.gw, 0), coalesce(s.gl, 0), coalesce(s.pf, 0), coalesce(s.pa, 0),
        v_pos, jsonb_array_length(v_tier) > 1
      from jsonb_array_elements_text(v_tier) as t(eid)
      left join lateral (
        select count(*)::integer played, sum(sr.win::integer)::integer wins, sum(sr.gw)::integer gw, sum(sr.gl)::integer gl,
          sum(sr.pf)::integer pf, sum(sr.pa)::integer pa
        from core.stage_rows(p_stage_id, v_group) sr where sr.e = t.eid) s on true;
      v_pos := v_pos + jsonb_array_length(v_tier);
    end loop;
  end loop;
end $$;


create or replace function core.draw_snapshot(p_ids text[]) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('entry_id', i,
    'guest_participant_ids', (select coalesce(jsonb_agg(g.participant_id order by g.participant_id),'[]'::jsonb) from public.entry_guests g where g.entry_id = i),
    'member_ids', (select coalesce(jsonb_agg(em.member_id order by em.member_id), '[]'::jsonb) from public.entry_members em where em.entry_id = i))
    order by i), '[]'::jsonb)
  from unnest(p_ids) i
$$;


revoke all on function public.submit_guest_event_payment(text,text,text,text,numeric,text) from public, anon, authenticated;
grant execute on function public.submit_guest_event_payment(text,text,text,text,numeric,text) to authenticated;

create function core.tg_entry_guests_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare en public.entries; ep public.event_participants; reg public.registrations; slots integer; taken integer;
begin
  select * into en from public.entries where id = new.entry_id for update;
  select * into ep from public.event_participants where id = new.participant_id;
  select * into reg from public.registrations where id = en.registration_id;
  if en.id is null or en.status <> 'active' or en.org_id <> new.org_id or ep.id is null
    or ep.org_id <> en.org_id or ep.event_id <> reg.event_id or ep.member_id is not null
    or reg.status <> 'confirmed' or new.participant_id not in (coalesce(reg.guest_participant_id,''),coalesce(reg.guest_partner_participant_id,'')) then
    raise exception 'Guest roster must match the confirmed registration' using errcode = '22023';
  end if;
  select case when format = 'doubles' then 2 else 1 end into slots from public.divisions where id = en.division_id;
  select (select count(*) from public.entry_members where entry_id = en.id) +
    (select count(*) from public.entry_guests where entry_id = en.id) into taken;
  if taken >= slots then raise exception 'This entry already has its full roster' using errcode = '22023'; end if;
  if exists(select 1 from public.entry_guests g join public.entries e on e.id = g.entry_id
    where g.participant_id = ep.id and e.division_id = en.division_id and e.status = 'active') then
    raise exception 'Guest already has an active entry in this division' using errcode = '23505';
  end if;
  new.unit_id := en.unit_id;
  new.display_name_snapshot := case when ep.id = reg.guest_participant_id then reg.guest_name_snapshot else reg.guest_partner_name_snapshot end;
  return new;
end $$;
revoke all on function core.tg_entry_guests_insert() from public, anon, authenticated;
create trigger a2_entry_guests_insert before insert on public.entry_guests
  for each row execute function core.tg_entry_guests_insert();

create or replace function core.entry_name(p_entry_id text) returns text
language sql stable security definer set search_path = '' as $$
  select string_agg(display_name, ' & ' order by display_name) from (
    select pe.display_name from public.entry_members em join public.members m on m.id = em.member_id
      join public.persons pe on pe.id = m.person_id where em.entry_id = p_entry_id
    union all
    select display_name_snapshot from public.entry_guests where entry_id = p_entry_id
  ) players
$$;
revoke all on function core.entry_name(text) from public, anon, authenticated;
grant execute on function core.entry_name(text) to service_role;

create function public.event_participant_choices(p_event_id text)
returns table(id text, person_id text, display_name text, member_id text, member_no text)
language plpgsql stable security definer set search_path = '' as $$
declare ev public.events;
begin
  select * into ev from public.events where public.events.id = p_event_id;
  if not found or not core.has_permission(ev.org_id,ev.unit_id,'events.manage') then
    raise exception 'You do not have permission to view event participants' using errcode = '42501';
  end if;
  return query select ep.id, ep.person_id, p.display_name, ep.member_id, m.member_no
    from public.event_participants ep join public.persons p on p.id = ep.person_id
    left join public.members m on m.id = ep.member_id
    where ep.event_id = ev.id and ep.deleted_at is null and p.deleted_at is null
    and (ep.member_id is null or (m.status = 'active' and m.deleted_at is null)) order by p.display_name,ep.id;
end $$;
revoke all on function public.event_participant_choices(text) from public, anon, authenticated;
grant execute on function public.event_participant_choices(text) to authenticated;

create function public.search_event_players(p_event_id text, p_term text)
returns table(person_id text, display_name text, member_id text, member_no text)
language plpgsql stable security definer set search_path = '' as $$
declare ev public.events; term text := lower(btrim(coalesce(p_term,'')));
begin
  select * into ev from public.events where id = p_event_id;
  if not found or not core.has_permission(ev.org_id,ev.unit_id,'events.manage') then
    raise exception 'You do not have permission to find event players' using errcode = '42501';
  end if;
  if char_length(term) < 2 or char_length(term) > 100 then return; end if;
  return query select p.id, p.display_name, m.id, m.member_no from public.persons p
    left join public.members m on m.person_id = p.id and m.org_id = ev.org_id
    where p.org_id = ev.org_id and p.deleted_at is null
      and ((m.status = 'active' and m.deleted_at is null) or (m.id is null and p.kind = 'guest'))
      and position(term in lower(p.display_name || ' ' || coalesce(m.member_no,''))) > 0
    order by p.display_name,p.id limit 50;
end $$;
revoke all on function public.search_event_players(text,text) from public, anon, authenticated;
grant execute on function public.search_event_players(text,text) to authenticated;

-- IDs are scoped by table. Resolve guest accounts from the source document,
-- never by guessing whether a person ID happens to equal some member's ID.
create function core.guest_ledger_account_for(p_org text, p_person text) returns text
language plpgsql security definer set search_path = '' as $$
declare result text;
begin
  if not exists(select 1 from public.persons p where p.id = p_person and p.org_id = p_org
    and p.kind = 'guest' and p.deleted_at is null and not exists(select 1 from public.members m where m.person_id = p.id)) then
    raise exception 'Choose a guest in this club' using errcode = '22023';
  end if;
  insert into public.ledger_accounts(org_id,owner_type,owner_id) values(p_org,'guest',p_person)
    on conflict(org_id,owner_type,owner_id,currency) where deleted_at is null do nothing;
  select id into result from public.ledger_accounts where org_id = p_org and owner_type = 'guest' and owner_id = p_person and deleted_at is null;
  return result;
end $$;
revoke all on function core.guest_ledger_account_for(text,text) from public, anon, authenticated;

create or replace function core.post_ledger(p_org text, p_member text, p_amount numeric, p_source_type text, p_source_id text,
  p_client_ref text, p_note text, p_reverses text default null) returns text
language plpgsql security definer set search_path = '' as $$
declare account text; result text; guest_person text;
begin
  if p_source_type = 'event_registration' then
    select ep.person_id into guest_person from public.registrations r
      join public.event_participants ep on ep.id = r.guest_participant_id where r.id = p_source_id and r.org_id = p_org;
  elsif p_source_type = 'payment' then
    select payer_person_id into guest_person from public.payment_submissions where id = p_source_id and org_id = p_org;
  end if;
  if guest_person is not null then
    if guest_person is distinct from p_member then raise exception 'Guest ledger payer does not match the source document' using errcode = '22023'; end if;
    account := core.guest_ledger_account_for(p_org,guest_person);
  else account := core.ledger_account_for(p_org,p_member); end if;
  select id into result from public.ledger_entries where org_id = p_org and source_type = p_source_type and source_id = p_source_id and client_ref = p_client_ref;
  if result is not null then return result; end if;
  insert into public.ledger_entries(org_id,account_id,amount,source_type,source_id,client_ref,note,reverses_entry_id)
    values(p_org,account,p_amount,p_source_type,p_source_id,p_client_ref,p_note,p_reverses) returning id into result;
  return result;
end $$;
