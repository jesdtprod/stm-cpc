-- Doubles registration: the partner search lists only members who are eligible for this division (the same rank, category,
-- format, gender and age rules the registration itself enforces for a partner), are active, are not the caller, and are not
-- already in the division. Registering still runs the strict check in core.register_for_event.
create or replace function core.eligible_partners(p_division_id text, p_term text)
returns table (member_id text, display_name text, member_no text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me public.members; dv public.divisions; v_term text := lower(btrim(coalesce(p_term, '')));
begin
  select m.* into v_me from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null limit 1;
  if v_me.id is null then
    raise exception 'sign in as a member to find a partner' using errcode = '42501';
  end if;
  select * into dv from public.divisions d where d.id = p_division_id and d.org_id = v_me.org_id;
  if not found then
    raise exception 'division not found' using errcode = '22023';
  end if;
  if dv.format <> 'doubles' then
    raise exception 'only a doubles division takes a partner' using errcode = '22023';
  end if;
  if char_length(v_term) < 2 then
    return;
  end if;
  return query
  with cand as materialized (
    select m.id as mid, pe.display_name as dname, m.member_no as mno
    from public.members m join public.persons pe on pe.id = m.person_id
    where m.org_id = v_me.org_id and m.deleted_at is null and m.status = 'active' and m.id <> v_me.id
      and (strpos(lower(pe.display_name), v_term) > 0 or strpos(lower(m.member_no), v_term) > 0)
      and not exists (
        select 1 from public.registrations r
        where r.division_id = dv.id and r.status in ('requested', 'confirmed', 'waitlisted')
          and (r.member_id = m.id or (r.meta ->> 'partner_member_id') = m.id))
    order by pe.display_name limit 100
  )
  select c.mid, c.dname, c.mno from cand c
  where core.registration_problem(c.mid, dv.id, true) is null
  order by c.dname limit 20;
end $$;
create or replace function public.eligible_partners(p_division_id text, p_term text)
returns table (member_id text, display_name text, member_no text)
language sql stable security invoker set search_path = '' as $$ select * from core.eligible_partners(p_division_id, p_term) $$;
revoke all on function core.eligible_partners(text, text), public.eligible_partners(text, text) from public, anon, authenticated;
grant execute on function core.eligible_partners(text, text), public.eligible_partners(text, text) to authenticated, service_role;

notify pgrst, 'reload schema';
