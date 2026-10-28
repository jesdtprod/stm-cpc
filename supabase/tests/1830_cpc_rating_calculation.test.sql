begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

-- Every lower/upper boundary, including the wider Intermediate/Advanced bands.
select is(core.cpc_rating_band_code(lo), code, code || ' lower boundary')
from (values
  (2.000, 'beginner-low'), (2.250, 'beginner-high'),
  (2.500, 'novice-low'), (2.750, 'novice-high'),
  (3.000, 'intermediate-low'), (3.500, 'intermediate-high'),
  (4.000, 'advanced-low'), (4.500, 'advanced-high'), (5.000, 'open')
) b(lo, code);
select is(core.cpc_rating_band_code(hi), code, code || ' upper boundary')
from (values
  (2.249, 'beginner-low'), (2.499, 'beginner-high'),
  (2.749, 'novice-low'), (2.999, 'novice-high'),
  (3.499, 'intermediate-low'), (3.999, 'intermediate-high'),
  (4.499, 'advanced-low'), (4.999, 'advanced-high'), (8.000, 'open')
) b(hi, code);
select is(core.cpc_rating_band_code(null), null::text, 'unrated has no numeric rank');
select throws_ok($$select core.cpc_rating_band_code(0)$$, '22023', null, 'zero is not a rating');
select throws_ok($$select core.cpc_rating_band_code(8.001)$$, '22023', null, 'out-of-range rating rejected');
select throws_ok($$select core.cpc_rating_band_code(2.2499)$$, '22023', null, 'ambiguous precision rejected');
select throws_ok($$select core.cpc_rating_band_code('NaN')$$, '22023', null, 'NaN is not a rating');

select is(core.cpc_rating_points(1.950), 1.950, 'a result below 2.000 is kept as it is (cpc-v2)');
select is(core.cpc_rating_points(-0.5), 0.000, 'division points stop at the 0.000 floor');
select is(core.cpc_rating_points(8.150), 8.000, 'division points stop at the ceiling');
select is(core.cpc_rating_points(2.7495), 2.750, 'division points round once to three decimals');
select is(core.cpc_rating_band_code(core.cpc_rating_points(2.7495)), 'novice-high', 'rounded points determine promotion');
select throws_ok($$select core.cpc_rating_points(null)$$, '22023', null, 'unrated is not silently initialized');
select throws_ok($$select core.cpc_rating_points('NaN')$$, '22023', null, 'NaN calculated points rejected');
select throws_ok($$select core.cpc_rating_points('Infinity')$$, '22023', null, 'infinite calculated points rejected');
select throws_ok($$select core.cpc_rating_points('-Infinity')$$, '22023', null, 'negative infinite calculated points rejected');

select is(round(core.cpc_rating_delta(3, 3, 11, 9, 5), 6), 0.005000, 'equal-rated established 11-9 winner gains 0.005');
select is(round(core.cpc_rating_delta(3, 3, 9, 11, 5), 6), -0.005000, 'equal-rated established 9-11 loser loses 0.005');
select is(round(core.cpc_rating_delta(3, 3, 11, 9, 4), 6), 0.010000, 'fifth played match remains provisional');
select is(round(core.cpc_rating_delta(3, 3, 11, 9, 5), 6), 0.005000, 'sixth played match uses established factor');
select is(core.cpc_rating_delta(3, 3, 10, 10, 5), 0::numeric, 'equal performance against equal strength has no adjustment');
select ok(core.cpc_rating_delta(3, 3.5, 9, 11, 5) > 0, 'close loss against stronger opposition can gain points');
select ok(core.cpc_rating_delta(3.5, 3, 11, 9, 5) < 0, 'underperforming win against weaker opposition can lose points');
select ok(core.cpc_rating_delta(3, 3, 11, 0, 5) > core.cpc_rating_delta(3, 3, 11, 9, 5), 'score margin affects the adjustment');
select is(round(core.cpc_rating_delta(3, 3.5, 9, 11, 5) + core.cpc_rating_delta(3.5, 3, 11, 9, 5), 12), 0::numeric, 'equal factors produce opposing deltas');
select is(core.cpc_rating_delta((2.5 + 3.5) / 2, (2.75 + 3.25) / 2, 11, 9, 5), core.cpc_rating_delta(3, 3, 11, 9, 5), 'doubles uses team means');
select ok(abs(core.cpc_rating_delta(2, 8, 11, 0, 0)) <= 0.200, 'provisional raw delta is bounded');
select ok(abs(core.cpc_rating_delta(8, 2, 0, 11, 5)) <= 0.100, 'established raw delta is bounded');
select lives_ok($$select core.cpc_rating_delta(3, 3, 2147483647, 2147483647, 5)$$, 'point totals cannot overflow integer addition');
select throws_ok($$select core.cpc_rating_delta(null, 3, 11, 9, 0)$$, '22023', null, 'unrated player requires explicit starting points');
select throws_ok($$select core.cpc_rating_delta(3, 0, 11, 9, 0)$$, '22023', null, 'unrated opponent cannot be zero');
select throws_ok($$select core.cpc_rating_delta(3, 3, 0, 0, 0)$$, '22023', null, 'unplayed zero-zero result rejected');
select throws_ok($$select core.cpc_rating_delta(3, 3, -1, 11, 0)$$, '22023', null, 'negative score rejected');
select throws_ok($$select core.cpc_rating_delta(3, 3, null, 11, 0)$$, '22023', null, 'missing score rejected');
select throws_ok($$select core.cpc_rating_delta(3, 3, 11, 9, -1)$$, '22023', null, 'negative prior match count rejected');
select throws_ok($$select core.cpc_rating_delta(3, 3, 11, 9, null)$$, '22023', null, 'missing prior match count rejected');
select throws_ok($$select core.cpc_rating_delta('NaN', 3, 11, 9, 0)$$, '22023', null, 'nonfinite team strength rejected');

select ok(not has_function_privilege('anon', 'core.cpc_rating_delta(numeric,numeric,integer,integer,integer)', 'execute'), 'anonymous cannot invoke calculation');
select ok(not has_function_privilege('authenticated', 'core.cpc_rating_delta(numeric,numeric,integer,integer,integer)', 'execute'), 'browser cannot invoke calculation');
select ok(not has_function_privilege('authenticated', 'core.cpc_rating_points(numeric)', 'execute'), 'browser cannot invoke division points helper');
select ok(not has_function_privilege('authenticated', 'core.cpc_rating_band_code(numeric)', 'execute'), 'browser cannot invoke band helper');
select ok(not has_function_privilege('anon', 'core.cpc_rating_points(numeric)', 'execute'), 'anonymous cannot invoke division points helper');
select ok(not has_function_privilege('anon', 'core.cpc_rating_band_code(numeric)', 'execute'), 'anonymous cannot invoke band helper');

select * from finish();
rollback;
