import { h, kpiCard, pageHeader } from "./ui.js";

export { componentsPage } from "./pages-components.js";

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

export function forbiddenPage() {
  return h(
    "div",
    { class: "page" },
    pageHeader({
      icon: "alert",
      title: "No access",
      description: "Your account does not have permission to open this page.",
    }),
    h("a", { href: "#/" }, "Back to home"),
  );
}
