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
  function renderMemberBadges(target, badges, fallbackInitials) {
    const initials = Array.isArray(badges)
      ? badges
        .slice(0, 15)
        .map((badge) =>
          String(badge?.initials ?? "")
            .replace(/[^a-z]/gi, "")
            .slice(0, 2)
            .toUpperCase()
        )
        .filter(Boolean)
      : [];
    const visibleInitials = initials.length ? initials : [
      String(fallbackInitials ?? "C").replace(/[^a-z]/gi, "").slice(0, 2)
        .toUpperCase() || "C",
    ];

    target.replaceChildren(
      ...visibleInitials.map((initial) =>
        h("span", { class: "cpc-member-account" }, initial)
      ),
    );
    target.hidden = false;
  }

  async function loadClubMemberCount(target, accountIndicators) {
    try {
      const stats = await api.rpc("club_home_stats");
      const count = Number(stats?.active_members);
      if (!target.isConnected || !Number.isSafeInteger(count) || count < 0) {
        return;
      }
      target.textContent = `${
        new Intl.NumberFormat("en-PH").format(count)
      } Active Club Member${count === 1 ? "" : "s"}`;
      const initials = String(stats?.member_initials ?? "C")
        .replace(/[^a-z]/gi, "")
        .slice(0, 2)
        .toUpperCase();
      renderMemberBadges(accountIndicators, stats?.member_badges, initials);
    } catch {
      if (target.isConnected) target.textContent = "Active club members";
    }
  }

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

  function createCourtWatermarkSvg() {
    return svgEl(
      "svg",
      {
        class: "cpc-hero-court-watermark",
        viewBox: "0 0 900 420",
        fill: "none",
        "aria-hidden": "true",
      },
      svgEl("rect", {
        x: "30",
        y: "30",
        width: "840",
        height: "360",
        rx: "8",
        stroke: "#163827",
        "stroke-width": "1.5",
        "stroke-opacity": "0.45",
      }),
      svgEl("line", {
        x1: "450",
        y1: "15",
        x2: "450",
        y2: "405",
        stroke: "#DFB756",
        "stroke-width": "1.5",
        "stroke-opacity": "0.35",
        "stroke-dasharray": "6 4",
      }),
      svgEl("line", {
        x1: "316",
        y1: "30",
        x2: "316",
        y2: "390",
        stroke: "#234735",
        "stroke-width": "1.2",
        "stroke-opacity": "0.45",
      }),
      svgEl("line", {
        x1: "584",
        y1: "30",
        x2: "584",
        y2: "390",
        stroke: "#234735",
        "stroke-width": "1.2",
        "stroke-opacity": "0.45",
      }),
      svgEl("line", {
        x1: "30",
        y1: "210",
        x2: "316",
        y2: "210",
        stroke: "#163827",
        "stroke-width": "1.2",
        "stroke-opacity": "0.45",
      }),
      svgEl("line", {
        x1: "584",
        y1: "210",
        x2: "870",
        y2: "210",
        stroke: "#163827",
        "stroke-width": "1.2",
        "stroke-opacity": "0.45",
      }),
      svgEl("circle", {
        cx: "30",
        cy: "30",
        r: "3",
        fill: "#DFB756",
        "fill-opacity": "0.3",
      }),
      svgEl("circle", {
        cx: "870",
        cy: "30",
        r: "3",
        fill: "#DFB756",
        "fill-opacity": "0.3",
      }),
      svgEl("circle", {
        cx: "30",
        cy: "390",
        r: "3",
        fill: "#DFB756",
        "fill-opacity": "0.3",
      }),
      svgEl("circle", {
        cx: "870",
        cy: "390",
        r: "3",
        fill: "#DFB756",
        "fill-opacity": "0.3",
      }),
    );
  }

  function setupConvexPatternCanvas(canvas, landingEl, watermarkEl) {
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const STEP = 60;
    const RADIUS = 180;
    const RADIUS_SQ = RADIUS * RADIUS;
    const EASE = 0.08;

    let width = 0;
    let height = 0;
    let targetX = -9999;
    let targetY = -9999;
    let currentX = -9999;
    let currentY = -9999;
    let targetStrength = 0;
    let currentStrength = 0;
    let animId = null;
    let hasConnected = false;

    function resize() {
      const rect = canvas.getBoundingClientRect();
      width = rect.width;
      height = rect.height;
      if (width === 0 || height === 0) return;
      const dpr = globalThis.devicePixelRatio || 1;
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      draw();
    }

    function warp(x, y) {
      const dx = x - currentX;
      const dy = y - currentY;
      const distSq = dx * dx + dy * dy;
      if (distSq >= RADIUS_SQ || currentStrength <= 0.0005) {
        return [x, y];
      }
      const dist = Math.sqrt(distSq);
      if (dist < 0.0001) return [x, y];
      const r = dist / RADIUS; // 0 <= r < 1
      // Convex lens formula: C1 smooth at boundary
      const factor = 0.44 * (1 - r * r) * (1 - r * r) * currentStrength;
      return [x + dx * factor, y + dy * factor];
    }

    function draw() {
      if (width === 0 || height === 0) return;
      ctx.clearRect(0, 0, width, height);

      const hasConvex = currentStrength > 0.0005;
      const xMin = hasConvex ? currentX - RADIUS : -9999;
      const xMax = hasConvex ? currentX + RADIUS : -9999;
      const yMin = hasConvex ? currentY - RADIUS : -9999;
      const yMax = hasConvex ? currentY + RADIUS : -9999;

      // 1. Diagonal Court Net Pattern (dashed)
      ctx.beginPath();
      ctx.setLineDash([3, 5]);
      ctx.strokeStyle = "rgba(17, 41, 28, 0.35)";
      ctx.lineWidth = 0.75;
      for (let gx = 0; gx < width + STEP; gx += STEP) {
        for (let gy = 0; gy < height + STEP; gy += STEP) {
          const x1 = gx;
          const y1 = gy + STEP;
          const x2 = gx + STEP;
          const y2 = gy;
          const inLens = hasConvex &&
            x2 >= xMin && x1 <= xMax &&
            y1 >= yMin && y2 <= yMax;
          if (!inLens) {
            ctx.moveTo(x1, y1);
            ctx.lineTo(x2, y2);
          } else {
            const [wx1, wy1] = warp(x1, y1);
            ctx.moveTo(wx1, wy1);
            for (let t = 0.15; t <= 1; t += 0.15) {
              const [wx, wy] = warp(
                x1 + (x2 - x1) * t,
                y1 + (y2 - y1) * t,
              );
              ctx.lineTo(wx, wy);
            }
          }
        }
      }
      ctx.stroke();
      ctx.setLineDash([]);

      // 2. Regulation Court Grid Lines (vertical & horizontal)
      ctx.beginPath();
      ctx.strokeStyle = "rgba(22, 56, 39, 0.45)";
      ctx.lineWidth = 1;

      // Vertical lines
      for (let gx = 0; gx <= width + STEP; gx += STEP) {
        if (!hasConvex || gx < xMin || gx > xMax) {
          ctx.moveTo(gx, 0);
          ctx.lineTo(gx, height);
        } else {
          ctx.moveTo(gx, 0);
          const yEnter = Math.max(0, yMin);
          const yExit = Math.min(height, yMax);
          if (yEnter > 0) ctx.lineTo(gx, yEnter);
          for (let gy = yEnter; gy <= yExit; gy += 6) {
            const [wx, wy] = warp(gx, gy);
            ctx.lineTo(wx, wy);
          }
          if (yExit < height) ctx.lineTo(gx, height);
        }
      }

      // Horizontal lines
      for (let gy = 0; gy <= height + STEP; gy += STEP) {
        if (!hasConvex || gy < yMin || gy > yMax) {
          ctx.moveTo(0, gy);
          ctx.lineTo(width, gy);
        } else {
          ctx.moveTo(0, gy);
          const xEnter = Math.max(0, xMin);
          const xExit = Math.min(width, xMax);
          if (xEnter > 0) ctx.lineTo(xEnter, gy);
          for (let gx = xEnter; gx <= xExit; gx += 6) {
            const [wx, wy] = warp(gx, gy);
            ctx.lineTo(wx, wy);
          }
          if (xExit < width) ctx.lineTo(width, gy);
        }
      }
      ctx.stroke();

      // 3. Regulation Center Crosses
      ctx.beginPath();
      ctx.strokeStyle = "rgba(35, 71, 53, 0.65)";
      ctx.lineWidth = 1.2;
      ctx.lineCap = "round";
      for (let gx = 0; gx < width + STEP; gx += STEP) {
        for (let gy = 0; gy < height + STEP; gy += STEP) {
          const cx = gx + STEP / 2;
          const cy = gy + STEP / 2;
          const inLens = hasConvex &&
            cx >= xMin && cx <= xMax &&
            cy >= yMin && cy <= yMax;
          const [wcx, wcy] = inLens ? warp(cx, cy) : [cx, cy];
          const crossSize = inLens ? 6.5 : 5.5;
          ctx.moveTo(wcx, wcy - crossSize);
          ctx.lineTo(wcx, wcy + crossSize);
          ctx.moveTo(wcx - crossSize, wcy);
          ctx.lineTo(wcx + crossSize, wcy);
        }
      }
      ctx.stroke();
      ctx.lineCap = "butt";

      // 4. Pickleball Perforation Accents (Gold corner dots, Emerald center dots)
      // Gold corner dots
      ctx.fillStyle = "rgba(223, 183, 86, 0.16)";
      for (let gx = 0; gx <= width + STEP; gx += STEP) {
        for (let gy = 0; gy <= height + STEP; gy += STEP) {
          const inLens = hasConvex &&
            gx >= xMin && gx <= xMax &&
            gy >= yMin && gy <= yMax;
          const [wgx, wgy] = inLens ? warp(gx, gy) : [gx, gy];
          const dotR = inLens ? 2.2 : 1.8;
          ctx.beginPath();
          ctx.arc(wgx, wgy, dotR, 0, Math.PI * 2);
          ctx.fill();
        }
      }

      // Emerald center dots
      ctx.fillStyle = "rgba(74, 222, 128, 0.18)";
      for (let gx = 0; gx < width + STEP; gx += STEP) {
        for (let gy = 0; gy < height + STEP; gy += STEP) {
          const cx = gx + STEP / 2;
          const cy = gy + STEP / 2;
          const inLens = hasConvex &&
            cx >= xMin && cx <= xMax &&
            cy >= yMin && cy <= yMax;
          const [wcx, wcy] = inLens ? warp(cx, cy) : [cx, cy];
          const dotR = inLens ? 2.2 : 1.8;
          ctx.beginPath();
          ctx.arc(wcx, wcy, dotR, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    }

    function cleanup() {
      if (animId) {
        cancelAnimationFrame(animId);
        animId = null;
      }
      globalThis.removeEventListener("mousemove", handleMouseMove);
      globalThis.removeEventListener("mouseleave", handleMouseLeave);
      globalThis.removeEventListener("touchstart", handleTouch);
      globalThis.removeEventListener("touchmove", handleTouch);
      globalThis.removeEventListener("touchend", handleTouchEnd);
      globalThis.removeEventListener("touchcancel", handleTouchEnd);
      globalThis.removeEventListener("resize", resize);
    }

    function step() {
      if (landingEl.isConnected) {
        hasConnected = true;
      } else if (hasConnected) {
        cleanup();
        return;
      }

      currentX += (targetX - currentX) * EASE;
      currentY += (targetY - currentY) * EASE;
      currentStrength += (targetStrength - currentStrength) * EASE;

      draw();

      if (watermarkEl) {
        const halfW = width / 2 || 1;
        const halfH = height / 2 || 1;
        const normX = ((currentX - halfW) / halfW) * -16 * currentStrength;
        const normY = ((currentY - halfH) / halfH) * -12 * currentStrength;
        watermarkEl.style.transform = `translate(calc(-50% + ${
          normX.toFixed(2)
        }px), calc(-50% + ${normY.toFixed(2)}px)) rotate(${
          (-4 + normX * 0.04).toFixed(2)
        }deg)`;
      }

      // Settle and pause RAF when idle and mouse is not over
      if (
        targetStrength === 0 &&
        currentStrength <= 0.0005 &&
        Math.abs(targetX - currentX) < 0.1 &&
        Math.abs(targetY - currentY) < 0.1
      ) {
        currentStrength = 0;
        draw();
        animId = null;
        return;
      }

      animId = requestAnimationFrame(step);
    }

    function handleMouseMove(e) {
      const rect = canvas.getBoundingClientRect();
      targetX = e.clientX - rect.left;
      targetY = e.clientY - rect.top;
      if (currentX === -9999) {
        currentX = targetX;
        currentY = targetY;
      }
      targetStrength = 1;
      if (!animId) animId = requestAnimationFrame(step);
    }

    function handleTouch(e) {
      if (!e.touches || !e.touches[0]) return;
      const t = e.touches[0];
      const rect = canvas.getBoundingClientRect();
      targetX = t.clientX - rect.left;
      targetY = t.clientY - rect.top;
      if (currentX === -9999) {
        currentX = targetX;
        currentY = targetY;
      }
      targetStrength = 1;
      if (!animId) animId = requestAnimationFrame(step);
    }

    function handleMouseLeave() {
      targetStrength = 0;
      if (!animId) animId = requestAnimationFrame(step);
    }

    function handleTouchEnd() {
      targetStrength = 0;
      if (!animId) animId = requestAnimationFrame(step);
    }

    globalThis.addEventListener("mousemove", handleMouseMove, {
      passive: true,
    });
    globalThis.addEventListener("mouseleave", handleMouseLeave, {
      passive: true,
    });
    globalThis.addEventListener("touchstart", handleTouch, { passive: true });
    globalThis.addEventListener("touchmove", handleTouch, { passive: true });
    globalThis.addEventListener("touchend", handleTouchEnd, { passive: true });
    globalThis.addEventListener("touchcancel", handleTouchEnd, {
      passive: true,
    });
    globalThis.addEventListener("resize", resize, { passive: true });

    // Initial measurement
    requestAnimationFrame(() => {
      resize();
    });
  }

  function welcomePage() {
    const canvasEl = h("canvas", {
      class: "cpc-hero-canvas",
      "aria-hidden": "true",
    });
    const watermarkEl = createCourtWatermarkSvg();

    // 1. Hero Section
    const memberCount = h(
      "span",
      { class: "cpc-social-count", "aria-live": "polite" },
      "Active club members",
    );
    const memberAccounts = h(
      "div",
      { class: "cpc-member-accounts", "aria-hidden": "true" },
      h("span", { class: "cpc-member-account" }, "C"),
    );
    const heroSection = h(
      "section",
      { class: "cpc-hero", "aria-label": "Welcome to Capitol Pickleball Club" },
      canvasEl,
      watermarkEl,
      h(
        "div",
        { class: "cpc-landing-container" },
        h(
          "div",
          { class: "cpc-hero-grid" },
          // Left Column: Headline and CTAs
          h(
            "div",
            { class: "cpc-hero-content" },
            h(
              "div",
              { class: "cpc-hero-brand-top" },
              h(
                "div",
                { class: "cpc-top-flank cpc-top-flank-left" },
                h("img", {
                  src: "icons/paddle.png",
                  alt: "Tournament Pickleball Paddle Left",
                  class: "cpc-top-paddle cpc-top-paddle-left",
                }),
                h("img", {
                  src: "icons/ball.png",
                  alt: "Tournament Pickleball Left",
                  class: "cpc-top-ball cpc-top-ball-left",
                }),
              ),
              h("img", {
                class: "cpc-hero-logo cpc-top-logo",
                src: "icons/cpc-logo.png",
                alt: "Capitol Pickleball Club",
                width: "72",
                height: "72",
              }),
              h(
                "div",
                { class: "cpc-top-flank cpc-top-flank-right" },
                h("img", {
                  src: "icons/ball.png",
                  alt: "Tournament Pickleball Right",
                  class: "cpc-top-ball cpc-top-ball-right",
                }),
                h("img", {
                  src: "icons/paddle.png",
                  alt: "Tournament Pickleball Paddle Right",
                  class: "cpc-top-paddle cpc-top-paddle-right",
                }),
              ),
            ),
            h(
              "div",
              { class: "cpc-hero-badge" },
              icon("trophy"),
              "Province of Sultan Kudarat’s Pickleball Court",
            ),
            h(
              "h1",
              { class: "cpc-hero-title" },
              "Play, Compete & Elevate Your Game at ",
              h(
                "span",
                { class: "cpc-hero-title-accent" },
                "Capitol Pickleball Club",
              ),
            ),
            h(
              "p",
              { class: "cpc-hero-subtitle" },
              "Apply for membership, book court time, submit payment proof when needed, track your category and rank, and register for club events and tournaments.",
            ),
            h(
              "div",
              { class: "cpc-hero-actions" },
              h(
                "a",
                { class: "btn btn-accent", href: "#/signup" },
                icon("checkCircle"),
                "Join the Club",
              ),
              h(
                "a",
                { class: "btn btn-primary", href: "#/signin" },
                icon("user"),
                "Sign In",
              ),
              h(
                "a",
                { class: "btn btn-secondary", href: "#/booking" },
                icon("calendar"),
                "View Court Schedule",
              ),
            ),
            h(
              "div",
              { class: "cpc-hero-social" },
              memberAccounts,
              h(
                "div",
                { class: "cpc-social-text" },
                memberCount,
                h(
                  "span",
                  { class: "cpc-social-stars" },
                  "Custom club ranks · Court reservations",
                ),
              ),
            ),
          ),
          // Right Column: Symmetrical Paddles, Balls & Phone Mockup
          h(
            "div",
            { class: "cpc-hero-mockup-wrap" },
            h("img", {
              class: "cpc-paddle cpc-paddle-left",
              src: "icons/paddle.png",
              alt: "",
              "aria-hidden": "true",
            }),
            h("img", {
              class: "cpc-ball cpc-ball-left",
              src: "icons/ball.png",
              alt: "",
              "aria-hidden": "true",
            }),
            // Luxury Mobile Showcase Phone (Full Details)
            h(
              "div",
              {
                class: "cpc-phone",
                role: "img",
                "aria-label":
                  "Sample member dashboard showing a confirmed booking, club standing, tournament match, member pass, and recent activity. Illustrative data only.",
              },
              // Status Bar with Clock, Dynamic Island, and Signal/Battery
              h(
                "div",
                { class: "cpc-phone-status-bar" },
                h("span", { class: "cpc-phone-clock" }, "9:41"),
                h(
                  "div",
                  { class: "cpc-phone-dynamic-island" },
                  h("span", { class: "cpc-phone-camera-dot" }),
                ),
                h(
                  "div",
                  { class: "cpc-phone-status-tray" },
                  h(
                    "div",
                    { class: "cpc-phone-signal" },
                    h("span", {}),
                    h("span", {}),
                    h("span", {}),
                    h("span", {}),
                  ),
                  h("span", { class: "cpc-phone-5g" }, "5G"),
                  h(
                    "div",
                    { class: "cpc-phone-battery" },
                    h("div", { class: "cpc-phone-battery-level" }),
                  ),
                ),
              ),
              // Phone Screen
              h(
                "div",
                { class: "cpc-phone-screen" },
                // App Header with Avatar & QR Action
                h(
                  "div",
                  { class: "cpc-phone-head" },
                  h(
                    "div",
                    { class: "cpc-phone-user" },
                    h(
                      "div",
                      { class: "cpc-phone-avatar-wrap" },
                      h("span", { class: "cpc-phone-avatar" }, "AR"),
                      h("span", { class: "cpc-phone-online-dot" }),
                    ),
                    h(
                      "div",
                      {},
                      h(
                        "div",
                        { class: "cpc-phone-greeting" },
                        "Alex Reyes",
                      ),
                      h(
                        "div",
                        { class: "cpc-phone-status" },
                        "Sample member",
                      ),
                    ),
                  ),
                  h(
                    "span",
                    {
                      class: "cpc-phone-head-btn",
                      "aria-hidden": "true",
                    },
                    icon("qrScan"),
                  ),
                ),
                // Three calm cards: the next booking, the member's standing, the next match
                h(
                  "div",
                  { class: "cpc-phone-card cpc-phone-card-hero" },
                  h(
                    "div",
                    { class: "cpc-phone-card-top" },
                    h(
                      "span",
                      { class: "cpc-phone-card-tag" },
                      icon("calendar"),
                      "Next booking",
                    ),
                    h("span", { class: "cpc-phone-court-badge" }, "Court 1"),
                  ),
                  h("div", { class: "cpc-phone-court-name" }, "Today, 5:00 PM"),
                  h(
                    "div",
                    { class: "cpc-phone-time" },
                    icon("clock"),
                    "2 hours · Confirmed",
                  ),
                ),
                h(
                  "div",
                  { class: "cpc-phone-card" },
                  h(
                    "div",
                    { class: "cpc-phone-card-top" },
                    h(
                      "span",
                      { class: "cpc-phone-card-tag" },
                      icon("trophy"),
                      "Your standing",
                    ),
                  ),
                  h(
                    "div",
                    { class: "cpc-phone-metrics-grid" },
                    ...[["19", "Wins"], ["#12", "Club rank"], ["High", "Level"]]
                      .map(([value, label]) =>
                        h(
                          "div",
                          { class: "cpc-phone-metric" },
                          h("div", { class: "cpc-phone-metric-val" }, value),
                          h("div", { class: "cpc-phone-metric-lbl" }, label),
                        )
                      ),
                  ),
                ),
                h(
                  "div",
                  { class: "cpc-phone-card" },
                  h(
                    "div",
                    { class: "cpc-phone-card-top" },
                    h(
                      "span",
                      { class: "cpc-phone-card-tag" },
                      icon("trophy"),
                      "Summer Open",
                    ),
                    h("span", { class: "cpc-phone-live-dot" }, "● Live"),
                  ),
                  h(
                    "div",
                    { class: "cpc-phone-match-title" },
                    "Reyes / Tan vs. Santos / Lim",
                  ),
                  h(
                    "div",
                    { class: "cpc-phone-time" },
                    icon("clock"),
                    "Next match 7:30 PM · Court 3",
                  ),
                ),
                // Bottom navigation
                h(
                  "div",
                  { class: "cpc-phone-nav" },
                  ...[
                    ["home", "Home", true],
                    ["calendar", "Courts", false],
                    ["trophy", "Events", false],
                    ["user", "Profile", false],
                  ].map(([name, label, active]) =>
                    h(
                      "div",
                      {
                        class: `cpc-phone-nav-item${
                          active ? " is-active" : ""
                        }`,
                      },
                      icon(name),
                      h("span", {}, label),
                    )
                  ),
                ),
                // Home Indicator Bar
                h("div", { class: "cpc-phone-home-bar" }),
              ),
              h("img", {
                class: "cpc-ball cpc-ball-right",
                src: "icons/ball.png",
                alt: "",
                "aria-hidden": "true",
              }),
              h("img", {
                class: "cpc-paddle cpc-paddle-right",
                src: "icons/paddle.png",
                alt: "",
                "aria-hidden": "true",
              }),
            ),
          ),
        ),
      ),
    );

    const landingEl = h(
      "div",
      { class: "cpc-landing" },
      heroSection,
    );

    setupConvexPatternCanvas(canvasEl, landingEl, watermarkEl);
    loadClubMemberCount(memberCount, memberAccounts);

    return landingEl;
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
