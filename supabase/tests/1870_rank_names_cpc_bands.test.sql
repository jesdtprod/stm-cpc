begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table live as
  select r.code, r.name, r.rating_min, r.rating_max, r.sort_order, l.id as ladder_id
  from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
  where r.deleted_at is null and l.deleted_at is null
    and r.org_id = (select id from public.orgs where code = 'cpc');

select is((select count(*)::int from live), 9, 'nine live ranks');
select is((select name from live where code = 'beginner-low'), 'Beginner Low (2.000–2.249)', 'Beginner Low');
select is((select name from live where code = 'beginner-high'), 'Beginner High (2.250–2.499)', 'Beginner High');
select is((select name from live where code = 'novice-low'), 'Novice Low (2.500–2.749)', 'Novice Low');
select is((select name from live where code = 'novice-high'), 'Novice High (2.750–2.999)', 'Novice High');
select is((select name from live where code = 'intermediate-low'), 'Intermediate Low (3.000–3.499)', 'Intermediate Low');
select is((select name from live where code = 'intermediate-high'), 'Intermediate High (3.500–3.999)', 'Intermediate High');
select is((select name from live where code = 'advanced-low'), 'Advanced Low (4.000–4.499)', 'Advanced Low');
select is((select name from live where code = 'advanced-high'), 'Advanced High (4.500–4.999)', 'Advanced High');
select is((select name from live where code = 'open'), 'Open/Professional', 'the top tier keeps the Open/Professional label');
-- migration 1880 puts the band back into each name (generated from rating_min/rating_max), so every screen can show it
select is((select count(*)::int from live where code <> 'open' and name !~ '\(\d\.\d{3}–\d\.\d{3}\)$'), 0, 'every Low/High name ends with its band');
select is((select count(*)::int from live where code <> 'open' and name <> (regexp_replace(name, ' \(.*$', '') || ' (' || to_char(rating_min, 'FM0.000') || '–' || to_char(rating_max, 'FM0.000') || ')')), 0, 'and the band in the name equals the stored band');
select is((select rating_min from live where code = 'novice-low'), 2.500::numeric, 'Novice Low starts at 2.500');
select is((select rating_max from live where code = 'novice-high'), 2.999::numeric, 'Novice High ends at 2.999');
select is((select rating_min from live where code = 'open'), 5.000::numeric, 'Open/Professional starts at 5.000');
select is((select count(*)::int from live l where core.cpc_rank_for_points((select id from public.orgs where code = 'cpc'), l.rating_min) is distinct from
  (select r.id from public.ranks r where r.code = l.code and r.deleted_at is null)), 0, 'each band start maps back to its own rank');
select * from finish();
rollback;
