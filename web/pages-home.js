// Role-aware home (PLAN 3.6). The figures come from the my_dashboard() call, which only returns the
// sections the caller is allowed to see; this page just draws what it receives.
//   member : own rank, upcoming bookings, event registrations, unread notices
//   staff  : approvals, payment proofs, bookings to approve, today's bookings, events in progress
import { h, icon, pageHeader } from "./ui.js";
import { formatDateTime } from "./lib/dates.js";

// href is only set where the page already exists; the rest are plain figures until their steps arrive.
const STAFF_CARDS = [
  {
    key: "pending_members",
    label: "Members waiting for approval",
    icon: "user",
    href: "#/admin/members",
    hint: (n) =>
      n ? "Open the Members page to review them." : "No one is waiting.",
  },
  {
    key: "pending_proofs",
    label: "Payment proofs to verify",
    icon: "file",
    hint: (n) => n ? "Waiting for a decision." : "Nothing to verify.",
  },
  {
    key: "pending_bookings",
    label: "Bookings to approve",
    icon: "calendar",
    hint: (n) => n ? "Requests from members." : "No open requests.",
  },
  {
    key: "todays_bookings",
    label: "Today's bookings",
    icon: "clock",
    hint: () => "Confirmed for today.",
  },
  {
    key: "active_events",
    label: "Events in progress",
    icon: "layers",
    hint: () => "Open for registration or running.",
  },
];

function statCard({ label, value, hint, iconName, href, attention = false }) {
  const body = [
    h(
      "div",
      { class: "home-card-top" },
      h("span", { class: "home-card-label" }, label),
      h("span", { class: "badge-icon" }, icon(iconName)),
    ),
    h("div", { class: "home-card-value" }, value),
    hint ? h("div", { class: "home-card-hint muted" }, hint) : null,
  ];
  const cls = `card home-card${attention ? " is-attention" : ""}`;
  return href
    ? h("a", { class: `${cls} is-link`, href }, ...body)
    : h("div", { class: cls }, ...body);
}

function memberCards(m) {
  const next = m.next_booking
    ? `Next: ${m.next_booking.court}, ${
      formatDateTime(m.next_booking.starts_at)
    }${
      m.next_booking.status === "pending_approval"
        ? " (waiting for approval)"
        : ""
    }`
    : "Nothing booked yet.";
  return [
    statCard({
      label: "Current rank",
      value: m.rank?.name ?? "Not ranked yet",
      hint: m.rank ? m.rank.category : "The club sets your starting rank.",
      iconName: "layers",
    }),
    statCard({
      label: "Upcoming bookings",
      value: m.upcoming_bookings,
      hint: next,
      iconName: "calendar",
    }),
    statCard({
      label: "Event registrations",
      value: m.open_registrations,
      hint: m.open_registrations
        ? "Events you have joined or are waiting for."
        : "You have not joined an event yet.",
      iconName: "layers",
    }),
    statCard({
      label: "Notices",
      value: m.unread_notices,
      hint: m.unread_notices ? "Unread" : "You are up to date.",
      iconName: "inbox",
    }),
  ];
}

function section(title, description, cards) {
  return h(
    "section",
    { class: "home-section", "aria-label": title },
    h("h2", { class: "home-section-title" }, title),
    description ? h("p", { class: "muted" }, description) : null,
    h("div", { class: "home-grid" }, ...cards),
  );
}

function dashboardView(data) {
  const parts = [];
  const staff = STAFF_CARDS.filter((c) => data[c.key] != null).map((c) =>
    statCard({
      label: c.label,
      value: data[c.key],
      hint: c.hint(Number(data[c.key])),
      iconName: c.icon,
      href: c.href,
      attention: c.key !== "todays_bookings" && c.key !== "active_events" &&
        Number(data[c.key]) > 0,
    })
  );
  if (staff.length) {
    parts.push(
      section(
        "Needs your attention",
        "What the club is waiting on today.",
        staff,
      ),
    );
  }
  if (data.member) {
    parts.push(
      section(
        "Your club",
        "Your own bookings, events and rank.",
        memberCards(data.member),
      ),
    );
  }
  if (!parts.length) {
    parts.push(
      h(
        "div",
        { class: "card" },
        h(
          "p",
          {},
          "There is nothing to show here yet. Your menu has the pages you can open.",
        ),
      ),
    );
  }
  return parts;
}

