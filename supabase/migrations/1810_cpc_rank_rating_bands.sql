-- CPC skill-rating reference bands. These are club reference values only:
-- they do not verify, fetch, or alter a member's external DUPR rating.
alter table public.ranks
  add column rating_min numeric(4,3),
  add column rating_max numeric(4,3),
  add constraint ranks_rating_band_chk check (
    (rating_min is null and rating_max is null)
    or (
      rating_min is not null
      and rating_max is not null
      and rating_min >= 0
      and rating_max <= 8
      and rating_min <= rating_max
    )
  );

-- Keep rank IDs and ladder order unchanged so member ranks, event limits,
-- movement rules, registrations and history retain their existing links.
update public.ranks r
set
  name = case
    when c.code = 'open' and r.code = 'open' then 'Open/Professional'
    else r.name
  end,
  rating_min = case
    when c.code = 'beginner' and r.code = 'beginner-low' then 2.000
    when c.code = 'beginner' and r.code = 'beginner-high' then 2.250
    when c.code = 'novice' and r.code = 'novice-low' then 2.500
    when c.code = 'novice' and r.code = 'novice-high' then 2.750
    when c.code = 'intermediate' and r.code = 'intermediate-low' then 3.000
    when c.code = 'intermediate' and r.code = 'intermediate-high' then 3.500
    when c.code = 'advanced' and r.code = 'advanced-low' then 4.000
    when c.code = 'advanced' and r.code = 'advanced-high' then 4.500
    when c.code = 'open' and r.code = 'open' then 5.000
    else r.rating_min
  end,
  rating_max = case
    when c.code = 'beginner' and r.code = 'beginner-low' then 2.249
    when c.code = 'beginner' and r.code = 'beginner-high' then 2.499
    when c.code = 'novice' and r.code = 'novice-low' then 2.749
    when c.code = 'novice' and r.code = 'novice-high' then 2.999
    when c.code = 'intermediate' and r.code = 'intermediate-low' then 3.499
    when c.code = 'intermediate' and r.code = 'intermediate-high' then 3.999
    when c.code = 'advanced' and r.code = 'advanced-low' then 4.499
    when c.code = 'advanced' and r.code = 'advanced-high' then 4.999
    when c.code = 'open' and r.code = 'open' then 8.000
    else r.rating_max
  end
from public.rank_ladders l
join public.categories c on c.id = l.category_id
where r.ladder_id = l.id
  and r.deleted_at is null
  and l.deleted_at is null
  and c.deleted_at is null;

comment on column public.ranks.rating_min is
  'Optional club skill-rating reference band minimum; not an externally verified rating.';
comment on column public.ranks.rating_max is
  'Optional club skill-rating reference band maximum; not an externally verified rating.';

notify pgrst, 'reload schema';
