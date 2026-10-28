-- PLAN 8.10: a rating is stored as calculated, even below 2.000 (for example 1.850); it is no longer pulled up to 2.000.
-- Anything below 2.250 is classified Beginner Low. The floor is 0.000 and the ceiling stays 8.000. Assessed (typed) ratings
-- keep the 2.000-8.000 range; only results of play can take a rating below 2.000.

-- the stored ratings, their history and the frozen division inputs may be below 2.000
do $$
declare c record; def text;
begin
  for c in
    select conrelid::regclass::text as tbl, conname, pg_get_constraintdef(oid) as def from pg_constraint
    where contype = 'c' and conrelid in ('public.member_cpc_ratings'::regclass, 'public.member_cpc_rating_history'::regclass,
                                         'public.division_cpc_rating_snapshots'::regclass)
      and pg_get_constraintdef(oid) like '%>= 2.000%'
  loop
    def := replace(c.def, '>= 2.000', '>= 0.000');
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
    execute format('alter table %s add constraint %I %s', c.tbl, c.conname, def);
  end loop;
end $$;

create or replace function core.cpc_rating_points(p_candidate numeric) returns numeric
language plpgsql immutable parallel safe set search_path = '' as $$
begin
  if p_candidate is null or p_candidate::text in ('NaN', 'Infinity', '-Infinity') then
    raise exception 'a finite calculated points value is required' using errcode = '22023';
  end if;
  return round(greatest(0.000, least(8.000, p_candidate)), 3);
end $$;

-- classification: a rating below the lowest band (below 2.000) is Beginner Low
create or replace function core.cpc_rank_for_points(p_org text, p_points numeric) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_p numeric := greatest(p_points, 2.000); v_code text; v_ids text[];
begin
  v_code := core.cpc_rating_band_code(v_p);
  select array_agg(r.id order by r.id) into v_ids from public.ranks r
  join public.rank_ladders l on l.id = r.ladder_id and l.deleted_at is null
  where r.org_id = p_org and r.code = v_code and r.deleted_at is null
    and r.rating_min is not null and v_p between r.rating_min and r.rating_max;
  if v_ids is null or cardinality(v_ids) <> 1 then
    raise exception 'the club has no single rank band for % points', p_points using errcode = '22023';
  end if;
  return v_ids[1];
end $$;

notify pgrst, 'reload schema';
