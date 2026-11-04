-- Admin-only entry order, atomic player swaps and replacements before any draw.
-- Replaced registrations and payments retain their original ownership/history.
create function core.roster_players(r public.registrations) returns text[]
language sql immutable set search_path = '' as $$
  select array_remove(array[
    case when r.member_id is not null then 'm:'||r.member_id else 'g:'||r.guest_participant_id end,
    case when r.meta->>'partner_member_id' is not null then 'm:'||(r.meta->>'partner_member_id')
      when r.guest_partner_participant_id is not null then 'g:'||r.guest_partner_participant_id end
  ],null)
$$;
revoke all on function core.roster_players(public.registrations) from public,anon,authenticated;

create function core.insert_roster_replacement(p_source text,p_id text,p_players text[],p_position integer,p_confirm boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare src public.registrations; dv public.divisions; ep public.event_participants;
  mid text; partner text; gid text; pgid text; grank text; prank text;
  gname text; pname text; problem text; player text; rank_id text; n integer;
  genders text[] := array[]::text[]; gender text;
begin
  select * into src from public.registrations where id=p_source;
  select * into dv from public.divisions where id=src.division_id;
  if cardinality(p_players) <> (case when dv.format='doubles' then 2 else 1 end)
    or (select count(distinct x) from unnest(p_players) x)<>cardinality(p_players) then
    raise exception 'Choose distinct players for every team position' using errcode='22023';
  end if;
  for n in 1..cardinality(p_players) loop
    player := p_players[n];
    if exists(select 1 from public.registrations r where r.division_id=dv.id
      and r.status in ('requested','confirmed','waitlisted') and player=any(core.roster_players(r))) then
      raise exception 'A player already belongs to another entry in this division' using errcode='22023';
    end if;
    if left(player,2)='m:' then
      problem := core.registration_problem(substr(player,3),dv.id,true);
      select p.gender into gender from public.members m join public.persons p on p.id=m.person_id
        where m.id=substr(player,3) and m.org_id=dv.org_id and p.deleted_at is null;
      if not found then raise exception 'Choose a member in this club' using errcode='22023'; end if;
      if n=1 then mid:=substr(player,3); else partner:=substr(player,3); end if;
    elsif left(player,2)='g:' then
      select * into ep from public.event_participants where id=substr(player,3) and event_id=src.event_id
        and org_id=dv.org_id and member_id is null and deleted_at is null;
      if not found then raise exception 'Choose a guest in this event' using errcode='22023'; end if;
      select p.display_name,p.gender into pname,gender from public.persons p where p.id=ep.person_id and p.deleted_at is null;
      if not found then raise exception 'This guest is no longer available' using errcode='22023'; end if;
      rank_id:=core.guest_assessed_rank(ep.id,dv.format,dv.org_id);
      if rank_id is null and not core.cpc_points_enabled(dv.org_id) then
        select case when r.guest_participant_id=ep.id then r.guest_rank_id else r.guest_partner_rank_id end into rank_id
          from public.registrations r where r.division_id=dv.id
            and (r.guest_participant_id=ep.id or r.guest_partner_participant_id=ep.id) order by r.created_at desc limit 1;
      end if;
      problem:=core.guest_registration_problem(ep.id,dv.id,rank_id);
      if n=1 then gid:=ep.id; grank:=rank_id; gname:=pname;
      else pgid:=ep.id; prank:=rank_id; end if;
    else raise exception 'Choose a valid member or guest' using errcode='22023';
    end if;
    if problem is not null then raise exception '%',problem using errcode='22023'; end if;
    genders:=array_append(genders,gender);
  end loop;
  if dv.gender='mixed' and dv.format='doubles' and not (genders @> array['male','female']) then
    raise exception 'Mixed doubles requires one male and one female player' using errcode='22023';
  end if;
  insert into public.registrations(id,org_id,unit_id,event_id,division_id,member_id,fee_snapshot,payload_hash,meta,
    guest_participant_id,guest_partner_participant_id,guest_rank_id,guest_partner_rank_id,guest_name_snapshot,guest_partner_name_snapshot)
  values(p_id,src.org_id,src.unit_id,src.event_id,dv.id,mid,src.fee_snapshot,
    core.hash_of(jsonb_build_object('source',src.id,'players',p_players)),
    jsonb_build_object('roster_position',p_position)||case when partner is null then '{}'::jsonb else jsonb_build_object('partner_member_id',partner) end,
    gid,pgid,grank,prank,gname,case when pgid is not null then pname end);
  perform core.try_confirm_registration(p_id);
  if p_confirm and not core.registration_payment_pending(p_id) then
    perform core.confirm_registration_row(p_id,core.current_profile_id());
  end if;
end $$;
revoke all on function core.insert_roster_replacement(text,text,text[],integer,boolean) from public,anon,authenticated;

create function public.edit_division_roster(p_key text,p_division_id text,p_action text,p_source_id text,
  p_target_id text default null,p_source_player integer default null,p_target_player integer default null,
  p_replacement text default null,p_reason text default null,p_versions jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare dv public.divisions; ev public.events; src public.registrations; dst public.registrations;
  a text[]; b text[]; swapped text; aid text; bid text; pos_a integer; pos_b integer;
  replay jsonb; result jsonb; why text:=nullif(btrim(coalesce(p_reason,'')),''); payer text; replacement_payer text;
begin
  select * into dv from public.divisions where id=p_division_id for update;
  if not found or not core.has_permission(dv.org_id,dv.unit_id,'events.admin_roster') then
    raise exception 'Only an administrator can edit this roster' using errcode='42501';
  end if;
  replay:=core.idem_begin(p_key,dv.org_id,'division_roster.edit',jsonb_build_object('division',dv.id,'action',p_action,
    'source',p_source_id,'target',p_target_id,'source_player',p_source_player,'target_player',p_target_player,
    'replacement',p_replacement,'reason',why,'versions',p_versions));
  if replay is not null then return replay; end if;
  select * into ev from public.events where id=dv.event_id for update;
  if dv.status<>'open' or ev.status not in ('registration_open','registration_closed')
    or exists(select 1 from public.division_stages s join public.draws d on d.division_stage_id=s.id
      where s.division_id=dv.id and d.status='active')
    or exists(select 1 from public.division_stages s join public.matches m on m.division_stage_id=s.id
      where s.division_id=dv.id and m.status<>'cancelled') then
    raise exception 'Roster changes are allowed only before the draw' using errcode='22023';
  end if;
  if p_action is null or p_action not in ('team_swap','player_swap','replace') then
    raise exception 'Choose a roster action' using errcode='22023';
  end if;
  perform 1 from public.registrations where division_id=dv.id order by id for update;
  select * into src from public.registrations where id=p_source_id and division_id=dv.id and status in ('requested','confirmed');
  if not found then raise exception 'The source entry changed; reload the roster' using errcode='CP409'; end if;
  if coalesce(p_versions->>src.id,'')<>src.version::text then
    raise exception 'The source entry changed; reload the roster' using errcode='CP409';
  end if;
  if p_action<>'replace' then
    select * into dst from public.registrations where id=p_target_id and division_id=dv.id and status in ('requested','confirmed');
    if not found or dst.id=src.id or coalesce(p_versions->>dst.id,'')<>dst.version::text then
      raise exception 'Choose another current entry; reload if it changed' using errcode='CP409';
    end if;
  end if;
  -- Fill stable positions once; later replacements retain their original slot.
  with positions as (select r.id,row_number() over(order by
    case when r.meta->>'roster_position' ~ '^[0-9]+$' then (r.meta->>'roster_position')::integer end nulls last,r.created_at,r.id)::integer as n
    from public.registrations r where r.division_id=dv.id and r.status in ('requested','confirmed'))
  update public.registrations r set meta=r.meta||jsonb_build_object('roster_position',p.n)
    from positions p where r.id=p.id and r.meta->>'roster_position' is distinct from p.n::text;
  select (meta->>'roster_position')::integer into pos_a from public.registrations where id=src.id;
  select (meta->>'roster_position')::integer into pos_b from public.registrations where id=dst.id;
  if p_action='team_swap' then
    update public.registrations set meta=meta||jsonb_build_object('roster_position',case when id=src.id then pos_b else pos_a end)
      where id in (src.id,dst.id);
    result:=jsonb_build_object('source_id',src.id,'target_id',dst.id);
  else
    if why is null or char_length(why) not between 3 and 500 then
      raise exception 'Give a reason (3 to 500 characters)' using errcode='22023';
    end if;
    a:=core.roster_players(src); b:=core.roster_players(dst);
    if p_source_player is null or p_source_player<1 or p_source_player>cardinality(a) then
      raise exception 'Choose a player in the source entry' using errcode='22023';
    end if;
    if p_action='player_swap' then
      if p_target_player is null or p_target_player<1 or p_target_player>cardinality(b) then
        raise exception 'Choose a player in the target entry' using errcode='22023';
      end if;
      swapped:=a[p_source_player]; a[p_source_player]:=b[p_target_player]; b[p_target_player]:=swapped;
    else
      if p_replacement is null or p_replacement=any(a) then
        raise exception 'Choose a different replacement player' using errcode='22023';
      end if;
      a[p_source_player]:=p_replacement;
    end if;
    if exists(select 1 from public.payment_submissions where source_type='event_registration'
      and source_id in (src.id,dst.id) and status='submitted') then
      raise exception 'Review pending receipts before changing players' using errcode='22023';
    end if;
    aid:=core.ulid(); bid:=case when p_action='player_swap' then core.ulid() end;
    -- Reserve both places before withdrawal, preventing waitlist promotion mid-swap.
    for payer,replacement_payer,swapped in
      select src.id,aid,a[1] union all select dst.id,bid,b[1] where bid is not null
    loop
      insert into public.event_roster_changes(org_id,unit_id,event_id,source_registration_id,target_registration_id,
        kind,reason,carry_payment,previous_fee,new_fee)
      select dv.org_id,dv.unit_id,ev.id,payer,replacement_payer,'replace',why,
        core.registration_payer(payer)=case when left(swapped,2)='m:' then substr(swapped,3)
          else (select person_id from public.event_participants where id=substr(swapped,3)) end,
        r.fee_snapshot,r.fee_snapshot from public.registrations r where r.id=payer;
    end loop;
    perform core.release_registration(src.id,'Admin roster change: '||why);
    if bid is not null then perform core.release_registration(dst.id,'Admin player swap: '||why); end if;
    perform core.insert_roster_replacement(src.id,aid,a,pos_a,src.status='confirmed');
    if bid is not null then perform core.insert_roster_replacement(dst.id,bid,b,pos_b,dst.status='confirmed'); end if;
    result:=jsonb_build_object('source_id',aid,'target_id',bid);
  end if;
  perform core.write_audit(dv.org_id,'division_roster.'||p_action,'public.divisions',dv.id,
    jsonb_build_object('source',src.id,'target',dst.id),result||jsonb_build_object('reason',why));
  perform core.idem_complete(p_key,result);
  return result;
end $$;
revoke all on function public.edit_division_roster(text,text,text,text,text,integer,integer,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.edit_division_roster(text,text,text,text,text,integer,integer,text,text,jsonb) to authenticated;
notify pgrst,'reload schema';
