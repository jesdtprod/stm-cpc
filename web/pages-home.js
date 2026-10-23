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
    href: "#/admin/payments",
    hint: (n) => n ? "Waiting for a decision." : "Nothing to verify.",
  },
  {
    key: "pending_bookings",
    label: "Bookings to approve",
    icon: "calendar",
    href: "#/admin/bookings",
    hint: (n) => n ? "Requests from members." : "No open requests.",
  },
  {
    key: "todays_bookings",
    label: "Today's bookings",
    icon: "clock",
    href: "#/admin/bookings",
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
      href: "#/bookings",
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
  function svgEl(tag, props = {}, ...children) {
    const el = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [key, val] of Object.entries(props)) {
      if (key === "href" || key === "xlink:href") {
        el.setAttributeNS("http://www.w3.org/1999/xlink", "xlink:href", val);
        el.setAttribute("href", val);
      } else {
        el.setAttribute(key, val);
      }
    }
    for (const child of children.flat()) {
      if (child instanceof Node) el.append(child);
    }
    return el;
  }

  // Vector equipment follows the green honeycomb faces and gold rims of the CPC crest.
  function createEquipmentScene() {
    const gradient = (id, stops) => svgEl("linearGradient", {
      id, x1: "0", y1: "0", x2: "1", y2: "1",
    }, ...stops.map(([offset, color]) => svgEl("stop", { offset, "stop-color": color })));
    const face = "M42 0H98Q140 0 140 44V139Q140 169 110 185L91 196H49L30 185Q0 169 0 139V44Q0 0 42 0Z";
    const defs = svgEl("defs", {},
      gradient("cpc-paddle-green", [["0%", "#245942"], ["48%", "#103b2c"], ["100%", "#061d17"]]),
      gradient("cpc-paddle-gold", [["0%", "#f6e8b0"], ["35%", "#c4a15e"], ["65%", "#f1d58d"], ["100%", "#8d6c32"]]),
      svgEl("radialGradient", { id: "cpc-ball-gold", cx: "32%", cy: "25%", r: "75%" },
        svgEl("stop", { offset: "0%", "stop-color": "#fff2a3" }),
        svgEl("stop", { offset: "55%", "stop-color": "#edcb42" }),
        svgEl("stop", { offset: "100%", "stop-color": "#aa7e13" })),
      svgEl("pattern", { id: "cpc-honeycomb", width: "22", height: "38", patternUnits: "userSpaceOnUse" },
        svgEl("path", { d: "M11 0 22 6.3V19L11 25.3 0 19V6.3ZM0 19 11 25.3V38M22 19 11 25.3", fill: "none", stroke: "#b8cb9a", "stroke-width": "1", opacity: ".28" })),
      svgEl("clipPath", { id: "cpc-paddle-face" }, svgEl("path", { d: face })));
    const paddle = (n, transform) => svgEl("g", { class: `cpc-racket cpc-racket-${n}` },
      svgEl("g", { transform },
        svgEl("rect", { x: "52", y: "182", width: "36", height: "100", rx: "12", fill: "#0a1915", stroke: "url(#cpc-paddle-gold)", "stroke-width": "3" }),
        ...[206, 218, 230, 242, 254, 266].map(y => svgEl("path", { d: `M55 ${y} 85 ${y - 8}`, stroke: "#536258", "stroke-width": "3" })),
        svgEl("path", { d: face, fill: "url(#cpc-paddle-green)", stroke: "#e8eadb", "stroke-width": "10" }),
        svgEl("path", { d: face, fill: "none", stroke: "url(#cpc-paddle-gold)", "stroke-width": "5" }),
        svgEl("path", { d: face, fill: "url(#cpc-honeycomb)", "clip-path": "url(#cpc-paddle-face)" }),
        svgEl("path", { d: "M18 54Q18 18 53 18H94", fill: "none", stroke: "#ffffff", opacity: ".2", "stroke-width": "3" }),
        svgEl("path", { d: "M55 159 70 144 85 159 70 174Z", fill: "none", stroke: "#dbc48a", "stroke-width": "2" })));
    const ball = (n, transform) => svgEl("g", { class: `cpc-ball cpc-ball-${n}` },
      svgEl("g", { transform },
        svgEl("circle", { r: "36", fill: "url(#cpc-ball-gold)", stroke: "#efdc83", "stroke-width": "1" }),
        ...[[0, 0, 6, 8], [-18, -14, 5, 7], [13, -22, 6, 4], [20, 12, 5, 7], [-13, 23, 6, 4], [-30, 5, 3, 7], [31, -9, 2, 6]].map(([cx, cy, rx, ry]) =>
          svgEl("ellipse", { cx, cy, rx, ry, fill: "#3e461b", stroke: "#d0a72d", "stroke-width": "1.5" }))));
    const art = svgEl("svg", { viewBox: "0 0 620 620", class: "cpc-equipment-art", "aria-hidden": "true", focusable: "false" },
      defs,
      svgEl("circle", { cx: "310", cy: "290", r: "240", class: "cpc-art-orbit" }),
      svgEl("circle", { cx: "310", cy: "290", r: "190", class: "cpc-art-orbit cpc-art-orbit-inner" }),
      svgEl("ellipse", { cx: "320", cy: "535", rx: "180", ry: "18", fill: "#000", opacity: ".16" }),
      paddle(1, "translate(83 184) rotate(-27 70 140) scale(1.04)"),
      paddle(3, "translate(365 151) rotate(28 70 140) scale(.83)"),
      ball(2, "translate(128 120) scale(.48)"),
      paddle(2, "translate(251 202) rotate(13 70 140) scale(1.13)"),
      ball(1, "translate(440 423) scale(1.1)"),
      ball(3, "translate(488 163) scale(.56)"));
    return h("div", { class: "cpc-equipment-scene" }, art);
  }

  function welcomePage() {
    const scene = createEquipmentScene();
    const motionButton = h("button", {
      class: "btn btn-ghost btn-sm cpc-motion-control",
      type: "button",
      "aria-pressed": "false",
      "aria-label": "Pause decorative paddle and ball animation",
      onClick: () => {
        const paused = scene.classList.toggle("is-paused");
        motionButton.setAttribute("aria-pressed", String(paused));
        motionButton.setAttribute("aria-label", `${paused ? "Resume" : "Pause"} decorative paddle and ball animation`);
        motionButton.textContent = paused ? "Resume motion" : "Pause motion";
      },
    }, "Pause motion");
    const heroSection = h("section", {
      class: "cpc-hero", "aria-labelledby": "cpc-welcome-title",
    }, h("div", { class: "cpc-landing-container" },
      h("div", { class: "cpc-hero-grid" },
        h("div", { class: "cpc-hero-content" },
          h("p", { class: "cpc-hero-badge" }, "Sultan Kudarat ? Philippines"),
          h("h1", { class: "cpc-hero-title", id: "cpc-welcome-title" },
            "A better place ", h("span", { class: "cpc-hero-title-accent" }, "to play.")),
          h("p", { class: "cpc-hero-club" }, "Capitol Pickleball Club"),
          h("p", { class: "cpc-hero-subtitle" },
            "Good rallies. Great company. A club to call your own. Bring your love of the game ? we?ll help you find your next match."),
          h("div", { class: "cpc-hero-actions" },
            h("a", { class: "btn btn-primary btn-lg", href: "#/signup" }, "Become a member", icon("chevr")),
            h("a", { class: "cpc-editorial-link", href: "#/booking" }, "Explore court availability", icon("chevr"))),
          h("p", { class: "cpc-hero-note" }, "Already a member? Sign in using the menu above.")),
        h("div", { class: "cpc-equipment-wrap" }, scene,
          h("div", { class: "cpc-equipment-caption" },
            h("span", {}, "The game brings us together."), motionButton))),
      h("div", { class: "cpc-club-strip", "aria-label": "The club experience" },
        h("span", {}, "One club. Every kind of player."),
        h("span", {}, "Social rallies"), h("span", {}, "Court reservations"), h("span", {}, "Club competition"))));

    // 3. Key Features Section
    const featuresSection = h(
      "section",
      {
        class: "cpc-section cpc-section-alt",
        id: "features",
        "aria-label": "Key Features",
      },
      h(
        "div",
        { class: "cpc-landing-container" },
        h(
          "div",
          { class: "cpc-section-header" },
          h("span", { class: "cpc-section-tag" }, "The club experience"),
          h(
            "h2",
            { class: "cpc-section-title" },
            "More than a match.",
          ),
          h(
            "p",
            { class: "cpc-section-desc" },
            "Make time for the game, connect with fellow players, and build your confidence on court.",
          ),
        ),
        h(
          "div",
          { class: "cpc-features-grid" },
          h(
            "div",
            { class: "cpc-feature-card" },
            h("div", { class: "cpc-feature-icon" }, icon("calendar")),
            h("h3", { class: "cpc-feature-title" }, "Your time on court"),
            h(
              "p",
              { class: "cpc-feature-text" },
              "Find a court and a time that works for you. Submit a reservation and follow its approval status from your account.",
            ),
          ),
          h(
            "div",
            { class: "cpc-feature-card" },
            h("div", { class: "cpc-feature-icon" }, icon("layers")),
            h(
              "h3",
              { class: "cpc-feature-title" },
              "Room to grow",
            ),
            h(
              "p",
              { class: "cpc-feature-text" },
              "Find your level with club-assigned categories and ranks. Enjoy a clear starting point as you develop your game.",
            ),
          ),
          h(
            "div",
            { class: "cpc-feature-card" },
            h("div", { class: "cpc-feature-icon" }, icon("layers")),
            h(
              "h3",
              { class: "cpc-feature-title" },
              "A competitive spirit",
            ),
            h(
              "p",
              { class: "cpc-feature-text" },
              "From friendly rallies to club events, discover more reasons to practise, connect, and enjoy the challenge.",
            ),
          ),
          h(
            "div",
            { class: "cpc-feature-card" },
            h("div", { class: "cpc-feature-icon" }, icon("user")),
            h(
              "h3",
              { class: "cpc-feature-title" },
              "A sense of belonging",
            ),
            h(
              "p",
              { class: "cpc-feature-text" },
              "Your member account keeps your club identity, bookings, and profile together, wherever the game takes you.",
            ),
          ),
        ),
      ),
    );

    // 5. How It Works (3 Steps)
    const howSection = h(
      "section",
      {
        class: "cpc-section cpc-section-alt",
        id: "how-it-works",
        "aria-label": "How It Works",
      },
      h(
        "div",
        { class: "cpc-landing-container" },
        h(
          "div",
          { class: "cpc-section-header" },
          h("span", { class: "cpc-section-tag" }, "Your first rally starts here"),
          h(
            "h2",
            { class: "cpc-section-title" },
            "Join. Reserve. Play.",
          ),
          h(
            "p",
            { class: "cpc-section-desc" },
            "A simple path from joining the club to stepping onto the court.",
          ),
        ),
        h(
          "div",
          { class: "cpc-steps-grid" },
          h(
            "div",
            { class: "cpc-step-card" },
            h("div", { class: "cpc-step-num" }, "01"),
            h("h3", { class: "cpc-step-title" }, "Join the club"),
            h(
              "p",
              { class: "cpc-step-text" },
              "Create your account and submit your profile. The club reviews new memberships before activating access.",
            ),
          ),
          h(
            "div",
            { class: "cpc-step-card" },
            h("div", { class: "cpc-step-num" }, "02"),
            h("h3", { class: "cpc-step-title" }, "Find your time"),
            h(
              "p",
              { class: "cpc-step-text" },
              "Once approved, choose an available court and time. Submit any required payment proof and wait for confirmation.",
            ),
          ),
          h(
            "div",
            { class: "cpc-step-card" },
            h("div", { class: "cpc-step-num" }, "03"),
            h("h3", { class: "cpc-step-title" }, "Make it a regular thing"),
            h(
              "p",
              { class: "cpc-step-text" },
              "Check your confirmed booking, bring your paddle, and enjoy your time on court. Your next good rally is waiting.",
            ),
          ),
        ),
      ),
    );

    // 8. FAQ Section
    const faqSection = h(
      "section",
      {
        class: "cpc-section",
        id: "faq",
        "aria-label": "A few things to know.",
      },
      h(
        "div",
        { class: "cpc-landing-container" },
        h(
          "div",
          { class: "cpc-section-header" },
          h("span", { class: "cpc-section-tag" }, "Before you play"),
          h(
            "h2",
            { class: "cpc-section-title" },
            "A few things to know.",
          ),
        ),
        h(
          "div",
          { class: "cpc-faq-list" },
          h(
            "details",
            { class: "cpc-faq-item", open: true },
            h(
              "summary",
              { class: "cpc-faq-summary" },
              "How do I reserve a court and submit payment?",
              icon("chevronDown"),
            ),
            h(
              "div",
              { class: "cpc-faq-body" },
              "After your membership is approved, sign in and open Book a court. Choose an available slot and submit your request. If payment proof is required, follow the booking instructions. Your reservation is confirmed after club approval.",
            ),
          ),
          h(
            "details",
            { class: "cpc-faq-item" },
            h(
              "summary",
              { class: "cpc-faq-summary" },
              "When is my membership active?",
              icon("chevronDown"),
            ),
            h(
              "div",
              { class: "cpc-faq-body" },
              "New accounts are reviewed by the club. Check your account status after signing in; booking access becomes available once your membership is approved.",
            ),
          ),
          h(
            "details",
            { class: "cpc-faq-item" },
            h(
              "summary",
              { class: "cpc-faq-summary" },
              "How do the player skill categories work?",
              icon("chevronDown"),
            ),
            h(
              "div",
              { class: "cpc-faq-body" },
              "The club assigns your starting category and rank. Rank changes follow club rules and are applied after an event division is finalized, rather than after each match.",
            ),
          ),
          h(
            "details",
            { class: "cpc-faq-item" },
            h(
              "summary",
              { class: "cpc-faq-summary" },
              "Do I need an account to reserve a court?",
              icon("chevronDown"),
            ),
            h(
              "div",
              { class: "cpc-faq-body" },
              "Court reservations are for approved members. You can explore the public court schedule before joining, then create an account to request membership.",
            ),
          ),
        ),
      ),
    );

    const footerSection = h("footer", { class: "cpc-footer" },
      h("div", { class: "cpc-landing-container" },
        h("div", { class: "cpc-footer-grid" },
          h("a", { class: "cpc-footer-brand", href: "#/", "aria-label": "Capitol Pickleball Club home" },
            h("img", { src: "icons/cpc-logo.png", alt: "", width: "56", height: "56", loading: "lazy" }),
            "Capitol Pickleball Club"),
          h("p", { class: "cpc-footer-story" }, "Rooted in Sultan Kudarat. United by the game.")),
        h("div", { class: "cpc-footer-bottom" },
          h("span", {}, "Capitol Pickleball Club"),
          h("span", {}, "Sultan Kudarat, Philippines"))));

    return h(
      "div",
      { class: "cpc-landing" },
      heroSection,
      featuresSection,
      howSection,
      faqSection,
      footerSection,
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
