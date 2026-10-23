-- 1005_psgc_address (PLAN 2.2, part 2 of 3; design: docs/CLUB_SCHEMA.md D10)
-- Philippine address reference (PSGC: regions, provinces, cities/municipalities, barangays) and the
-- address columns on persons. The reference rows are loaded by scripts/seed-psgc.mjs, not by this file.
-- Deviation on purpose: psgc_areas has no audit trigger. It is public reference data loaded in bulk
-- (about 44,000 rows); auditing every row would only fill audit_log with noise.

-- ---------------------------------------------------------------------------
-- psgc_areas: one row per area. class: master (reference data, no personal data).
--   level       region | province | city_muni | barangay
--   parent_code province -> region; city_muni -> province, or region when it has no province
--               (Metro Manila's cities; a few special cities); barangay -> city_muni
-- ---------------------------------------------------------------------------
create table public.psgc_areas (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  unit_id       text collate "C" references public.org_units (id) on delete restrict,
  code          text not null constraint psgc_areas_code_chk check (code ~ '^[0-9]{9}$'),
  level         text not null constraint psgc_areas_level_chk check (level in ('region', 'province', 'city_muni', 'barangay')),
  name          text not null constraint psgc_areas_name_chk check (length(btrim(name)) > 0),
  parent_code   text,
  region_code   text not null,
  province_code text,
  is_city       boolean not null default false,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb,
  constraint psgc_areas_org_code_uq unique (org_id, code),
  constraint psgc_areas_parent_chk check ((level = 'region') = (parent_code is null)),
  constraint psgc_areas_province_chk check (level <> 'province' or province_code = code)
);
comment on table public.psgc_areas is 'class: master. Reference data (PSGC), loaded by scripts/seed-psgc.mjs. Read by every org member; writes by service code only. Contains no personal data.';
create index psgc_areas_org_idx on public.psgc_areas (org_id);
create index psgc_areas_unit_idx on public.psgc_areas (unit_id);
create index psgc_areas_parent_idx on public.psgc_areas (org_id, level, parent_code, name) where deleted_at is null;
create index psgc_areas_region_idx on public.psgc_areas (org_id, region_code);

select core.attach_standard('public.psgc_areas', 'master');
drop trigger z_audit on public.psgc_areas;

alter table public.psgc_areas enable row level security;
create policy psgc_areas_select on public.psgc_areas for select to authenticated
  using (core.is_org_member(org_id));
select core.grant_client_dml('public.psgc_areas', false, false);
grant select, insert, update on public.psgc_areas to service_role;

-- ---------------------------------------------------------------------------
-- persons: address columns. Clients send the deepest code they know (usually the barangay) and a
-- street line; the trigger below fills the higher codes and the text snapshot from the reference
-- rows and rejects a combination that does not belong together.
-- ---------------------------------------------------------------------------
alter table public.persons
  add column street_line    text constraint persons_street_chk check (street_line is null or length(street_line) <= 200),
  add column barangay_code  text,
  add column city_muni_code text,
  add column province_code  text,
  add column region_code    text,
  add column address_text   text;

alter table public.persons
  add constraint persons_barangay_fk foreign key (org_id, barangay_code) references public.psgc_areas (org_id, code) on delete restrict,
  add constraint persons_city_muni_fk foreign key (org_id, city_muni_code) references public.psgc_areas (org_id, code) on delete restrict,
  add constraint persons_province_fk foreign key (org_id, province_code) references public.psgc_areas (org_id, code) on delete restrict,
  add constraint persons_region_fk foreign key (org_id, region_code) references public.psgc_areas (org_id, code) on delete restrict;
create index persons_barangay_idx on public.persons (org_id, barangay_code);
create index persons_city_muni_idx on public.persons (org_id, city_muni_code);
create index persons_province_idx on public.persons (org_id, province_code);
create index persons_region_idx on public.persons (org_id, region_code);

create or replace function core.tg_persons_address() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  deepest text := coalesce(new.barangay_code, new.city_muni_code, new.province_code, new.region_code);
  a public.psgc_areas;
  chain public.psgc_areas[] := '{}';
  cur public.psgc_areas;
  brgy text; city text; prov text; reg text; prov_name text; reg_name text; brgy_name text; city_name text;
  parts text[] := '{}';
begin
  if tg_op = 'UPDATE'
     and (new.street_line, new.barangay_code, new.city_muni_code, new.province_code, new.region_code)
         is not distinct from (old.street_line, old.barangay_code, old.city_muni_code, old.province_code, old.region_code) then
    return new;
  end if;

  if deepest is not null then
    select * into cur from public.psgc_areas
    where org_id = new.org_id and code = deepest and deleted_at is null;
    if not found then
      raise exception 'unknown address code %', deepest using errcode = '22023';
    end if;
    -- Walk up to the region.
    loop
      chain := chain || cur;
      exit when cur.parent_code is null;
      select * into cur from public.psgc_areas
      where org_id = new.org_id and code = cur.parent_code and deleted_at is null;
      if not found then
        raise exception 'address code % has a missing parent', deepest using errcode = '22023';
      end if;
    end loop;
    foreach a in array chain loop
      case a.level
        when 'barangay' then brgy := a.code; brgy_name := a.name;
        when 'city_muni' then city := a.code; city_name := a.name;
        when 'province' then prov := a.code; prov_name := a.name;
        when 'region' then reg := a.code; reg_name := a.name;
      end case;
    end loop;
    -- Anything the caller supplied must agree with the chain.
    if (new.barangay_code is not null and new.barangay_code is distinct from brgy)
       or (new.city_muni_code is not null and new.city_muni_code is distinct from city)
       or (new.province_code is not null and new.province_code is distinct from prov)
       or (new.region_code is not null and new.region_code is distinct from reg) then
      raise exception 'the address codes do not belong together' using errcode = '22023';
    end if;
    new.barangay_code := brgy;
    new.city_muni_code := city;
    new.province_code := prov;
    new.region_code := reg;
    -- Metro Manila has no province: its region name stands in for it.
    if brgy_name is not null then parts := parts || brgy_name; end if;
    if city_name is not null then parts := parts || city_name; end if;
    if prov_name is not null then parts := parts || prov_name;
    elsif reg = '130000000' then parts := parts || 'Metro Manila';
    elsif reg_name is not null and city_name is null then parts := parts || reg_name;
    end if;
  end if;

  if new.street_line is not null then
    new.street_line := nullif(btrim(new.street_line), '');
  end if;
  if new.street_line is not null then parts := array[new.street_line] || parts; end if;
  new.address_text := nullif(array_to_string(parts, ', '), '');
  return new;
end $$;
revoke all on function core.tg_persons_address() from public, anon, authenticated;
create trigger c3_persons_address before insert or update on public.persons
  for each row execute function core.tg_persons_address();

-- The columns are new: refresh the column-level grants on persons.
select core.grant_client_dml('public.persons', true, true);

-- ---------------------------------------------------------------------------
-- Address is personal data: mask it in audit_log like email, mobile and birth date.
-- (Same function as 0002 with 'address' and 'street' added to the masked names.)
-- ---------------------------------------------------------------------------
create or replace function core.tg_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  o jsonb;
  n jsonb;
  oldv jsonb := '{}'::jsonb;
  newv jsonb := '{}'::jsonb;
  k text;
  act text := lower(tg_op);
  rid text;
  org text;
begin
  if tg_op = 'INSERT' then
    n := to_jsonb(new); newv := n; rid := n ->> 'id'; org := n ->> 'org_id';
  elsif tg_op = 'DELETE' then
    o := to_jsonb(old); oldv := o; rid := o ->> 'id'; org := o ->> 'org_id';
  else
    o := to_jsonb(old); n := to_jsonb(new); rid := n ->> 'id'; org := n ->> 'org_id';
    for k in select jsonb_object_keys(n) loop
      if k in ('updated_at', 'updated_by', 'version') then continue; end if;
      if o -> k is distinct from n -> k then
        oldv := oldv || jsonb_build_object(k, o -> k);
        newv := newv || jsonb_build_object(k, n -> k);
      end if;
    end loop;
    if newv = '{}'::jsonb then return null; end if;
    if o -> 'deleted_at' = 'null'::jsonb and n -> 'deleted_at' <> 'null'::jsonb then act := 'soft_delete';
    elsif o -> 'deleted_at' <> 'null'::jsonb and n -> 'deleted_at' = 'null'::jsonb then act := 'restore';
    end if;
  end if;

  for k in select jsonb_object_keys(oldv) loop
    if k ~* '(password|passwd|token|secret|email|mobile|phone|birth|address|street)' then oldv := jsonb_set(oldv, array[k], '"***"'); end if;
  end loop;
  for k in select jsonb_object_keys(newv) loop
    if k ~* '(password|passwd|token|secret|email|mobile|phone|birth|address|street)' then newv := jsonb_set(newv, array[k], '"***"'); end if;
  end loop;

  insert into core.audit_log (org_id, actor_id, action, table_name, record_id, old_values, new_values, request_id)
  values (
    org, coalesce(core.current_profile_id(), 'system'), act, tg_table_schema || '.' || tg_table_name, rid,
    nullif(oldv, '{}'::jsonb), nullif(newv, '{}'::jsonb),
    (nullif(current_setting('request.headers', true), '')::jsonb) ->> 'x-request-id'
  );
  return null;
end $$;
