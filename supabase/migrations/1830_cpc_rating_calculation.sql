-- PLAN 8.4a: private, deterministic CPC points calculation (algorithm cpc-v1).
-- Foundation only: no member backfill or change to the active finalization engine.
-- These are club calculations, not the proprietary DUPR algorithm.

create or replace function core.cpc_rating_delta(
  p_team_points numeric, p_opponent_points numeric,
  p_points_for integer, p_points_against integer, p_prior_matches integer
) returns numeric
language plpgsql immutable parallel safe set search_path = '' as $$
declare
  v_expected numeric;
  v_actual numeric;
  v_k numeric;
begin
  if p_team_points is null or p_opponent_points is null
     or not (p_team_points between 2 and 8)
     or not (p_opponent_points between 2 and 8)
     or p_prior_matches is null or p_prior_matches < 0 then
    raise exception 'valid rated teams and prior match count are required' using errcode = '22023';
  end if;
  if p_points_for is null or p_points_against is null
     or p_points_for < 0 or p_points_against < 0
     or p_points_for::bigint + p_points_against::bigint = 0 then
    raise exception 'played match points must be nonnegative with a positive total' using errcode = '22023';
  end if;

  -- Team strength is the player's points in singles, or the partners' mean in doubles.
  -- A 0.500 rating advantage predicts 10/11 of the scored points.
  v_expected := 1 / (1 + power(10::numeric, (p_opponent_points - p_team_points) / 0.500));
  v_actual := p_points_for::numeric / (p_points_for::bigint + p_points_against::bigint);
  v_k := case when p_prior_matches < 5 then 0.200 else 0.100 end;
  -- Keep precision here: sum played-match deltas, then clamp/round once per division.
  return v_k * (v_actual - v_expected);
end $$;

create or replace function core.cpc_rating_points(p_candidate numeric) returns numeric
language plpgsql immutable parallel safe set search_path = '' as $$
begin
  if p_candidate is null or p_candidate::text in ('NaN', 'Infinity', '-Infinity') then
    raise exception 'a finite calculated points value is required' using errcode = '22023';
  end if;
  return round(greatest(2.000, least(8.000, p_candidate)), 3);
end $$;

create or replace function core.cpc_rating_band_code(p_points numeric) returns text
language plpgsql immutable parallel safe set search_path = '' as $$
begin
  -- Unrated is NULL, never zero. Registration may provisionally use Beginner Low.
  if p_points is null then return null; end if;
  if not (p_points between 2 and 8) or p_points <> round(p_points, 3) then
    raise exception 'CPC points must be between 2.000 and 8.000 with at most three decimals' using errcode = '22023';
  end if;
  return case
    when p_points < 2.250 then 'beginner-low'
    when p_points < 2.500 then 'beginner-high'
    when p_points < 2.750 then 'novice-low'
    when p_points < 3.000 then 'novice-high'
    when p_points < 3.500 then 'intermediate-low'
    when p_points < 4.000 then 'intermediate-high'
    when p_points < 4.500 then 'advanced-low'
    when p_points < 5.000 then 'advanced-high'
    else 'open' -- Existing rank code; displayed as Professional in the upcoming UI step.
  end;
end $$;

-- Internal helpers only. A later permission-checked engine consumes verified results.
revoke all on function core.cpc_rating_delta(numeric, numeric, integer, integer, integer) from public, anon, authenticated;
revoke all on function core.cpc_rating_points(numeric) from public, anon, authenticated;
revoke all on function core.cpc_rating_band_code(numeric) from public, anon, authenticated;

comment on function core.cpc_rating_delta(numeric, numeric, integer, integer, integer) is
  'CPC cpc-v1 raw match delta; valid played results only, team mean for doubles, first five played matches provisional. Private engine helper.';
comment on function core.cpc_rating_points(numeric) is
  'CPC cpc-v1 division-end clamp to 2.000-8.000 and rounding to three decimals; never initializes an unrated player.';
comment on function core.cpc_rating_band_code(numeric) is
  'CPC cpc-v1 canonical rank code for three-decimal points; NULL means unrated. Does not write member ranks.';
