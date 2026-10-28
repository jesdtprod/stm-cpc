-- Members may choose an existing, eligible event guest as their doubles partner.
-- Guest profile creation and assessment remain admin-only. The member owns payment.
create function public.eligible_division_partners(p_division_id text, p_term text)
returns table(member_id text, guest_participant_id text, display_name text, member_no text)
language plpgsql stable security definer set search_path = '' as $$
declare me public.members; dv public.divisions; term text := lower(btrim(coalesce(p_term,'')));
begin
  select * into me from public.members m where m.profile_id = core.current_profile_id() and m.deleted_at is null;
  if me.id is null or me.status <> 'active' or not core.has_permission(me.org_id,null,'events.register') then
    raise exception 'only an active member can find a partner' using errcode = '42501';
  end if;
  select * into dv from public.divisions d where d.id = p_division_id and d.org_id = me.org_id;
  if not found or dv.format <> 'doubles' then raise exception 'choose a doubles division' using errcode = '22023'; end if;
  if length(term) < 2 or core.registration_problem(me.id,dv.id,true) is not null then return; end if;
  return query
    select candidates.mid, candidates.gid, candidates.dname, candidates.mno from (
      select m.member_id as mid, null::text as gid, m.display_name as dname, m.member_no as mno
        from core.eligible_partners(dv.id,term) m
      union all
      select null::text, ep.id, pe.display_name, null::text
        from public.event_participants ep join public.persons pe on pe.id = ep.person_id
        where ep.event_id = dv.event_id and ep.org_id = me.org_id and ep.member_id is null
          and ep.deleted_at is null and pe.deleted_at is null and pe.kind = 'guest'
          and strpos(lower(pe.display_name),term) > 0
          and core.guest_registration_problem(ep.id,dv.id,null) is null
          and not exists(select 1 from public.registrations r where r.division_id = dv.id
            and r.status in ('requested','confirmed','waitlisted')
            and (r.guest_participant_id = ep.id or r.guest_partner_participant_id = ep.id))
    ) candidates order by candidates.dname, candidates.mid, candidates.gid limit 20;
end $$;
revoke all on function public.eligible_division_partners(text,text) from public, anon, authenticated;
grant execute on function public.eligible_division_partners(text,text) to authenticated, service_role;

create function public.register_for_event_with_guest(p_id text, p_division_id text, p_guest_participant_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me public.members; dv public.divisions; ev public.events; ep public.event_participants;
  previous public.registrations; result public.registrations; problem text; fingerprint text;
  guest_rank text; guest_name text; taken integer; waitlisted boolean := false;
begin
  select * into me from public.members m where m.profile_id = core.current_profile_id() and m.deleted_at is null;
  if me.id is null or me.status <> 'active' or not core.has_permission(me.org_id,null,'events.register') then
    raise exception 'only an active member can register' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then raise exception 'a registration ID is required' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('registration:' || p_id,0));
  fingerprint := core.hash_of(jsonb_build_object('division',p_division_id,'member',me.id,'guest_partner',p_guest_participant_id));
  select * into previous from public.registrations r where r.id = p_id;
  if found then
    if previous.org_id <> me.org_id or previous.payload_hash <> fingerprint then
      raise exception 'this registration ID was already used for a different request' using errcode = 'CP422';
    end if;
    return jsonb_build_object('id',previous.id,'status',previous.status,'fee',previous.fee_snapshot,'replayed',true);
  end if;
  select * into dv from public.divisions d where d.id = p_division_id and d.org_id = me.org_id for update;
  if not found or dv.format <> 'doubles' then raise exception 'choose a doubles division' using errcode = '22023'; end if;
  select * into ev from public.events e where e.id = dv.event_id;
  problem := core.registration_problem(me.id,dv.id,true);
  if problem is not null then raise exception '%',problem using errcode = '22023'; end if;
  select * into ep from public.event_participants e where e.id = p_guest_participant_id and e.event_id = ev.id
    and e.org_id = me.org_id and e.member_id is null and e.deleted_at is null for share;
  if not found then raise exception 'choose an existing guest from this event' using errcode = '22023'; end if;
  problem := core.guest_registration_problem(ep.id,dv.id,null);
  if problem is not null then raise exception 'your guest partner cannot join: %',problem using errcode = '22023'; end if;
  guest_rank := core.guest_assessed_rank(ep.id,dv.format,me.org_id);
  select p.display_name into guest_name from public.persons p where p.id = ep.person_id;
  if exists(select 1 from public.registrations r where r.division_id = dv.id and r.status in ('requested','confirmed','waitlisted')
    and (r.member_id = me.id or r.meta->>'partner_member_id' = me.id
      or r.guest_participant_id = ep.id or r.guest_partner_participant_id = ep.id)) then
    raise exception 'you or your partner are already registered in this division' using errcode = '23505';
  end if;
  select count(*) into taken from public.registrations r where r.division_id = dv.id and r.status in ('requested','confirmed');
  if dv.max_entries is not null and taken >= dv.max_entries then
    if not core.setting_bool(me.org_id,'events.waitlist_enabled',true) then raise exception 'this division is full' using errcode = '22023'; end if;
    waitlisted := true;
  end if;
  insert into public.registrations(id,org_id,unit_id,event_id,division_id,member_id,fee_snapshot,payload_hash,
    guest_partner_participant_id,guest_partner_rank_id,guest_partner_name_snapshot)
    values(p_id,me.org_id,dv.unit_id,ev.id,dv.id,me.id,ev.fee,fingerprint,ep.id,guest_rank,guest_name);
  if waitlisted then update public.registrations set status = 'waitlisted',status_reason = 'Division full' where id = p_id;
  else perform core.try_confirm_registration(p_id); end if;
  perform core.write_audit(me.org_id,'registration.create','public.registrations',p_id,null,
    jsonb_build_object('event',ev.id,'division',dv.id,'member',me.id,'guest_partner',ep.id,'fee',ev.fee));
  select * into result from public.registrations r where r.id = p_id;
  return jsonb_build_object('id',result.id,'status',result.status,'fee',result.fee_snapshot,'replayed',false);
