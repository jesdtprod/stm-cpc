-- PLAN 6.2c: admin-only guest setup, late registration and pre-draw roster changes.
-- Permission checks use a dedicated code, granted to the admin bundle only.
select core.add_permission('events.admin_roster', 'Administer guest players and pre-draw roster changes', array['admin']);

create table public.event_roster_changes (
  id text collate "C" primary key default core.ulid(),
  org_id text collate "C" not null references public.orgs(id) on delete restrict,
  unit_id text collate "C" references public.org_units(id) on delete restrict,
  event_id text collate "C" not null references public.events(id) on delete restrict,
  source_registration_id text collate "C" not null references public.registrations(id) on delete restrict,
  target_registration_id text collate "C" not null references public.registrations(id) on delete restrict deferrable initially deferred,
  kind text not null check(kind in ('move','replace')),
  reason text not null check(char_length(btrim(reason)) between 3 and 500),
  carry_payment boolean not null,
  previous_fee numeric(12,2) not null check(previous_fee >= 0),
  new_fee numeric(12,2) not null check(new_fee >= 0),
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  version integer not null default 1, meta jsonb not null default '{}'::jsonb,
  constraint event_roster_changes_source_uq unique(source_registration_id),
  constraint event_roster_changes_target_uq unique(target_registration_id),
  constraint event_roster_changes_distinct_chk check(source_registration_id <> target_registration_id)
);
comment on table public.event_roster_changes is 'class: ledger/log. Append-only admin roster history. A transfer preserves withdrawn registrations and receipts. Same-payer payment credit follows this chain; a replacement payer never inherits another person funds. Deferred target FK permits atomic same-division place reservation.';
create index event_roster_changes_org_idx on public.event_roster_changes(org_id);
create index event_roster_changes_unit_idx on public.event_roster_changes(unit_id);
create index event_roster_changes_event_idx on public.event_roster_changes(event_id);
select core.attach_standard('public.event_roster_changes','ledger');
select core.enable_standard_rls('public.event_roster_changes','org','events');
drop policy event_roster_changes_select on public.event_roster_changes;
drop policy event_roster_changes_insert on public.event_roster_changes;
drop policy event_roster_changes_update on public.event_roster_changes;
create policy event_roster_changes_select on public.event_roster_changes for select to authenticated
  using(core.has_permission(org_id,unit_id,'events.admin_roster'));
revoke all on public.event_roster_changes from public,anon,authenticated;
grant select on public.event_roster_changes to authenticated;

create or replace function core.registration_paid(p_registration text) returns numeric
language sql stable security definer set search_path = '' as $$
  with recursive sources(id) as (
    select p_registration collate "C"
    union
    select c.source_registration_id from public.event_roster_changes c join sources s on s.id = c.target_registration_id
      where c.carry_payment
  ) select coalesce(sum(p.amount),0) from public.payment_submissions p
    where p.source_type = 'event_registration' and p.source_id in(select id from sources) and p.status = 'verified'
$$;

create or replace function core.tg_registrations_freed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('requested','confirmed') and new.status in ('rejected','withdrawn') then
    -- A replacement retains this place; moving to another division frees it.
    if not exists(select 1 from public.event_roster_changes c where c.source_registration_id = new.id and c.kind = 'replace') then
      perform core.promote_waitlist(new.division_id);
    end if;
  end if;
  return null;
end $$;

