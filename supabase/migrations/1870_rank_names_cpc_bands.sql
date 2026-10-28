-- Rank names follow the CPC points bands (docs/CPC_RATING.md). Names only: ids, codes, order, bands, starting flags and
-- every link stay as they are. The old Novice names carried swapped ranges in their text; the ranges now come from
-- rating_min / rating_max, not from the name. The Open/Professional label is kept on purpose (members know it as Open).
update public.ranks r
set name = v.new_name
from (values
  ('beginner-low', 'Beginner Low'),
  ('beginner-high', 'Beginner High'),
  ('novice-low', 'Novice Low'),
  ('novice-high', 'Novice High'),
  ('intermediate-low', 'Intermediate Low'),
  ('intermediate-high', 'Intermediate High'),
  ('advanced-low', 'Advanced Low'),
  ('advanced-high', 'Advanced High')
) as v(code, new_name)
where r.code = v.code and r.deleted_at is null and r.name is distinct from v.new_name;
