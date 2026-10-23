import {
  badge,
  button,
  dataTable,
  field,
  h,
  kpiCard,
  openModal,
  pageHeader,
  pagination,
  toast,
  toolbar,
} from "./ui.js";

export function homePage() {
  return h(
    "div",
    { class: "page" },
    pageHeader({
      icon: "home",
      eyebrow: "Welcome",
      title: "Capitol Pickleball Club",
      description:
        "Sign-in, bookings, ranks and tournaments arrive in later steps.",
    }),
    h(
      "div",
      { class: "kpis" },
      kpiCard("Members", "—"),
      kpiCard("Bookings today", "—"),
      kpiCard("Open events", "—"),
    ),
  );
}

// Fake data only.
const FAKE = Array.from({ length: 23 }, (_, i) => ({
  id: `Demo ${i + 1}`,
  name: `Sample Player ${i + 1}`,
  level: i % 2 ? "Novice High" : "Novice Low",
  status: i % 3 === 0 ? "pending" : "active",
  fee: 100 * (i + 1),
}));

const schema = {
  columns: [
    {
      key: "name",
      label: "Member",
      render: (r) => h("span", {}, r.name, h("span", { class: "sub" }, r.id)),
    },
    { key: "level", label: "Rank" },
    {
      key: "status",
      label: "Status",
      render: (r) =>
        badge(r.status, r.status === "active" ? "success" : "warning"),
    },
    { key: "fee", label: "Fee", kind: "money", align: "right" },
  ],
  actions: [
    { label: "Edit record", icon: "edit", onClick: (r) => openEdit(r) },
    {
      label: "Remove record",
      icon: "trash",
      onClick: (r) => toast(`Remove ${r.name} (demo only)`),
    },
  ],
};

function openEdit(row) {
  openModal({
    title: "Edit record",
    eyebrow: "Demo",
    description: "Shared modal anatomy: header, body, footer.",
    icon: "edit",
    body: [
      field({
        id: "demo-name",
        label: "Name",
        value: row.name,
        required: true,
      }),
      field({ id: "demo-note", label: "Note", hint: "Optional." }),
    ],
    onConfirm: () => toast("Saved (demo only)"),
  });
}

export function componentsPage() {
  const pageSize = 5;
  const state = { page: 1, q: "", mode: "ready" };
  const host = h("div", { class: "page" });
  const tableHost = h("div", {});

  const rows = () =>
    FAKE.filter((r) => r.name.toLowerCase().includes(state.q.toLowerCase()));

  const draw = () => {
    const all = rows();
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize));
    state.page = Math.min(state.page, maxPage);
    const slice = all.slice((state.page - 1) * pageSize, state.page * pageSize);
    tableHost.replaceChildren(
      dataTable({
        schema,
        rows: slice,
        state: state.mode,
        ariaLabel: "Members demo",
        hasFilters: state.q !== "",
        emptyTitle: "No members found",
        emptyText: "No members exist yet.",
        onRetry: () => {
          state.mode = "ready";
          draw();
        },
        onReset: () => {
          state.q = "";
          state.page = 1;
          document.getElementById("search").value = "";
          draw();
        },
      }),
      state.mode === "ready"
        ? pagination({
          page: state.page,
          pageSize,
          total: all.length,
          onPage: (p) => {
            state.page = p;
            draw();
          },
        })
        : null,
    );
  };

  const modeButton = (label, mode) =>
    button({
      label,
      onClick: () => {
        state.mode = mode;
        draw();
      },
    });

  host.append(
    pageHeader({
      icon: "grid",
      eyebrow: "Foundation",
      title: "Components",
      description: "Shared components shown with fake data.",
      actions: [
        button({
          label: "Open modal",
          variant: "primary",
          icon: "plus",
          onClick: () => openEdit(FAKE[0]),
        }),
      ],
    }),
    toolbar({
      searchLabel: "Search members",
      onSearch: (v) => {
        state.q = v;
        state.page = 1;
        draw();
      },
      actions: [
        modeButton("Loading", "loading"),
        modeButton("Error", "error"),
        modeButton("Ready", "ready"),
      ],
    }),
    tableHost,
  );
  draw();
  return host;
}

export function notFoundPage() {
  return h(
    "div",
    { class: "page" },
    pageHeader({
      icon: "alert",
      title: "Page not found",
      description: "That page does not exist.",
    }),
    h("a", { href: "#/" }, "Back to home"),
  );
}