create function public.change_guest_registration(
  p_id text, p_registration_id text, p_division_id text, p_kind text, p_rank_id text,
  p_partner_participant_id text default null, p_partner_rank_id text default null,
  p_replacement_participant_id text default null, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare src public.registrations; target public.divisions; origin public.divisions; ev public.events;
  lead public.event_participants; partner public.event_participants; dst public.registrations;
  replay jsonb; result jsonb; taken integer; reason text := nullif(btrim(coalesce(p_reason,'')),'');
  same_payer boolean; previous_partner text;
begin
  select * into src from public.registrations where id = p_registration_id for update;
  if not found or not core.has_permission(src.org_id,src.unit_id,'events.admin_roster') then
    raise exception 'Only an administrator can change guest registrations' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('move','replace') or reason is null or char_length(reason) not between 3 and 500 then
    raise exception 'Choose Move or Replace and give a reason (3 to 500 characters)' using errcode = '22023';
  end if;
  replay := core.idem_begin(p_id,src.org_id,'guest_roster.change',jsonb_build_object('registration',src.id,
    'division',p_division_id,'kind',p_kind,'rank',p_rank_id,'partner',p_partner_participant_id,
    'partner_rank',p_partner_rank_id,'replacement',p_replacement_participant_id,'reason',reason));
  if replay is not null then return replay; end if;
  if exists(select 1 from public.registrations where id = p_id) then
    raise exception 'This roster change needs a new registration ID' using errcode = 'CP422';
  end if;
  if src.guest_participant_id is null or src.status not in ('requested','confirmed') then
    raise exception 'Choose an active guest registration that is not waitlisted' using errcode = '22023';
  end if;
  if exists(select 1 from public.payment_submissions p where p.source_type='event_registration' and p.source_id=src.id and p.status='submitted') then
    raise exception 'Verify or reject pending receipts before changing this registration' using errcode = '22023';
  end if;
  perform 1 from public.divisions where id in(src.division_id,p_division_id) order by id for update;
  select * into origin from public.divisions where id = src.division_id;
  select * into target from public.divisions where id = p_division_id;
  select * into ev from public.events where id = src.event_id for update;
  if target.id is null or target.event_id <> src.event_id or target.org_id <> src.org_id then
    raise exception 'Choose a division in this event' using errcode = '22023';
  end if;
  if ev.status not in ('registration_open','registration_closed') or origin.status <> 'open' or target.status <> 'open'
    or exists(select 1 from public.division_stages s join public.draws d on d.division_stage_id = s.id
      where s.division_id in(origin.id,target.id) and d.status = 'active') then
    raise exception 'Roster changes require undrawn divisions before play; existing draws and matches must be preserved' using errcode = '22023';
  end if;
  if p_kind = 'move' and (origin.id = target.id or p_replacement_participant_id is not null) then
    raise exception 'A move keeps the guest and needs a different division' using errcode = '22023';
  end if;
  if p_kind = 'replace' and origin.id <> target.id then
    raise exception 'Replace players in the same division; use Move for another division' using errcode = '22023';
  end if;
  select * into lead from public.event_participants where id = coalesce(p_replacement_participant_id,src.guest_participant_id)
    and event_id = ev.id and org_id = ev.org_id and member_id is null and deleted_at is null;
  if not found then raise exception 'Choose a guest participant in this event' using errcode = '22023'; end if;
  select * into partner from public.event_participants where id = p_partner_participant_id and event_id = ev.id and deleted_at is null;
  select id into previous_partner from public.event_participants where event_id = ev.id and member_id = src.meta->>'partner_member_id' and deleted_at is null;
  previous_partner := coalesce(src.guest_partner_participant_id,previous_partner);
  if p_kind = 'replace' and lead.id = src.guest_participant_id and p_partner_participant_id is not distinct from previous_partner then
    raise exception 'Choose at least one different player' using errcode = '22023';
  end if;
  select count(*) into taken from public.registrations r where r.division_id = target.id and r.status in ('requested','confirmed') and r.id <> src.id;
  if target.max_entries is not null and taken >= target.max_entries then
    raise exception 'The destination division is full; this change cannot remove the current entry' using errcode = '22023';
  end if;
  same_payer := lead.person_id = core.registration_payer(src.id);
  insert into public.event_roster_changes(id,org_id,unit_id,event_id,source_registration_id,target_registration_id,kind,reason,carry_payment,previous_fee,new_fee)
    values(p_id,src.org_id,src.unit_id,ev.id,src.id,p_id,p_kind,reason,same_payer,src.fee_snapshot,ev.fee);
  perform core.release_registration(src.id,'Admin '||p_kind||': '||reason);
  perform public.register_guest_for_event(p_id,target.id,lead.id,p_rank_id,p_partner_participant_id,p_partner_rank_id);
  select * into dst from public.registrations where id = p_id;
  if src.status = 'confirmed' and dst.status = 'requested' and not core.registration_payment_pending(dst.id) then
    perform core.confirm_registration_row(dst.id,core.current_profile_id());
  end if;
  select * into dst from public.registrations where id = p_id;
  result := jsonb_build_object('id',p_id,'source_id',src.id,'status',dst.status,'previous_fee',src.fee_snapshot,
    'fee',dst.fee_snapshot,'fee_difference',dst.fee_snapshot-src.fee_snapshot,'payment_carried',same_payer);
  perform core.idem_complete(p_id,result);
  return result;
end $$;
revoke all on function public.change_guest_registration(text,text,text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.change_guest_registration(text,text,text,text,text,text,text,text,text) to authenticated;

create function public.guest_registration_payment_summary(p_registration_ids text[]) returns table(id text,verified_total numeric,pending_total numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists(select 1 from core.my_profile() p where core.has_permission(p.org_id,null,'events.admin_roster')) then
    raise exception 'Only an administrator can review guest registration credit' using errcode = '42501';
  end if;
  return query select r.id,core.registration_paid(r.id),coalesce((select sum(p.amount) from public.payment_submissions p
      where p.source_type='event_registration' and p.source_id=r.id and p.status='submitted'),0)
    from public.registrations r where r.id=any(p_registration_ids) and r.guest_participant_id is not null
      and core.has_permission(r.org_id,r.unit_id,'events.admin_roster');
end $$;
revoke all on function public.guest_registration_payment_summary(text[]) from public,anon,authenticated;
grant execute on function public.guest_registration_payment_summary(text[]) to authenticated;


-- Existing RPCs receive the same admin and late-registration rules.

create or replace function public.create_event_participant(
  p_id text, p_event_id text, p_member_id text default null,
  p_guest_person_id text default null, p_guest_name text default null,
  p_guest_mobile text default null, p_guest_gender text default null,
  p_guest_birth_date date default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_org text;
  v_event public.events;
  v_existing public.event_participants;
  v_person public.persons;
  v_person_id text;
  v_name text := nullif(btrim(coalesce(p_guest_name, '')), '');
  v_mobile text := nullif(btrim(coalesce(p_guest_mobile, '')), '');
  v_hash text;
begin
  select org_id into v_org from core.my_profile();
  select * into v_event from public.events where id = p_event_id and org_id = v_org for update;
  if not found or not core.has_permission(v_org, v_event.unit_id, 'events.admin_roster') then
    raise exception 'You do not have permission to manage these event participants' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then
    raise exception 'A participant ID is required' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('event-participant:' || p_id, 0));
  if (p_member_id is null) = (p_guest_person_id is null) then
    raise exception 'Choose either a member or a guest' using errcode = '22023';
  end if;
  if p_member_id is not null and (v_name is not null or v_mobile is not null
    or p_guest_gender is not null or p_guest_birth_date is not null) then
    raise exception 'Member details come from the member profile' using errcode = '22023';
  end if;
  v_hash := core.hash_of(jsonb_build_object('event', p_event_id, 'member', p_member_id,
    'guest', p_guest_person_id, 'name', v_name, 'mobile', v_mobile,
    'gender', p_guest_gender, 'birth_date', p_guest_birth_date));
  select * into v_existing from public.event_participants where id = p_id;
  if found then
    if v_existing.org_id <> v_org or v_existing.payload_hash <> v_hash then
      raise exception 'This participant ID was used for a different request' using errcode = 'CP422';
    end if;
    if v_existing.deleted_at is not null then
      raise exception 'This participant has been removed' using errcode = '22023';
    end if;
    return jsonb_build_object('id', p_id, 'person_id', v_existing.person_id,
      'member_id', v_existing.member_id, 'replayed', true);
  end if;
  if v_event.status not in ('draft', 'registration_open', 'registration_closed') then
    raise exception 'Participant setup is closed after the draw' using errcode = '22023';
  end if;
  if p_member_id is not null then
    select m.person_id into v_person_id from public.members m
      join public.persons p on p.id = m.person_id
      where m.id = p_member_id and m.org_id = v_org and m.status = 'active'
      and m.deleted_at is null and p.deleted_at is null;
    if not found then
      raise exception 'Choose an active club member' using errcode = '22023';
    end if;
  else
    if not core.is_ulid(p_guest_person_id) or char_length(v_name) > 120
      or char_length(v_mobile) > 40 or p_guest_gender not in ('male', 'female')
      or p_guest_birth_date > (now() at time zone 'Asia/Manila')::date then
      raise exception 'Guest details are invalid' using errcode = '22023';
    end if;
    if v_name is not null then
      insert into public.persons(id, org_id, kind, display_name, mobile, gender, date_of_birth)
        values (p_guest_person_id, v_org, 'guest', v_name, v_mobile, p_guest_gender, p_guest_birth_date)
        on conflict (id) do nothing;
    end if;
    select * into v_person from public.persons where id = p_guest_person_id for update;
    if not found or v_person.org_id <> v_org or v_person.kind <> 'guest'
      or v_person.deleted_at is not null then
      raise exception 'Choose an existing guest or provide a name for a new guest' using errcode = '22023';
    end if;
    if (v_name is not null and (v_person.display_name, v_person.mobile, v_person.gender, v_person.date_of_birth)
      is distinct from (v_name, v_mobile, p_guest_gender, p_guest_birth_date))
      or (v_name is null and (v_mobile is not null or p_guest_gender is not null or p_guest_birth_date is not null)) then
      raise exception 'Guest details cannot be changed while adding a participant' using errcode = 'CP422';
    end if;
    v_person_id := v_person.id;
  end if;
  if exists (select 1 from public.event_participants where event_id = p_event_id
    and person_id = v_person_id and deleted_at is null) then
    raise exception 'This person is already an event participant; reuse their participant record' using errcode = '22023';
  end if;
  insert into public.event_participants(id, org_id, unit_id, event_id, person_id, member_id, payload_hash)
    values (p_id, v_org, v_event.unit_id, p_event_id, v_person_id, p_member_id, v_hash);
  return jsonb_build_object('id', p_id, 'person_id', v_person_id, 'member_id', p_member_id, 'replayed', false);
end $$;


create or replace function public.create_guest_event_participant(
  p_id text, p_event_id text, p_guest_person_id text, p_guest_name text,
  p_guest_mobile text default null, p_guest_gender text default null,
  p_guest_birth_date date default null, p_dupr_id text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare ev public.events; guest public.persons; result jsonb; replay jsonb;
  dupr text := nullif(upper(btrim(coalesce(p_dupr_id,''))), '');
  guest_name text := nullif(btrim(coalesce(p_guest_name,'')), '');
  mobile text := nullif(btrim(coalesce(p_guest_mobile,'')), '');
begin
  select * into ev from public.events where id = p_event_id for update;
  if not found or not core.has_permission(ev.org_id,ev.unit_id,'events.admin_roster') then
    raise exception 'You do not have permission to manage these event participants' using errcode = '42501';
  end if;
  if dupr is not null and dupr !~ '^[A-Z0-9]{1,32}$' then
    raise exception 'DUPR ID must contain 1 to 32 letters or numbers' using errcode = '22023';
  end if;
  if p_guest_person_id is null or not core.is_ulid(p_guest_person_id) or guest_name is null
    or char_length(guest_name) > 120 then
    raise exception 'A guest ID and name are required (up to 120 characters)' using errcode = '22023';
  end if;
  replay := core.idem_begin(p_id,ev.org_id,'guest_participant.create',jsonb_build_object(
    'event',p_event_id,'person',p_guest_person_id,'name',guest_name,'mobile',mobile,
    'gender',p_guest_gender,'birth_date',p_guest_birth_date,'dupr_id',dupr));
  if replay is not null then return replay; end if;
  -- Seed the real guest identity first, so the participant trigger snapshots its ID.
  -- Any validation failure from the existing participant RPC rolls this insert back.
  begin
    insert into public.persons(id,org_id,kind,display_name,mobile,gender,date_of_birth,dupr_id)
      values(p_guest_person_id,ev.org_id,'guest',guest_name,mobile,p_guest_gender,p_guest_birth_date,dupr)
      on conflict(id) do nothing;
  exception when unique_violation then
    raise exception 'That DUPR ID is already recorded for another person in this club' using errcode = '23505';
  end;
  select * into guest from public.persons where id = p_guest_person_id for update;
  if guest.org_id <> ev.org_id or guest.kind <> 'guest' or guest.deleted_at is not null then
    raise exception 'Choose a guest identity in this club' using errcode = '22023';
  end if;
  if guest.dupr_id is distinct from dupr then
    raise exception 'Adding a participant cannot replace an existing person DUPR ID' using errcode = 'CP422';
  end if;
  result := public.create_event_participant(p_id,ev.id,null,p_guest_person_id,guest_name,mobile,p_guest_gender,p_guest_birth_date);
  result := result || jsonb_build_object('dupr_id',dupr);
  perform core.idem_complete(p_id,result);
  return result;
end $$;


create or replace function public.set_event_guest_policy(p_event_id text, p_allow boolean, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare ev public.events; replay jsonb; result jsonb;
begin
  select * into ev from public.events where id = p_event_id for update;
  if not found or not core.has_permission(ev.org_id, ev.unit_id, 'events.admin_roster') then
    raise exception 'You do not have permission to manage this event' using errcode = '42501';
  end if;
  if p_allow is null then raise exception 'Choose whether to allow guests' using errcode = '22023'; end if;
  replay := core.idem_begin(p_key, ev.org_id, 'event.guest_policy', jsonb_build_object('event',p_event_id,'allow',p_allow));
  if replay is not null then return replay; end if;
  if ev.status not in ('draft','registration_open','registration_closed') then
    raise exception 'Guest policy cannot change once the event draw or play has begun' using errcode = '22023';
  end if;
  if not p_allow and exists(select 1 from public.registrations r where r.event_id=ev.id and r.guest_participant_id is not null and r.status in ('requested','confirmed','waitlisted')) then
    raise exception 'Guests already have active registrations; keep guest registration enabled' using errcode = '22023';
  end if;
  update public.events set allow_guest_players = p_allow where id = ev.id and allow_guest_players is distinct from p_allow;
  result := jsonb_build_object('id', ev.id, 'allow_guest_players', p_allow);
  perform core.idem_complete(p_key, result);
  return result;
end $$;


create or replace function core.tg_event_guest_policy() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.allow_guest_players is distinct from old.allow_guest_players and (old.status not in ('draft','registration_open','registration_closed') or not core.has_permission(old.org_id,old.unit_id,'events.admin_roster')) then
    raise exception 'Only an administrator can change guest policy before the draw' using errcode = '22023';
  end if;
  return new;
end $$;


create or replace function core.guest_registration_problem(p_participant text, p_division text, p_rank text, p_confirm boolean default false) returns text
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
  if dv.status <> 'open' or (ev.status <> 'registration_open' and not ((p_confirm or core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster')) and ev.status = 'registration_closed')) then return 'Registration is not open.'; end if;
  if not p_confirm and not core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster') and ((ev.registration_opens_at is not null and now() < ev.registration_opens_at)
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


create or replace function core.registration_problem(p_member_id text, p_division_id text, p_soft boolean default true)
returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  m public.members;
  per public.persons;
  dv public.divisions;
  ev public.events;
  v_rank record;
  v_lo integer;
  v_hi integer;
  v_age integer;
  v_group text;
  v_a integer;
  v_b integer;
begin
  select * into m from public.members x where x.id = p_member_id and x.deleted_at is null;
  if not found or m.status <> 'active' then
    return 'Only an active member can register.';
  end if;
  select * into dv from public.divisions x where x.id = p_division_id;
  if not found or dv.org_id <> m.org_id then
    return 'That division does not exist.';
  end if;
  select * into ev from public.events x where x.id = dv.event_id;
  if ev.status <> 'registration_open' and not (ev.status = 'registration_closed' and core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster')) then
    return 'Registration for this event is not open.';
  end if;
  if not core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster') and ((ev.registration_opens_at is not null and now() < ev.registration_opens_at)
     or (ev.registration_closes_at is not null and now() >= ev.registration_closes_at)) then
    return 'Registration for this event is outside its registration window.';
  end if;
  if dv.status <> 'open' then
    return 'This division is not open for registration.';
  end if;
  if not p_soft then
    return null;
  end if;

  select r.id, r.sort_order, l.category_id into v_rank
  from public.member_ranks mr
  join public.ranks r on r.id = mr.rank_id
  join public.rank_ladders l on l.id = r.ladder_id
  where mr.member_id = m.id and mr.deleted_at is null;
  if not found then
    return 'You have no rank yet, so you cannot join a ranked division.';
  end if;
  if v_rank.category_id <> dv.category_id then
    return 'This division is for a different category than your current rank.';
  end if;
  if dv.min_rank_id is not null then
    select sort_order into v_lo from public.ranks where id = dv.min_rank_id;
    if v_rank.sort_order < v_lo then return 'Your rank is below this division''s lowest allowed rank.'; end if;
  end if;
  if dv.max_rank_id is not null then
    select sort_order into v_hi from public.ranks where id = dv.max_rank_id;
    if v_rank.sort_order > v_hi then return 'Your rank is above this division''s highest allowed rank.'; end if;
  end if;

  select * into per from public.persons p where p.id = m.person_id;
  if dv.gender in ('male', 'female') then
    if per.gender is null then
      return 'Add your gender to your profile to join this division.';
    elsif per.gender <> dv.gender then
      return case dv.gender when 'male' then 'This division is for men.' else 'This division is for women.' end;
    end if;
  end if;

  v_group := btrim(coalesce(dv.age_group, ''));
  if v_group ~ '^\d{1,2}\+$' or v_group ~ '^\d{1,2}\s*-\s*\d{1,2}$' then
    if per.date_of_birth is null then
      return 'Your birth date is needed to check this division''s age group.';
    end if;
    v_age := extract(year from age(ev.starts_on, per.date_of_birth))::integer;
    if v_group ~ '\+$' then
      v_a := substring(v_group from '^\d+')::integer;
      if v_age < v_a then return format('This division is for ages %s and over.', v_a); end if;
    else
      v_a := substring(v_group from '^\d+')::integer;
      v_b := substring(v_group from '(\d+)$')::integer;
      if v_age < v_a or v_age > v_b then return format('This division is for ages %s to %s.', v_a, v_b); end if;
    end if;
  end if;
  return null;
end $$;


create or replace function public.register_guest_for_event(p_id text, p_division_id text, p_participant_id text,
  p_rank_id text, p_partner_participant_id text default null, p_partner_rank_id text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare dv public.divisions; ev public.events; ep public.event_participants; partner public.event_participants;
  existing public.registrations; problem text; payload text; taken integer; reg_status text;
  guest_partner text; member_partner text; guest_name text; partner_name text;
begin
  select * into dv from public.divisions where id = p_division_id for update;
  if not found or not core.has_permission(dv.org_id, dv.unit_id, 'events.admin_roster') then
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
  select core.registration_paid(p_registration_id) + coalesce(sum(p.amount), 0) into v_live from public.payment_submissions p
  where p.source_type = 'event_registration' and p.source_id = p_registration_id and p.status = 'submitted';
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

