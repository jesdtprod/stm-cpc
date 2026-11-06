// Form feedback only. The database repeats these checks using the saved match rule.
export function finishedGamesError(games, rule) {
  if (!games.length) return "Enter at least one completed game.";
  const target = Number(rule.points_per_game);
  const winBy = Number(rule.win_by ?? 2);
  const cap = rule.point_cap == null ? null : Number(rule.point_cap);
  for (const [index, { a, b }] of games.entries()) {
    if (![a, b].every((score) => Number.isInteger(score) && score >= 0 && score <= 99)) {
      return `Game ${index + 1}: enter whole-number scores from 0 to 99.`;
    }
    const high = Math.max(a, b);
    const low = Math.min(a, b);
    if (high < target) return `Game ${index + 1}: one side must reach at least ${target} points before saving.`;
    if (cap != null && high > cap) return `Game ${index + 1}: scores cannot exceed the ${cap}-point cap.`;
    const valid = cap != null && high === cap ? high > low
      : high === target ? high - low >= winBy : high - low === winBy;
    if (!valid) return `Game ${index + 1}: the winning score must meet the win-by-${winBy} rule${cap == null ? "" : ` or the ${cap}-point cap`}.`;
  }
  return null;
}
