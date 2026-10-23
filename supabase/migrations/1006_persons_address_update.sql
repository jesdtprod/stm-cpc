-- 1006_persons_address_update (PLAN 2.2, part 2 of 3; fixes 1005)
-- 1005 rejected an UPDATE that changed only the barangay (or city), because the old, now stale
-- higher codes were still on the row. On UPDATE, the most specific code that changed wins and the
-- codes that did not change are re-derived from it. Codes that did change must still agree.

create or replace function core.tg_persons_address() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  deepest text;
  a public.psgc_areas;
  chain public.psgc_areas[] := '{}';
  cur public.psgc_areas;
  brgy text; city text; prov text; reg text; prov_name text; reg_name text; brgy_name text; city_name text;
  ch_b boolean; ch_c boolean; ch_p boolean; ch_r boolean;
  parts text[] := '{}';
begin
  if tg_op = 'UPDATE' then
    if (new.street_line, new.barangay_code, new.city_muni_code, new.province_code, new.region_code)
         is not distinct from (old.street_line, old.barangay_code, old.city_muni_code, old.province_code, old.region_code) then
      return new;
    end if;
    ch_b := new.barangay_code is distinct from old.barangay_code;
    ch_c := new.city_muni_code is distinct from old.city_muni_code;
    ch_p := new.province_code is distinct from old.province_code;
    ch_r := new.region_code is distinct from old.region_code;
    if ch_b and new.barangay_code is not null then
      deepest := new.barangay_code;
    elsif ch_c and new.city_muni_code is not null then
      deepest := new.city_muni_code;
    elsif ch_p and new.province_code is not null then
      deepest := new.province_code;
    elsif ch_r and new.region_code is not null then
      deepest := new.region_code;
    end if;
    if deepest is not null then
      -- Codes that did not change are stale: they are derived again below.
      if not ch_b then new.barangay_code := null; end if;
      if not ch_c then new.city_muni_code := null; end if;
      if not ch_p then new.province_code := null; end if;
      if not ch_r then new.region_code := null; end if;
    end if;
  end if;
  deepest := coalesce(deepest, new.barangay_code, new.city_muni_code, new.province_code, new.region_code);

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
    -- Anything still supplied must agree with the chain.
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
    -- Metro Manila has no province: its name stands in for it.
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
