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
  const compact = /^(order|sort_order|position|priority)$/.test(
    column.key,
  );
  const date = /date|when|created|joined|starts|ends|imported/.test(key);
  return {
    ...column,
    actions,
    align: actions ? "center" : money ? "right" : column.align ?? "left",
    actionCount: Math.max(1, column.actionCount ?? 2),
    fixedWidth: column.width ?? (compact ? 80 : null),
    minWidth: actions ? 0 : column.width ??
      (compact ? 80 : column.minWidth ?? (wide ? 180 : date ? 160 : 120)),
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

// Leave room for the Action heading as well as the icon group and cell padding.
const actionWidth = (column) =>
  Math.max(88, 36 * column.actionCount + 8 * (column.actionCount - 1) + 36);

export function tableTracks(columns) {
  return columns.map((column) =>
    column.actions
      ? `${actionWidth(column)}px`
      : column.fixedWidth
      ? `${column.fixedWidth}px`
      : `minmax(${column.minWidth}px, ${column.fraction}fr)`
  );
}

export function tableMinWidth(columns) {
  return columns.reduce(
    (total, column) =>
      total +
      (column.actions ? actionWidth(column) : column.minWidth),
    0,
  );
}
