-- Division status follows the member's own OR partner registration, including guest-led teams.
create or replace function core.my_event_options() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare m public.members; v_out jsonb;
begin
  select * into m from public.members x where x.profile_id = core.current_profile_id() and x.deleted_at is null;
  if not found or m.status <> 'active' then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',e.id,'name',e.name,'starts_on',e.starts_on,'ends_on',e.ends_on,'location',e.location,'fee',e.fee,
    'registration_opens_at',e.registration_opens_at,'registration_closes_at',e.registration_closes_at,
    'divisions',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',d.id,'name',d.name,'format',d.format,'gender',d.gender,'age_group',d.age_group,
        'category',c.name,'max_entries',d.max_entries,
        'taken',(select count(*) from public.registrations r where r.division_id=d.id and r.status in ('requested','confirmed')),
        'waitlisted',(select count(*) from public.registrations r where r.division_id=d.id and r.status='waitlisted'),
        'problem',core.registration_problem(m.id,d.id,true),
        'mine',(
          select jsonb_build_object('id',r.id,'status',r.status,'fee',r.fee_snapshot,
            'is_owner',coalesce(r.member_id=m.id,false),'paid',core.registration_paid(r.id),
            'pending',(select coalesce(sum(p.amount),0) from public.payment_submissions p
              where p.source_type='event_registration' and p.source_id=r.id and p.status='submitted'),
            'payment_required',core.setting_bool(m.org_id,'payments.required.event_registration',false))
          from public.registrations r where r.division_id=d.id
            and (r.member_id=m.id or r.meta->>'partner_member_id'=m.id)
            and r.status in ('requested','confirmed','waitlisted')
          order by r.created_at desc,r.id limit 1)
      ) order by d.name),'[]'::jsonb)
      from public.divisions d join public.categories c on c.id=d.category_id
      where d.event_id=e.id and d.status='open')
  ) order by e.starts_on),'[]'::jsonb) into v_out from public.events e
  where e.org_id=m.org_id and e.status='registration_open';
  return v_out;
end $$;
notify pgrst, 'reload schema';
