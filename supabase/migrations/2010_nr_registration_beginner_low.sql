-- PLAN 8.9 (revised): a player with no rating (NR) for the division's format may register only in a division whose lowest
-- allowed rank is Beginner Low: a Beginner division with no higher minimum. They skip the rank and category check there; gender,
-- age and the other rules still apply. Replaces the "up to Novice Low" rule of migration 2000.

create or replace function core.registration_problem(p_member_id text, p_division_id text, p_soft boolean default true)
returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  m public.members;
  per public.persons;
  dv public.divisions;
  ev public.events;
  v_rank record;
  v_nr boolean := false;
  v_low text;
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

  if core.cpc_points_enabled(m.org_id) then
    -- ratings are on: the rating for this division's format decides (Singles or Doubles), never the Club Rank
    select r.id, r.sort_order, l.category_id into v_rank
    from public.member_cpc_ratings cr
    join public.ranks r on r.id = core.cpc_rank_for_points(m.org_id, cr.points)
    join public.rank_ladders l on l.id = r.ladder_id
    where cr.member_id = m.id and cr.discipline = dv.format and cr.deleted_at is null and cr.points is not null;
    if not found then
      -- NR (no rating for this format): only a division whose lowest allowed rank is Beginner Low (its own minimum, or the
      -- bottom of its category when it has no minimum), i.e. a Beginner division open from the start
      select coalesce(
        (select x.code from public.ranks x where x.id = dv.min_rank_id),
        (select x.code from public.ranks x join public.rank_ladders ll on ll.id = x.ladder_id
          where ll.category_id = dv.category_id and x.deleted_at is null and ll.deleted_at is null order by x.sort_order limit 1)) into v_low;
      if v_low = 'beginner-low' then
        v_nr := true;
      else
        return format('You have no %s rating yet. Unrated players can join Beginner divisions that start at Beginner Low; ask an administrator to assess your rating.', dv.format);
      end if;
    end if;
  else
    select r.id, r.sort_order, l.category_id into v_rank
    from public.member_ranks mr
    join public.ranks r on r.id = mr.rank_id
    join public.rank_ladders l on l.id = r.ladder_id
    where mr.member_id = m.id and mr.deleted_at is null;
    if not found then
      return 'You have no rank yet, so you cannot join a ranked division.';
    end if;
  end if;
  if not v_nr then
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

notify pgrst, 'reload schema';
