// One column definition for table headings, data, and loading placeholders.
export const isActionColumn = (column) =>
  ["action", "actions"].includes(column.key) ||
  /^actions?$/i.test(column.label ?? "");

export function tableColumn(column) {
  const actions = isActionColumn(column);
  const key = `${column.key} ${column.label}`.toLowerCase();
  const money = column.kind === "money";
  const wide =
    /name|member|contact|email|court|player|team|issue|description|reason/.test(
      key,
    );
  const date = /date|when|created|joined|starts|ends|imported/.test(key);
  return {
    ...column,
    actions,
    align: actions ? "center" : money ? "right" : column.align ?? "left",
    actionCount: Math.max(1, column.actionCount ?? 2),
    minWidth: actions ? 0 : column.minWidth ?? (wide ? 180 : date ? 160 : 120),
    fraction: wide ? 1.5 : 1,
    skeleton: column.skeleton ??
      (actions
        ? "actions"
        : money
        ? "text"
        : /^(name|member)$/.test(column.key)
        ? "member"
        : /status/.test(key)
        ? "badge"
        : date
        ? "date"
        : "text"),
  };
}

export function tableTracks(columns) {
  return columns.map((column) =>
    column.actions
      ? `${36 * column.actionCount + 8 * (column.actionCount - 1) + 36}px`
      : `minmax(${column.minWidth}px, ${column.fraction}fr)`
  );
}

export function tableMinWidth(columns) {
  return columns.reduce(
    (total, column) =>
      total +
      (column.actions
        ? 36 * column.actionCount + 8 * (column.actionCount - 1) + 36
        : column.minWidth),
    0,
  );
}
