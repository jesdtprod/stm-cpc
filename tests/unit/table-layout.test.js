import assert from "node:assert/strict";
import {
  tableColumn,
  tableMinWidth,
  tableTracks,
} from "../../web/lib/table-layout.js";

Deno.test("table layout: action and money alignments match for headings and data", () => {
  assert.equal(tableColumn({ key: "actions", align: "left" }).align, "center");
  assert.equal(tableColumn({ key: "fee", kind: "money" }).align, "right");
  assert.equal(
    tableColumn({ key: "status", label: "Status" }).skeleton,
    "badge",
  );
});

Deno.test("table layout: variable action groups reserve 36px controls with 8px gaps", () => {
  const columns = [{ key: "member", label: "Member" }, {
    key: "actions",
    actionCount: 4,
  }].map(tableColumn);
  assert.equal(tableTracks(columns)[1], "204px");
  assert.equal(tableMinWidth(columns), 384);
  assert.equal(columns[0].skeleton, "member");
  assert.equal(columns[1].skeleton, "actions");
});

Deno.test("table layout: ordering stays compact while text columns receive available width", () => {
  const columns = [{ key: "order", label: "Order", align: "right" }, {
    key: "name",
    label: "Category",
  }].map(tableColumn);
  assert.equal(tableTracks(columns)[0], "80px");
  assert.equal(tableMinWidth(columns), 260);
  assert.equal(tableTracks(columns)[1], "minmax(180px, 1.5fr)");
});

Deno.test("table layout: a single action reserves enough width for its one-line heading", () => {
  const columns = [
    tableColumn({ key: "actions", label: "Action", actionCount: 1 }),
  ];
  assert.equal(tableTracks(columns)[0], "88px");
  assert.equal(tableMinWidth(columns), 88);
});
