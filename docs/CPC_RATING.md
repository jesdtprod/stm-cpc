# CPC points rating (cpc-v1)

Accepted direction: replace automatic H/L level movement with a numerical CPC
rating. This is an independent club rating, not an official DUPR score or an
implementation of DUPR's proprietary formula.

## Delivery and current status

PLAN 8.4a supplies private calculation helpers and database tests only. The active
rank engine still uses existing rank rules until the finalization integration
step is implemented and verified. No existing member is assigned points by this
foundation migration.

PLAN 8.4b (migration 1840) adds storage: `member_cpc_ratings` (current points,
NULL = unrated, eligible match count), append-only `member_cpc_rating_history`
(before/after per change), `event_participant_cpc_ratings` (guest assessments)
and `division_cpc_rating_snapshots` (frozen starting points, prior counts and team
strength per player, guests included). `initialize_member_cpc_ratings` only adds
unrated rows; existing ranks are untouched. Finalization does not use them yet.

PLAN 8.4c (migration 1850) adds the engine behind the setting
`ranks.cpc_points_enabled` (default off). Inputs are frozen at the draw; a division with
frozen inputs is rated by points at finalization and on corrections, and others keep
the legacy rank rules. Eligible matches are completed, played matches with games
(any stage); forfeits, byes and voided matches are excluded. Match order for the
provisional count is stage, round, match number. Each correction reverses a changed
player's earlier delta relative to their current points, so later assessments survive.
PLAN 8.4e (migration 1890): every player has two ratings, Singles and Doubles, each 2.000-8.000 with
its own history and provisional count. A singles division updates only Singles and a doubles division (mixed
included) only Doubles; a player needs an assessed rating for the division's format before a draw. The club
rank follows the higher of the two ratings that exist. Screens say "Singles Rating" and "Doubles Rating".
PLAN 8.4f (migrations 1900, 1910): the Club Rank is automatic: Classification(MAX(Singles, Doubles)), NR
ignored, recalculated whenever a rating changes (assessment, a member's first submission, division finalization), with rank
history only when the classification changes. It cannot be set by hand while ratings are on. A member may submit first
Singles and Doubles ratings once; afterwards only administrators change them. Event registration checks the rating for
the division's format (Singles or Doubles), never the Club Rank. The Member Profile card shows Singles, Doubles and Club
Rank (with the rating it is based on).

Only an unrated player is labelled provisional ("Unrated · Provisional Beginner Low"); an assessed
rating shows as a normal rating with its matches played. The faster movement during the first five matches
stays in the calculation but is not shown as a label.

PLAN 8.4d (migrations 1880, web/cpc-points.js): the Ranking, Home and Member Details screens show
points to three decimals with Provisional (first five matches) and Unrated labels, plus the points
history; staff with ranks.override assess starting points. A member sees only their own points
(enforced in the database). Turning points on is refused until every active member has a points
record (Prepare Members); the setting is `ranks.cpc_points_enabled`.

Tested (1850, 1851): provisional factors, retries, corrections, a guest opponent, doubles
from team strengths, two divisions from the same frozen start, the 8.000/2.000 limits and
the event opt-out. Not tested: a guest as a doubles partner, and two transactions
finalizing at the same instant.

## Starting points and rank bands

- Unrated is NULL, never zero. Display `Unrated` with `Provisional Beginner Low`
  as smaller subtext; this registration fallback is not a verified skill rating.
- A genuine beginner starts at 2.000 when the rating is initialized. Experienced
  newcomers need an admin-assigned provisional starting value, with a reason,
  permission `ranks.override`, and an idempotent audit record. A self-assessment
  must not become official points automatically.
- Existing ranked members require an explicit migration/assessment policy before
  activation; do not silently reset them to 2.000 or infer an exact score from a
  broad rank band. Historical results and rank history remain intact.
- Rated points are stored to three decimals, bounded to 2.000–8.000. First five
  eligible played matches are provisional; the sixth uses the established factor.
- Use these bands after rounding the final points:

| Rank | Points |
| --- | --- |
| Beginner Low | 2.000–2.249 |
| Beginner High | 2.250–2.499 |
| Novice Low | 2.500–2.749 |
| Novice High | 2.750–2.999 |
| Intermediate Low | 3.000–3.499 |
| Intermediate High | 3.500–3.999 |
| Advanced Low | 4.000–4.499 |
| Advanced High | 4.500–4.999 |
| Professional | 5.000–8.000 |

The Professional tier keeps the existing `open` rank code and ID; the UI label
will change in the screen step. The current database label is Open/Professional.

## Calculation

Initial club constants: scale = 0.500, established factor = 0.100, provisional
factor = 0.200. These are CPC design choices, not claims about DUPR's constants.
Changing them later requires a new algorithm version; old history must retain
the formula version and inputs used.

```
team_strength = own starting points (singles), or mean of partners (doubles)
expected_share = 1 / (1 + 10 ^ ((opponent_strength - team_strength) / 0.500))
actual_share = points_scored / (points_scored + points_conceded)
factor = 0.200 if prior eligible matches < 5, otherwise 0.100
match_delta = factor * (actual_share - expected_share)
division_points = round(clamp(starting_points + sum(match_deltas), 2, 8), 3)
```

For multi-game matches, sum the official rally points across the played games,
not games won. Each doubles partner uses the same team performance but their own
provisional/established factor and receives their own delta. Points are a skill
estimate: a close loss to stronger opposition can gain points, while an
underperforming win against weaker opposition can lose points.

An established 3.000 player beating an equally rated opponent 11–9 gains 0.005.
A provisional player gets 0.010 for the same performance. H/L placement itself
adds no bonus or penalty. There is no fixed promotion for an H champion.

## Finalization integration requirements (next steps)

- Count eligible, completed, actually played matches from Round 1, H and L.
  Exclude byes, walkovers, forfeits, retirements and voided/cancelled matches,
  including any administrative award scores. Only verified complete results
  enter the calculation; the helper alone cannot establish eligibility.
- Freeze each participant's starting points and prior eligible match count when
  the division starts. Increase the effective count in stable played-match order
  for provisional factors; keep the strength snapshots fixed for this division.
  Count each match once, not each game. Apply the combined adjustment only on
  finalization, even if a member crosses five played matches during the division.
- Record algorithm version, participant identities (including guests), starting
  points, strengths, scores, prior counts and deltas in append-only history.
  Do not fabricate guest strengths: require assessed points for every player
  before a points-rated division starts. Guests do not receive member rank credit.
- Preserve the event's CPC opt-out. Finalization retries cannot duplicate points
  or played-match counts. Lock member rating rows in stable order, and define
  how overlapping divisions use their frozen inputs without losing updates.
- Corrections must evaluate changed scores even when the winner is unchanged.
  Write reversing and replacement entries, preserve audit history and later
  independent adjustments; do not merely rerun legacy placement-change logic.
- Map official final points to the matching active rank in the same club, checking
  categories/ladders and exact band coverage. Reject missing, overlapping or
  incompatible bands. Check permission codes in the database for every write.
- Deliver points, provisional status and before/after changes in the ranking,
  profile, member details and history screens. Keep external DUPR independent.

## Verification for 8.4a

Apply only migration `1830_cpc_rating_calculation.sql` using the project's normal
migration process, then run:

```powershell
deno task db:test 1830_cpc_rating_calculation
```

The test command does not install migrations. A `function
core.cpc_rating_band_code(numeric) does not exist` error means the linked database
is missing migration 1830; apply it before rerunning the suite. Migration 1830
was applied to the linked development project on 2026-10-28, with 58/58 tests
passing against the installed helpers.

The pgTAP suite covers all band endpoints, unrated/invalid values, precision,
clamping, score margin, strength differences, provisional transitions, doubles
means, arithmetic limits, and denied browser/anonymous execution. Its transaction
rolls back. Passing this suite verifies the calculation foundation, not activation
of the points system.
