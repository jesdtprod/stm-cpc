begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

select ok(exists(
  select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'ranks' and column_name = 'rating_min'
), 'ranks stores an optional rating-band minimum');
select ok(exists(
  select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'ranks' and column_name = 'rating_max'
), 'ranks stores an optional rating-band maximum');

select is((
  select format('%s-%s', rating_min, rating_max)
  from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
  join public.categories c on c.id = l.category_id
  where c.code = 'beginner' and r.code = 'beginner-low' and r.deleted_at is null
), '2.000-2.249', 'Beginner Low has the requested 2.000 to 2.249 band');
select is((
  select format('%s-%s', rating_min, rating_max)
  from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
  join public.categories c on c.id = l.category_id
  where c.code = 'intermediate' and r.code = 'intermediate-high' and r.deleted_at is null
), '3.500-3.999', 'Intermediate High has the requested 3.500 to 3.999 band');
select is((
  select format('%s-%s', rating_min, rating_max)
  from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
  join public.categories c on c.id = l.category_id
  where c.code = 'open' and r.code = 'open' and r.deleted_at is null
), '5.000-8.000', 'Open/Professional has the requested 5.000 to 8.000 band');
select is((
  select r.name
  from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
  join public.categories c on c.id = l.category_id
  where c.code = 'open' and r.code = 'open' and r.deleted_at is null
), 'Open/Professional', 'the final tier is named Open/Professional');

select throws_ok(
  $$update public.ranks set rating_min = 3.000, rating_max = 2.999
    where id = (select id from public.ranks where rating_min is not null limit 1)$$,
  '23514', null, 'a rating band cannot end below its start'
);
select throws_ok(
  $$update public.ranks set rating_min = 5.000, rating_max = 8.001
    where id = (select id from public.ranks where rating_min is not null limit 1)$$,
  '23514', null, 'a rating band cannot exceed 8.000'
);

select * from finish();
rollback;
