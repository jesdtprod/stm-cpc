-- 1750_public_members: a public Members page (#/members) for visitors who are not signed in.
--   Shows every member the club counts as on the roster: active members and imported or invited members who have not
--   signed in yet. Never pending applications, rejected, suspended or archived members.
--   Only: display name, profile photo, and CPC rank with its category (or none). No member ID (it is the sign-in
--   username), contact details, birth date, address, DUPR ID, history or payments.
--   Settings switch public.members_enabled (Settings > Public Pages), ON by default at the club's request. While it is
--   off the function answers {"enabled": false}, no names leave the database and no photo can be signed.

create or replace function core.setting_valid(p_key text, p_value jsonb) returns boolean
language plpgsql stable set search_path = '' as $$
declare
  t text;
  n numeric;
  item text;
begin
  if p_value is null or p_value = 'null'::jsonb then
    return false;
  end if;
  t := jsonb_typeof(p_value);

  if p_key = 'timezone' then
    return t = 'string' and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_value #>> '{}');
  end if;

  if p_key in ('members.signup_enabled', 'members.auto_approve_imported', 'booking.approval_required',
               'payments.required.court_booking', 'payments.required.event_registration',
               'payments.proof_required_non_cash', 'events.registration_approval_required',
               'events.waitlist_enabled', 'ranks.movement_enabled', 'public.results_enabled', 'public.leaderboard_enabled',
               'member_menu.book', 'member_menu.bookings', 'member_menu.events', 'member_menu.ranking',
               'public.members_enabled') then
    return t = 'boolean';
  end if;

  if p_key in ('club.name', 'events.default_scoring_rule') then
    return t = 'string' and char_length(btrim(p_value #>> '{}')) between 1 and 80;
  end if;
  if p_key = 'members.id_prefix' then
    return t = 'string' and (p_value #>> '{}') ~ '^[A-Z]{2,6}$';
  end if;
  if p_key = 'members.id_pattern' then
    return t = 'string' and char_length(p_value #>> '{}') between 1 and 200;
  end if;
  if p_key = 'payments.instructions' then
    return t = 'string' and char_length(p_value #>> '{}') <= 1000;
  end if;

  if p_key = 'payments.methods' then
    if t <> 'array' or jsonb_array_length(p_value) not between 1 and 4 then
      return false;
    end if;
    for item in select jsonb_array_elements_text(p_value) loop
      if item not in ('cash', 'gcash', 'maya', 'bank_transfer') then
        return false;
      end if;
    end loop;
    return (select count(distinct e) = jsonb_array_length(p_value) from jsonb_array_elements_text(p_value) e);
  end if;

  -- whole numbers within a range
  if p_key in ('members.temp_password_days', 'session.idle_minutes', 'booking.slot_minutes', 'booking.advance_days',
               'booking.max_participants', 'booking.request_expiry_hours', 'booking.cancel_cutoff_hours') then
    if t <> 'number' then
      return false;
    end if;
    n := (p_value #>> '{}')::numeric;
    if n <> trunc(n) then
      return false;
    end if;
    return case p_key
      when 'members.temp_password_days' then n between 0 and 365
      when 'session.idle_minutes' then n between 5 and 120
      when 'booking.slot_minutes' then n between 15 and 240
      when 'booking.advance_days' then n between 1 and 365
      when 'booking.max_participants' then n between 1 and 20
      when 'booking.request_expiry_hours' then n between 1 and 168
      else n between 0 and 168
    end;
  end if;

  -- money
  if p_key in ('booking.cancel_fee', 'booking.no_show_fee') then
    if t <> 'number' then
      return false;
    end if;
    n := (p_value #>> '{}')::numeric;
    return n >= 0 and n <= 100000 and n = round(n, 2);
  end if;

  return true;
end $$;

insert into public.settings (org_id, key, value)
select o.id, 'public.members_enabled', 'true'::jsonb
from public.orgs o
where o.code = 'cpc' and o.deleted_at is null
  and not exists (select 1 from public.settings s where s.org_id = o.id and s.key = 'public.members_enabled'
                  and s.unit_id is null and s.deleted_at is null);

-- the members the public page may show, while the switch is on
create or replace function core.public_member_rows() returns table (
  member_id text, display_name text, avatar_path text, category_name text, rank_name text, rank_idx integer
)
language sql stable security definer set search_path = '' as $$
  with club as (
    select o.id from public.orgs o
    where o.code = 'cpc' and o.deleted_at is null and core.setting_bool(o.id, 'public.members_enabled', true)
  )
  select m.id, p.display_name, p.avatar_path, c.name, r.name, ch.idx
  from public.members m
  join club on club.id = m.org_id
  join public.persons p on p.id = m.person_id and p.deleted_at is null
  left join public.member_ranks mr on mr.member_id = m.id and mr.deleted_at is null
  left join public.ranks r on r.id = mr.rank_id
  left join public.rank_ladders l on l.id = r.ladder_id
  left join public.categories c on c.id = l.category_id
  left join core.rank_chain(club.id) ch on ch.rank_id = r.id
  where m.deleted_at is null and m.status in ('active', 'imported', 'invited')
$$;
revoke all on function core.public_member_rows() from public, anon, authenticated;

create or replace function public.public_members() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
begin
  select o.id into v_org from public.orgs o where o.code = 'cpc' and o.deleted_at is null;
  if v_org is null or not core.setting_bool(v_org, 'public.members_enabled', true) then
    return jsonb_build_object('enabled', false);
  end if;
  return jsonb_build_object('enabled', true, 'members', coalesce((
    select jsonb_agg(jsonb_build_object('name', q.display_name, 'photo', q.avatar_path, 'category', q.category_name,
      'rank', q.rank_name) order by q.rank_idx desc nulls last, q.display_name, q.member_id)
    from (select * from core.public_member_rows() order by rank_idx desc nulls last, display_name limit 1000) q), '[]'::jsonb));
end $$;
revoke all on function public.public_members() from public, anon, authenticated;
grant execute on function public.public_members() to anon, authenticated, service_role;

-- Anonymous visitors may sign/read the photos of the members on that page only, and only while it is published.
create or replace function core.public_member_photo(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.public_member_rows() x where x.avatar_path = p_name)
$$;
revoke all on function core.public_member_photo(text) from public, anon, authenticated;
grant execute on function core.public_member_photo(text) to anon, authenticated;

create policy avatars_public_members_select on storage.objects for select to anon, authenticated
  using (bucket_id = 'avatars' and core.public_member_photo(name));