end $$;
revoke all on function public.register_for_event_with_guest(text,text,text) from public, anon, authenticated;
grant execute on function public.register_for_event_with_guest(text,text,text) to authenticated, service_role;

-- The same confirmation path serves approval, payment and waitlist promotion.
create or replace function core.confirm_registration_row(p_registration_id text, p_actor text) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.registrations; v_entry text; v_partner text;
begin
  select * into r from public.registrations where id = p_registration_id for update;
  if r.status not in ('requested','waitlisted') then return; end if;
  if r.guest_participant_id is not null then
    if core.guest_registration_problem(r.guest_participant_id,r.division_id,r.guest_rank_id,true) is not null then
      raise exception 'Guest eligibility changed; review this registration' using errcode = '22023';
    end if;
    if r.meta->>'partner_member_id' is not null and not exists(select 1 from public.members m where m.id = r.meta->>'partner_member_id' and m.status = 'active' and m.deleted_at is null) then
      raise exception 'Member partner eligibility changed; review this registration' using errcode = '22023';
    end if;
  end if;
  if r.guest_partner_participant_id is not null and core.guest_registration_problem(r.guest_partner_participant_id,r.division_id,r.guest_partner_rank_id,true) is not null then
    raise exception 'Guest partner eligibility changed; review this registration' using errcode = '22023';
  end if;
  update public.registrations set status = 'confirmed',status_reason = null where id = r.id;
  if r.fee_snapshot > 0 then
    perform core.post_ledger(r.org_id,core.registration_payer(r.id),-r.fee_snapshot,'event_registration',r.id,'charge','Event registration fee');
  end if;
  insert into public.entries(org_id,division_id,registration_id) values(r.org_id,r.division_id,r.id) returning id into v_entry;
  if r.member_id is not null then
    insert into public.entry_members(org_id,entry_id,member_id) values(r.org_id,v_entry,r.member_id);
  else
    insert into public.entry_guests(org_id,unit_id,entry_id,participant_id,display_name_snapshot)
      values(r.org_id,r.unit_id,v_entry,r.guest_participant_id,r.guest_name_snapshot);
  end if;
  if r.guest_partner_participant_id is not null then
    insert into public.entry_guests(org_id,unit_id,entry_id,participant_id,display_name_snapshot)
      values(r.org_id,r.unit_id,v_entry,r.guest_partner_participant_id,r.guest_partner_name_snapshot);
  end if;
  v_partner := r.meta->>'partner_member_id';
  if v_partner is not null then insert into public.entry_members(org_id,entry_id,member_id) values(r.org_id,v_entry,v_partner); end if;
end $$;
notify pgrst, 'reload schema';
