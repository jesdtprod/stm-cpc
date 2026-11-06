import assert from "node:assert/strict";
import { finishedGamesError } from "../../web/lib/score-validation.js";

const rule = { points_per_game: 11, win_by: 2 };
Deno.test("score entry: reject incomplete, negative, fractional and nonnumeric scores", () => {
  for (const games of [[], [{ a: 10, b: 8 }], [{ a: -1, b: 11 }], [{ a: 11.5, b: 8 }], [{ a: "11", b: 8 }], [{ a: NaN, b: 8 }], [{ a: 100, b: 8 }]]) {
    assert.ok(finishedGamesError(games, rule));
  }
});
Deno.test("score entry: respect target, win-by, deuce and point cap", () => {
  assert.equal(finishedGamesError([{ a: 11, b: 8 }], rule), null);
  assert.equal(finishedGamesError([{ a: 12, b: 10 }], rule), null);
  assert.ok(finishedGamesError([{ a: 11, b: 10 }], rule));
  assert.ok(finishedGamesError([{ a: 13, b: 10 }], rule));
  assert.ok(finishedGamesError([{ a: 11, b: 8 }], { ...rule, points_per_game: 15 }));
  assert.equal(finishedGamesError([{ a: 15, b: 14 }], { ...rule, point_cap: 15 }), null);
  assert.ok(finishedGamesError([{ a: 16, b: 14 }], { ...rule, point_cap: 15 }));
});