function loadingView() {
  return h(
    "div",
    { class: "home-grid", "aria-busy": "true", "aria-label": "Loading" },
    ...[1, 2, 3, 4].map(() =>
      h(
        "div",
        { class: "card home-card is-loading" },
        h("span", { class: "sk-line" }),
        h("span", { class: "sk-line sk-wide" }),
        h("span", { class: "sk-line sk-short" }),
      )
    ),
  );
}

export function createHomePages({ session, api }) {
  function welcomePage() {
    return h(
      "div",
      { class: "page" },
      pageHeader({
        icon: "home",
        eyebrow: "Welcome",
        title: "Capitol Pickleball Club",
        description: "Book courts, join events and follow your rank.",
      }),
      h(
        "div",
        { class: "card home-welcome" },
        h("img", {
          class: "home-logo",
          src: "icons/cpc-logo.png",
          alt: "",
          width: "96",
          height: "96",
        }),
        h(
          "p",
          {},
          "Sign in with your member ID, or create an account if you are new to the club.",
        ),
        h(
          "div",
          { class: "actions" },
          h("a", { class: "btn btn-primary", href: "#/signin" }, "Sign in"),
          h(
            "a",
            { class: "btn btn-secondary", href: "#/signup" },
            "Join the club",
          ),
        ),
      ),
    );
  }

  function gatePage(gate) {
    const text = {
      password_change: [
        "Choose your own password to continue.",
        "#/password",
        "Change password",
      ],
      pending: [
        "Your account is waiting for approval. We will let you know when it is ready.",
        "#/pending",
        "See account status",
      ],
    }[gate] ??
      [
        "Your account cannot use the club pages right now. Please contact the club.",
        null,
        null,
      ];
    return h(
      "div",
      { class: "page" },
      pageHeader({
        icon: "home",
        eyebrow: "Welcome",
        title: "Capitol Pickleball Club",
      }),
      h(
        "div",
        { class: "card home-welcome" },
        h("p", {}, text[0]),
        text[1]
          ? h("a", { class: "btn btn-primary", href: text[1] }, text[2])
          : null,
      ),
    );
  }

  function homePage() {
    const state = session.getState();
    if (state.status !== "signed_in") return welcomePage();
    if (state.gate) return gatePage(state.gate);

    const name = (state.access?.display_name ?? "").split(/\s+/)[0];
    const host = h("div", { class: "home-body" }, loadingView());
    const header = pageHeader({
      icon: "home",
      eyebrow: "Home",
      title: name ? `Welcome, ${name}` : "Welcome",
      description: state.access?.member_no
        ? `Member ID ${state.access.member_no}`
        : null,
    });
    const page = h("div", { class: "page" }, header, host);

    async function load() {
      host.replaceChildren(loadingView());
      try {
        const data = await api.rpc("my_dashboard");
        if (!page.isConnected && !host.isConnected) return;
        host.replaceChildren(...dashboardView(data ?? {}));
        const eyebrow = header.querySelector(".eyebrow");
        if (eyebrow && data?.role_name) eyebrow.textContent = data.role_name;
      } catch (error) {
        host.replaceChildren(
          h(
            "div",
            { class: "card home-error", role: "alert" },
            h("p", {}, error?.message ?? "We could not load your home page."),
            h(
              "button",
              { class: "btn btn-secondary", type: "button", onClick: load },
              icon("refresh"),
              "Try again",
            ),
          ),
        );
      }
    }
    load();
    return page;
  }

  return { homePage };
}
