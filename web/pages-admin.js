// Admin pages (PLAN 3.5): the members list with the approval flow (approve, reject, reconsider, suspend, restore).
// Every decision goes through the decide_member function, which checks the permission, takes an idempotency key
// (one per intent, reused if the request is retried), and writes the audit row. The buttons shown here follow the
// caller's permissions, but that is convenience only: the database decides.
import {
  attachPagePattern,
  badge,
  button,
  dataTable,
  DEFAULT_PAGE_SIZE,
  h,
  icon,
  iconButton,
  openModal,
  pagination,
  searchControl,
  selectControl,
  toast,
} from "./ui.js";
import { can } from "./lib/permissions.js";
import { avatarImage, signedAvatarUrls } from "./lib/avatar.js";
import { formatDateTime } from "./lib/dates.js";

const PAGE_SIZE = DEFAULT_PAGE_SIZE;

const TABS = [
  {
    id: "pending",
    label: "Waiting for Approval",
    statuses: ["pending_approval"],
  },
  { id: "active", label: "Active", statuses: ["active"] },
  { id: "suspended", label: "Suspended", statuses: ["suspended"] },
  { id: "rejected", label: "Rejected", statuses: ["rejected"] },
  { id: "archived", label: "Archived", statuses: ["archived"] },
  { id: "new", label: "Not Signed in Yet", statuses: ["imported", "invited"] },
  {
    id: "all",
    label: "All",
    statuses: [
      "imported",
      "invited",
      "pending_approval",
      "active",
      "rejected",
      "suspended",
      "archived",
    ],
  },
  {
    id: "deleted",
    label: "Deleted",
    deleted: true,
    statuses: [
      "imported",
      "invited",
      "pending_approval",
      "active",
      "rejected",
      "suspended",
      "archived",
    ],
  },
];

const STATUS_LABEL = {
  imported: "not signed in",
  invited: "profile incomplete",
  pending_approval: "waiting",
  active: "active",
  rejected: "rejected",
  suspended: "suspended",
  archived: "archived",
};
const STATUS_TONE = {
  imported: "neutral",
  invited: "neutral",
  pending_approval: "warning",
  active: "success",
  rejected: "danger",
  suspended: "danger",
  archived: "neutral",
};
const FLAG_LABEL = {
  possible_duplicate_name_dob: "Same name and birth date as another member",
  possible_duplicate_mobile: "Same mobile number as another member",
  minor: "Under 18: needs a guardian and a signed waiver",
};
const FLAG_SHORT = {
  possible_duplicate_name_dob: "duplicate?",
  possible_duplicate_mobile: "same mobile",
  minor: "under 18",
};

const SELECT =
  "id,member_no,status,status_reason,joined_on,created_at,profile_id,deleted_at,delete_reason," +
  "persons!inner(display_name,avatar_path,mobile,email,gender,date_of_birth,address_text,emergency_name,emergency_relationship,emergency_phone)," +
  "flags:member_review_flags!member_review_flags_member_id_fkey(kind,resolved_at)";

const openFlags = (row) => (row.flags ?? []).filter((f) => !f.resolved_at);
/** First letter upper case; the rest is left as typed (reasons are free text). */
const sentence = (t) => (t ? t.charAt(0).toUpperCase() + t.slice(1) : t);
const cleanTerm = (t) => t.replace(/[%_,()*]/g, " ").trim().slice(0, 60);

export function createAdminPages({ client, api, adminResetPassword }) {
  async function countOf(statuses, deleted = false) {
    let q = client.from("members").select("id", {
      count: "exact",
      head: true,
    }).in("status", statuses);
    q = deleted ? q.not("deleted_at", "is", null) : q.is("deleted_at", null);
    const { count, error } = await q;
    if (error) throw error;
    return count ?? 0;
  }

  async function loadPage({ statuses, term, page, deleted = false }) {
    let q = client.from("members").select(SELECT, { count: "exact" }).in(
      "status",
      statuses,
    ).order("created_at", { ascending: false })
      .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
    q = deleted ? q.not("deleted_at", "is", null) : q.is("deleted_at", null);
    const t = cleanTerm(term);
    if (t) {
      q = /^(cpc|\d)/i.test(t)
        ? q.ilike("member_no", `%${t}%`)
        : q.ilike("persons.display_name", `%${t}%`);
    }
    const { data, error, count } = await q;
    if (error) throw error;
    const rows = data ?? [];
    // Photos are private: each visible one is shown through a short-lived signed link.
    const urls = await signedAvatarUrls(
      client,
      rows.map((r) => r.persons?.avatar_path),
    );
    for (const r of rows) r._avatar = urls.get(r.persons?.avatar_path) ?? null;
    return { rows, total: count ?? 0 };
  }

  // ------------------------------------------------------------------ modals
  const reasonField = (label, required) => {
    const count = h("output", {
      class: "decision-reason-count",
      id: "decision-reason-count",
      for: "decision-reason",
    }, "0 / 500");
    return h(
      "div",
      { class: "field" },
      h(
        "div",
        { class: "decision-field-heading" },
        h(
          "label",
          { for: "decision-reason" },
          label,
          required ? h("span", { class: "decision-required" }, " *") : null,
        ),
        count,
      ),
      h("textarea", {
        class: "input textarea",
        id: "decision-reason",
        name: "reason",
        rows: 4,
        maxlength: 500,
        placeholder: "Provide context or explanation for this decision...",
        required,
        "aria-describedby": "decision-reason-help decision-reason-count",
        onInput: (event) => {
          count.textContent = `${event.target.value.length} / 500`;
        },
      }),
      h(
        "p",
        { class: "muted decision-reason-help", id: "decision-reason-help" },
        required
          ? "At least 3 characters. Maximum 500 characters."
          : "Optional. Maximum 500 characters.",
      ),
    );
  };

  /** Runs a decision; on failure the message is shown inside the modal and it stays open. */
  function decide(
    {
      action,
      row,
      title,
      verb,
      destructive = false,
      icon: iconName,
      tone,
      body,
      extra = () => ({}),
      call = null,
      reasonRequired,
      onDone,
    },
  ) {
    const key = api.newKey(); // one key per intent: a retry of the same click is not a second decision
    const error = h("p", {
      class: "field-error form-error",
      role: "alert",
      hidden: true,
    });
    const roleValue = h("span", {}, "Loading…");
    const dialog = openModal({
      title,
      eyebrow: "Member Management",
      icon: iconName || (destructive ? "alert" : "check"),
      tone: tone || (destructive ? "danger" : "info"),
      body: h(
        "div",
        { class: "member-decision" },
        h(
          "div",
          { class: "member-decision-subject" },
          h(
            "span",
            { class: "member-avatar", "aria-hidden": "true" },
            icon("user", { solid: true }),
          ),
          h(
            "div",
            { class: "member-meta" },
            h(
              "div",
              { class: "member-decision-name" },
              h("strong", { class: "member-name" }, row.persons.display_name),
              badge(
                STATUS_LABEL[row.status] ?? row.status,
                STATUS_TONE[row.status] ?? "neutral",
              ),
            ),
            h("span", { class: "sub member-subtext" }, row.member_no),
          ),
          can("roles.manage")
            ? h(
              "div",
              { class: "member-decision-role" },
              h("span", { class: "muted" }, "Role"),
              roleValue,
            )
            : null,
        ),
        body,
        error,
      ),
      confirmLabel: verb,
      cancelLabel: "Cancel",
      destructive,
      onConfirm: async (form) => {
        const reason = String(form.get("reason") ?? "").trim();
        if (reasonRequired && reason.length < 3) {
          error.textContent = "Please give a reason (at least 3 characters).";
          error.hidden = false;
          return false;
        }
        try {
          await (call ? call({ reason, key }) : api.rpc("decide_member", {
            p_action: action,
            p_member_id: row.id,
            p_reason: reason || null,
            p_key: key,
            ...extra(form),
          }));
          toast(`${row.persons.display_name}: ${verb.toLowerCase()} done.`, {
            tone: "success",
          });
          await onDone();
        } catch (e) {
          // The decision function's own messages (open review flags, wrong state, no permission) are written for
          // people, so they are shown as they are; anything else gets the generic wording.
          const own =
            ["22023", "42501", "23503", "CP422", "CP409"].includes(e.code) &&
            e.cause?.message;
          error.textContent = own || e.message ||
            "That did not work. Please try again.";
          error.hidden = false;
          return false;
        }
      },
    });
    if (can("roles.manage")) {
      api.rpc("staff_directory", {
        p_term: row.member_no,
        p_only_staff: row.status !== "active",
      })
        .then((members) => {
          roleValue.textContent = members?.find((member) =>
            member.member_id === row.id
          )?.role_name || "Unavailable";
        }).catch(() => {
          roleValue.textContent = "Unavailable";
        });
    }
    return dialog;
  }

  async function approveModal(row, onDone) {
    const flags = openFlags(row);
    let ranks = [];
    try {
      ranks = await api.read((c) =>
        c.from("ranks").select(
          "id,name,sort_order,rank_ladders!inner(categories!inner(name,sort_order))",
        ).is("deleted_at", null).order("sort_order")
      );
    } catch { /* the rank list is optional */ }
    ranks.sort((a, b) =>
      (a.rank_ladders.categories.sort_order -
        b.rank_ladders.categories.sort_order) || (a.sort_order - b.sort_order)
    );
    const rankSelect = selectControl(
      { class: "input", id: "decision-rank", name: "rank" },
      h("option", { value: "" }, "No starting rank yet"),
      ...ranks.map((r) => h("option", { value: r.id }, r.name)),
    );
    const ack = h("input", {
      type: "checkbox",
      id: "decision-ack",
      name: "ack",
    });
    decide({
      action: "approve",
      row,
      title: "Approve This Member",
      verb: "Approve",
      icon: "check",
      tone: "success",
      onDone,
      reasonRequired: false,
      body: h(
        "div",
        { class: "stack" },
        h(
          "div",
          { class: "modal-callout is-success" },
          h(
            "span",
            { class: "modal-callout-icon", "aria-hidden": "true" },
            icon("check"),
          ),
          h(
            "div",
            { class: "modal-callout-text" },
            "They will be able to book courts and join events right away.",
          ),
        ),
        flags.length
          ? h(
            "div",
            { class: "modal-callout is-warning" },
            h("strong", {}, "Review flags:"),
            h(
              "ul",
              { style: "margin: 6px 0 10px 18px; padding: 0;" },
              flags.map((f) => h("li", {}, FLAG_LABEL[f.kind] ?? f.kind)),
            ),
            h(
              "div",
              {
                class: "check",
                style:
                  "display: flex; align-items: center; gap: 8px; margin-top: 6px;",
              },
              ack,
              h(
                "label",
                {
                  for: "decision-ack",
                  style: "font-weight: 600; cursor: pointer;",
                },
                "I have reviewed these flags.",
              ),
            ),
          )
          : null,
        h(
          "div",
          { class: "field" },
          h("label", { for: "decision-rank" }, "Starting rank (optional)"),
          rankSelect,
        ),
        reasonField("Note (optional)", false),
      ),
      extra: (form) => ({
        p_acknowledge_flags: form.get("ack") === "on",
        p_rank_id: form.get("rank") || null,
      }),
    });
  }

  function reasonModal(action, row, text, onDone) {
    const copy = {
      reject: {
        title: "Reject This Application",
        verb: "Reject",
        destructive: true,
        icon: "x",
        tone: "danger",
        label: "Reason (the member is not shown this)",
      },
      reconsider: {
        title: "Reconsider This Application",
        verb: "Reconsider",
        destructive: false,
        icon: "refresh",
        tone: "restore",
        label: "Reason",
      },
      suspend: {
        title: "Suspend This Member",
        verb: "Suspend",
        destructive: true,
        icon: "alert",
        tone: "warning",
        label: "Reason",
      },
      restore: {
        title: "Restore This Member",
        verb: "Restore",
        destructive: false,
        icon: "refresh",
        tone: "restore",
        label: "Reason",
      },
      archive: {
        title: "Archive This Member",
        verb: "Archive",
        destructive: true,
        icon: "inbox",
        tone: "archive",
        label: "Reason",
      },
      delete: {
        title: "Delete This Member Record",
        verb: "Delete",
        destructive: true,
        icon: "trash",
        tone: "danger",
        label: "Reason",
      },
    }[action];
    const call = action === "archive"
      ? ({ reason, key }) =>
        api.rpc("archive_member", {
          p_member_id: row.id,
          p_reason: reason,
          p_key: key,
        })
      : (action === "delete"
        ? ({ reason, key }) =>
          api.rpc("soft_delete", {
            p_table: "members",
            p_id: row.id,
            p_reason: reason,
            p_key: key,
          })
        : null);
    decide({
      action,
      row,
      title: copy.title,
      verb: copy.verb,
      destructive: copy.destructive,
      icon: copy.icon,
      tone: copy.tone,
      call,
      reasonRequired: true,
      onDone,
      body: h(
        "div",
        { class: "stack" },
        h(
          "div",
          { class: `modal-callout is-${copy.tone}` },
          h(
            "span",
            { class: "modal-callout-icon", "aria-hidden": "true" },
            icon(copy.icon),
          ),
          h(
            "div",
            { class: "modal-callout-text" },
            h(
              "strong",
              { class: "decision-impact-title" },
              {
                suspend: "Access will be paused",
                archive: "This action is final",
                reject: "Application will be rejected",
                reconsider: "Application will be reviewed again",
                restore: "Access will be restored",
                delete: "Record will be hidden",
              }[action],
            ),
            h("p", { class: "decision-impact-text" }, text),
          ),
        ),
        reasonField(copy.label, true),
      ),
    });
  }

  /** Puts the member back on the first-password rule. Nothing is shown or sent: the member only needs their ID and birth date. */
  function resetPasswordModal(row) {
    const error = h("p", {
      class: "field-error form-error",
      role: "alert",
      hidden: true,
    });
    const name = row.persons?.display_name || row.member_no;
    const roleValue = h("span", {}, "Loading…");

    if (can("roles.manage")) {
      api.rpc("staff_directory", {
        p_term: row.member_no,
        p_only_staff: row.status !== "active",
      })
        .then((members) => {
          roleValue.textContent = members?.find((member) =>
            member.member_id === row.id
          )?.role_name || "Member";
        }).catch(() => {
          roleValue.textContent = "Member";
        });
    }

    const memberSubject = h(
      "div",
      { class: "member-decision-subject" },
      h(
        "span",
        { class: "member-avatar", "aria-hidden": "true" },
        icon("user", { solid: true }),
      ),
      h(
        "div",
        { class: "member-meta" },
        h(
          "div",
          { class: "member-decision-name" },
          h("strong", { class: "member-name" }, name),
          badge(
            STATUS_LABEL[row.status] ?? row.status,
            STATUS_TONE[row.status] ?? "neutral",
          ),
        ),
        h("span", { class: "sub member-subtext" }, row.member_no),
      ),
      can("roles.manage")
        ? h(
          "div",
          { class: "member-decision-role" },
          h("span", { class: "muted" }, "Role"),
          roleValue,
        )
        : null,
    );

    const callout = h(
      "div",
      { class: "modal-callout is-warning" },
      h(
        "span",
        { class: "modal-callout-icon", "aria-hidden": "true" },
        icon("alertTriangle"),
      ),
      h(
        "div",
        { class: "modal-callout-text" },
        h(
          "strong",
          { class: "decision-impact-title" },
          "First-password rule will be restored",
        ),
        h(
          "p",
          { class: "decision-impact-text" },
          "The password goes back to the initial rule: the last 5 digits of the member ID followed by their birth date as MMDDYYYY.",
        ),
      ),
    );

    const impactList = h(
      "div",
      { class: "decision-impact-list" },
      h(
        "div",
        { class: "decision-impact-item" },
        icon("checkCircle"),
        h(
          "div",
          {},
          h("strong", {}, "Existing credentials expire: "),
          "Active sessions end and current password stops working immediately.",
        ),
      ),
      h(
        "div",
        { class: "decision-impact-item" },
        icon("checkCircle"),
        h(
          "div",
          {},
          h("strong", {}, "Forced password change: "),
          "The member must choose a new password and confirm profile details upon next sign-in.",
        ),
      ),
      h(
        "div",
        { class: "decision-impact-item" },
        icon("checkCircle"),
        h(
          "div",
          {},
          h("strong", {}, "Audit trail: "),
          "This password reset action is permanently recorded in the administrative audit log.",
        ),
      ),
    );

    return openModal({
      title: "Reset Password",
      eyebrow: "Member Security",
      icon: "lock",
      tone: "danger",
      confirmLabel: "Reset Password",
      cancelLabel: "Cancel",
      destructive: true,
      body: h(
        "div",
        { class: "member-decision" },
        memberSubject,
        callout,
        impactList,
        error,
      ),
      onConfirm: async () => {
        try {
          const token = (await client.auth.getSession()).data.session
            ?.access_token;
          await adminResetPassword(row.id, token);
          toast(`${name}: password reset.`, { tone: "success" });
        } catch (e) {
          error.textContent = e?.message ||
            "The password could not be reset. Please try again.";
          error.hidden = false;
          return false;
        }
      },
    });
  }

  function detailsModal(row) {
    const p = row.persons;
    const kv = (label, value, wide = false) =>
      h(
        "dl",
        { class: `kv-item${wide ? " kv-item-wide" : ""}` },
        h("dt", { class: "kv-label" }, label),
        h("dd", { class: "kv-val" }, value || "—"),
      );

    const flags = row.flags ?? [];
    const history = h(
      "div",
      { class: "timeline-empty muted" },
      "Loading history…",
    );
    const rankEl = h("div", {}, badge("Loading…", "neutral"));

    const statusBadge = badge(
      STATUS_LABEL[row.status] ?? row.status,
      STATUS_TONE[row.status] ?? "neutral",
    );

    const accountBadge = row.profile_id
      ? badge("Active Account", "success")
      : badge("No Account Yet", "neutral");

    openModal({
      title: p.display_name,
      eyebrow: row.member_no,
      icon: "user",
      size: "lg",
      tone: "info",
      confirmLabel: "Close",
      cancelLabel: null,
      body: h(
        "div",
        { class: "member-details-modal" },
        // One summary row; the member number is already in the modal header.
        h(
          "div",
          { class: "member-banner" },
          h(
            "div",
            { class: "member-summary-item" },
            h("span", { class: "kv-label" }, "Membership"),
            statusBadge,
          ),
          h(
            "div",
            { class: "member-summary-item" },
            h("span", { class: "kv-label" }, "Account"),
            accountBadge,
          ),
          h(
            "div",
            { class: "member-summary-item" },
            h("span", { class: "kv-label" }, "Club Ranking"),
            rankEl,
          ),
        ),
        // Structured Profile Section Cards
        h(
          "div",
          { class: "member-profile-sections" },
          h(
            "div",
            { class: "member-section-card" },
            h(
              "h3",
              {},
              h(
                "span",
                { class: "section-icon", "aria-hidden": "true" },
                icon("phone"),
              ),
              "Contact Information",
            ),
            h(
              "div",
              { class: "member-details-grid" },
              kv(
                "Mobile",
                p.mobile
                  ? h(
                    "a",
                    { href: `tel:${p.mobile}`, class: "details-link" },
                    p.mobile,
                  )
                  : "—",
              ),
              kv(
                "Email",
                p.email
                  ? h(
                    "a",
                    { href: `mailto:${p.email}`, class: "details-link" },
                    p.email,
                  )
                  : "—",
              ),
              kv("Address", p.address_text || "—", true),
            ),
          ),
          h(
            "div",
            { class: "member-section-card" },
            h(
              "h3",
              {},
              h(
                "span",
                { class: "section-icon", "aria-hidden": "true" },
                icon("user"),
              ),
              "Personal & Profile",
            ),
            h(
              "div",
              { class: "member-details-grid" },
              kv("Date of Birth", p.date_of_birth || "—"),
              kv(
                "Gender",
                p.gender
                  ? p.gender.replace(/\b[a-z]/g, (c) => c.toUpperCase())
                  : "—",
              ),
              kv(
                "Emergency Contact",
                [p.emergency_name, p.emergency_relationship, p.emergency_phone]
                  .filter(Boolean)
                  .join(" · ") || "—",
                true,
              ),
            ),
          ),
        ),
        h(
          "div",
          { class: "member-section-card" },
          h(
            "h3",
            {},
            h(
              "span",
              { class: "section-icon", "aria-hidden": "true" },
              icon("file"),
            ),
            "Membership & Audit",
          ),
          h(
            "div",
            { class: "member-details-grid" },
            kv("Reason on Record", sentence(row.status_reason) || "—"),
            kv(
              "Review Flags",
              flags.length
                ? h(
                  "span",
                  { class: "badges" },
                  flags.map((f) =>
                    badge(FLAG_SHORT[f.kind] ?? f.kind, "warning")
                  ),
                )
                : h("span", { class: "muted" }, "None"),
            ),
            row.deleted_at
              ? kv(
                "Deleted Record",
                `Deleted: ${row.delete_reason ?? "No Reason"}`,
              )
              : null,
          ),
        ),
        // Activity Timeline Card
        h(
          "div",
          { class: "member-section-card" },
          h(
            "h3",
            {},
            h(
              "span",
              { class: "section-icon", "aria-hidden": "true" },
              icon("calendar"),
            ),
            "Status & Activity History",
          ),
          history,
        ),
      ),
      onConfirm: () => {},
    });

    // Staff with ranks.override can set the rank by hand; the database checks the permission, refuses the caller's own
    // rank, and writes the rank history and audit rows.
    const drawRank = () =>
      loadRank(row).then((current) => {
        rankEl.replaceChildren(
          h(
            "span",
            { class: "member-rank-line" },
            current
              ? h("span", { class: "badge badge-accent" }, current.text)
              : h("span", { class: "badge badge-neutral" }, "Unranked"),
            can("ranks.override") && !row.deleted_at
              ? iconButton({
                label: current ? "Change Rank" : "Set Rank",
                icon: "medal",
                size: "sm",
                variant: "edit",
                onClick: () => setRankModal(row, current, drawRank),
              })
              : null,
          ),
        );
      }).catch(() => {
        rankEl.replaceChildren(
          h("span", { class: "badge badge-neutral" }, "—"),
        );
      });
    drawRank();

    loadHistory(row).then((items) => {
      if (!items.length) {
        history.replaceChildren(
          h("div", { class: "muted timeline-empty" }, "No changes recorded."),
        );
        return;
      }
      history.className = "timeline-list";
      history.replaceChildren(
        ...items.map((e) => {
          const fromLabel = e.from_status
            ? STATUS_LABEL[e.from_status] ?? e.from_status
            : null;
          const toLabel = STATUS_LABEL[e.to_status] ?? e.to_status;
          const toTone = STATUS_TONE[e.to_status] ?? "neutral";
          return h(
            "div",
            { class: "timeline-item" },
            h("div", { class: `timeline-node is-${toTone}` }),
            h(
              "div",
              { class: "timeline-content" },
              h(
                "div",
                { class: "timeline-meta" },
                h(
                  "span",
                  { class: "timeline-time" },
                  formatDateTime(e.occurred_at),
                ),
                h(
                  "span",
                  { class: "timeline-transition" },
                  fromLabel
                    ? [
                      badge(fromLabel, "neutral"),
                      h("span", { class: "state-arrow" }, "→"),
                    ]
                    : null,
                  badge(toLabel, toTone),
                ),
              ),
              e.reason
                ? h("p", { class: "timeline-reason" }, `“${e.reason}”`)
                : null,
            ),
          );
        }),
      );
    }).catch(() => {
      history.textContent = "The history could not be loaded.";
    });
  }

  async function loadRank(row) {
    const r = await api.read((c) =>
      c.from("member_ranks").select(
        "rank_id,ranks(name,rank_ladders(categories(name)))",
      ).eq("member_id", row.id).is("deleted_at", null).maybeSingle()
    );
    const rk = r?.ranks;
    return rk
      ? {
        id: r.rank_id,
        text: `${rk.rank_ladders?.categories?.name ?? ""}: ${rk.name}`,
      }
      : null;
  }

  async function setRankModal(row, current, onDone) {
    let ranks;
    try {
      ranks = await api.read((c) =>
        c.from("ranks").select(
          "id,name,sort_order,rank_ladders!inner(categories!inner(name,sort_order))",
        ).is("deleted_at", null)
      ) ?? [];
    } catch {
      toast("The ranks could not be loaded.", { tone: "error" });
      return;
    }
    ranks.sort((a, b) =>
      (a.rank_ladders.categories.sort_order -
        b.rank_ladders.categories.sort_order) || (a.sort_order - b.sort_order)
    );
    const key = api.newKey();
    const error = h("p", {
      class: "field-error form-error",
      role: "alert",
      hidden: true,
    });
    openModal({
      title: current ? "Change Rank" : "Set Rank",
      eyebrow: `${row.persons.display_name} · ${
        current ? `now ${current.text}` : "unranked"
      }`,
      icon: "medal",
      tone: "warning",
      confirmLabel: "Set Rank",
      body: h(
        "div",
        { class: "stack" },
        h(
          "p",
          { class: "muted" },
          "This overrides the rank rules. It is kept in the member's rank history and the audit log. You cannot change your own rank.",
        ),
        h(
          "div",
          { class: "field" },
          h("label", { for: "set-rank" }, "New Rank *"),
          selectControl(
            { class: "input", id: "set-rank", name: "rank", required: true },
            h("option", { value: "" }, "Choose a rank"),
            ...ranks.map((r) =>
              h(
                "option",
                { value: r.id, selected: r.id === current?.id },
                `${r.rank_ladders.categories.name} · ${r.name}`,
              )
            ),
          ),
        ),
        h(
          "div",
          { class: "field" },
          h("label", { for: "set-rank-reason" }, "Reason *"),
          h("textarea", {
            class: "input textarea",
            id: "set-rank-reason",
            name: "reason",
            rows: 3,
            maxlength: 500,
            required: true,
          }),
        ),
        error,
      ),
      onConfirm: async (form) => {
        const rankId = String(form.get("rank") ?? "");
        const reason = String(form.get("reason") ?? "").trim();
        const fail = (m) => {
          error.textContent = m;
          error.hidden = false;
          return false;
        };
        if (!rankId) return fail("Choose a rank.");
        if (rankId === current?.id) {
          return fail("The member is already at that rank.");
        }
        if (reason.length < 3) {
          return fail("Give a reason of at least 3 characters.");
        }
        try {
          await api.rpc("override_member_rank", {
            p_member_id: row.id,
            p_rank_id: rankId,
            p_reason: reason,
            p_key: key,
          });
          toast(`${row.persons.display_name}: rank set.`, { tone: "success" });
          onDone?.();
        } catch (e) {
          return fail(
            e.cause?.message || e.message || "That did not work. Try again.",
          );
        }
      },
    });
  }

  async function loadHistory(row) {
    return await api.read((c) =>
      c.from("member_status_events").select(
        "from_status,to_status,reason,occurred_at",
      ).eq("member_id", row.id).order("occurred_at", { ascending: false })
        .limit(20)
    ) ?? [];
  }

  // ------------------------------------------------------------------ the page
  function membersPage() {
    const state = {
      tab: "pending",
      term: "",
      page: 1,
      rows: [],
      total: 0,
      status: "loading",
    };
    const counts = Object.fromEntries(TABS.map((item) => [item.id, null]));
    const root = h("div", { class: "page admin-dashboard admin-members-page" });
    attachPagePattern(root);

    const kpis = h("div", { class: "home-grid kpis" });
    const tableHost = h("div", { class: "table-host" });
    const pagerHost = h("div", {});
    let timer = null;
    const statusButtons = TABS.map((item) =>
      h("button", {
        type: "button",
        class: "tab-btn",
        "aria-pressed": String(item.id === state.tab),
        onClick: () => {
          clearTimeout(timer);
          state.tab = item.id;
          state.term = search.value;
          state.page = 1;
          drawStatusFilter();
          load();
        },
      }, item.label)
    );
    const statusFilter = h(
      "div",
      {
        class: "member-status-badges",
        role: "group",
        "aria-label": "Filter members by status",
      },
      ...statusButtons,
    );

    const search = searchControl({
      class: "input",
      id: "members-search",
      type: "search",
      placeholder: "Search by name or member ID…",
      "aria-label": "Search Members",
      onInput: (e) => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          state.term = e.target.value;
          state.page = 1;
          load();
        }, 300);
      },
    });

    const searchBox = search;

    const actionsFor = (row) => {
      const buttons = [
        iconButton({
          label: "View Details",
          icon: "info",
          size: "sm",
          variant: "info",
          onClick: () => detailsModal(row),
        }),
      ];
      if (
        can("members.reset_password") && row.profile_id && !row.deleted_at &&
        ["active", "invited", "pending_approval"].includes(row.status)
      ) {
        buttons.push(iconButton({
          label: "Reset Password",
          icon: "lock",
          size: "sm",
          variant: "edit",
          onClick: () => resetPasswordModal(row),
        }));
      }
      const approve = can("members.approve");
      const suspend = can("members.suspend");
      const edit = can("members.update");
      if (row.deleted_at) {
        if (edit) {
          buttons.push(iconButton({
            label: "Restore the Record",
            icon: "refresh",
            size: "sm",
            variant: "restore",
            onClick: async () => {
              try {
                await api.rpc("restore_row", {
                  p_table: "members",
                  p_id: row.id,
                  p_key: api.newKey(),
                });
                toast(`${row.persons.display_name}: record restored.`, {
                  tone: "success",
                });
                await refresh();
              } catch (e) {
                toast(e.cause?.message || e.message || "That did not work.", {
                  tone: "error",
                });
              }
            },
          }));
        }
        return h("div", { class: "row-actions" }, buttons);
      }
      if (row.status === "pending_approval" && approve) {
        buttons.push(
          iconButton({
            label: "Approve",
            icon: "check",
            size: "sm",
            variant: "success",
            onClick: () => approveModal(row, refresh),
          }),
          iconButton({
            label: "Reject",
            icon: "x",
            size: "sm",
            variant: "danger",
            onClick: () =>
              reasonModal(
                "reject",
                row,
                "The application will be marked rejected. You can reconsider it later.",
                refresh,
              ),
          }),
        );
      }
      if (row.status === "rejected" && approve) {
        buttons.push(iconButton({
          label: "Reconsider",
          icon: "refresh",
          size: "sm",
          variant: "restore",
          onClick: () =>
            reasonModal(
              "reconsider",
              row,
              "The application goes back to waiting for approval.",
              refresh,
            ),
        }));
      }
      if (row.status === "active" && suspend) {
        buttons.push(iconButton({
          label: "Suspend",
          icon: "alert",
          size: "sm",
          variant: "warning",
          onClick: () =>
            reasonModal(
              "suspend",
              row,
              "They lose access at once. You can restore them later.",
              refresh,
            ),
        }));
      }
      if (row.status === "suspended" && suspend) {
        buttons.push(iconButton({
          label: "Restore",
          icon: "refresh",
          size: "sm",
          variant: "restore",
          onClick: () =>
            reasonModal("restore", row, "They get their access back.", refresh),
        }));
      }
      if (suspend && row.status !== "archived") {
        buttons.push(iconButton({
          label: "Archive",
          icon: "inbox",
          size: "sm",
          variant: "archive",
          onClick: () =>
            reasonModal(
              "archive",
              row,
              "Archived is final: they lose access and cannot be brought back to active. Their history is kept.",
              refresh,
            ),
        }));
      }
      if (
        edit &&
        ["archived", "rejected", "imported", "invited"].includes(row.status)
      ) {
        buttons.push(iconButton({
          label: "Delete the Record",
          icon: "trash",
          size: "sm",
          variant: "danger",
          onClick: () =>
            reasonModal(
              "delete",
              row,
              "The record is hidden from every list. You can restore it from the Deleted tab.",
              refresh,
            ),
        }));
      }
      return h("div", { class: "row-actions" }, buttons);
    };

    const schema = {
      // One shared column schema drives headings, rows and skeletons.
      columns: [
        {
          key: "name",
          label: "Member",
          render: (r) => {
            const name = r.persons.display_name || "Unknown";
            return h(
              "div",
              { class: "member-cell" },
              h(
                "span",
                { class: "member-avatar", "aria-hidden": "true" },
                avatarImage(r._avatar, name),
              ),
              h(
                "div",
                { class: "member-meta" },
                h("span", { class: "member-name" }, name),
                h("span", { class: "sub member-subtext" }, r.member_no || "—"),
              ),
            );
          },
        },
        {
          key: "mobile",
          label: "Contact",
          skeleton: "stack",
          render: (r) =>
            h(
              "div",
              { class: "member-table-stack" },
              r.persons.mobile ?? "—",
              h("span", { class: "sub" }, r.persons.email ?? "No Email"),
            ),
        },
        {
          key: "status",
          label: "Status",
          skeleton: "badge-stack",
          render: (r) =>
            h(
              "div",
              { class: "member-table-stack" },
              badge(
                STATUS_LABEL[r.status] ?? r.status,
                STATUS_TONE[r.status] ?? "neutral",
              ),
              h(
                "span",
                { class: "sub" },
                r.deleted_at
                  ? "Deleted"
                  : ((sentence(r.status_reason) ?? "").toLowerCase() !==
                      (STATUS_LABEL[r.status] ?? r.status).toLowerCase()
                    ? sentence(r.status_reason)
                    : "") ||
                    (r.profile_id ? "Has an account" : "No account yet"),
              ),
            ),
        },
        {
          key: "flags",
          label: "Review",
          skeleton: "badge-stack",
          render: (r) => {
            const open = openFlags(r);
            return open.length
              ? h(
                "div",
                { class: "member-table-stack" },
                h(
                  "span",
                  { class: "badges" },
                  open.map((f) =>
                    badge(FLAG_SHORT[f.kind] ?? f.kind, "warning")
                  ),
                ),
                h(
                  "span",
                  { class: "sub" },
                  `${open.length} to review`,
                ),
              )
              : h(
                "div",
                { class: "member-table-stack" },
                "Clear",
                h("span", { class: "sub" }, "No review flags"),
              );
          },
        },
        {
          key: "joined",
          label: "Membership Dates",
          skeleton: "stack",
          render: (r) =>
            h(
              "div",
              { class: "member-table-stack" },
              `Added ${
                (r.created_at ?? r.joined_on ?? "").slice(0, 10) || "—"
              }`,
              h(
                "span",
                { class: "sub" },
                r.joined_on
                  ? `Joined ${r.joined_on.slice(0, 10)}`
                  : "Not joined yet",
              ),
            ),
        },
        {
          key: "actions",
          label: "Action",
          align: "center",
          actionCount: 5,
          render: actionsFor,
        },
      ],
    };

    function drawStatusFilter() {
      TABS.forEach((item, index) => {
        const count = counts[item.id];
        statusButtons[index].replaceChildren(
          item.label,
          badge(String(count ?? 0), "neutral"),
        );
        statusButtons[index].setAttribute(
          "aria-pressed",
          String(item.id === state.tab),
        );
      });
    }

    function memberStatCard({
      label,
      value,
      hint,
      iconName,
      pill,
      isAttention,
      tone = "emerald",
      tabId,
    }) {
      return h(
        "button",
        {
          type: "button",
          class: `home-card member-stat-card is-link is-tone-${tone}${
            isAttention ? " is-attention" : ""
          }`,
          onClick: () => {
            state.tab = tabId;
            state.page = 1;
            drawStatusFilter();
            load();
          },
        },
        h(
          "div",
          { class: "member-stat-main" },
          h(
            "span",
            { class: "home-card-icon", "aria-hidden": "true" },
            icon(iconName),
          ),
          h(
            "div",
            { class: "member-stat-copy" },
            h("span", { class: "home-card-value" }, String(value ?? "0")),
            h("span", { class: "home-card-label" }, label),
          ),
          pill,
        ),
        h(
          "div",
          { class: "home-card-bottom" },
          h("div", { class: "home-card-hint" }, hint),
          h(
            "span",
            { class: "home-card-go" },
            tabId === "pending" ? "Review Applications" : "View Members",
            icon("chevronRight"),
          ),
        ),
      );
    }

    function drawKpis() {
      const pCount = Number(counts.pending) || 0;
      const sCount = Number(counts.suspended) || 0;
      const aCount = Number(counts.active) || 0;

      kpis.replaceChildren(
        memberStatCard({
          label: "Waiting for Approval",
          value: counts.pending ?? "—",
          hint: pCount > 0
            ? "Requires administrator review"
            : "Approval queue is clear",
          iconName: "clock",
          isAttention: pCount > 0,
          tone: "amber",
          tabId: "pending",
          pill: pCount > 0
            ? h(
              "span",
              { class: "card-status-pill is-attention" },
              h("span", { class: "pill-pulse-dot", "aria-hidden": "true" }),
              "Needs Review",
            )
            : h(
              "span",
              { class: "card-status-pill is-clean" },
              icon("check"),
              "All Clear",
            ),
        }),
        memberStatCard({
          label: "Active Members",
          value: counts.active ?? "—",
          hint: `${aCount} registered member${aCount === 1 ? "" : "s"} in club`,
          iconName: "user",
          isAttention: false,
          tone: "emerald",
          tabId: "active",
          pill: h(
            "span",
            { class: "card-status-pill is-clean" },
            icon("check"),
            "Active",
          ),
        }),
        memberStatCard({
          label: "Suspended",
          value: counts.suspended ?? "—",
          hint: sCount > 0
            ? "Accounts restricted from play"
            : "Zero account suspensions",
          iconName: "alert",
          isAttention: sCount > 0,
          tone: "rose",
          tabId: "suspended",
          pill: sCount > 0
            ? h(
              "span",
              { class: "card-status-pill is-attention" },
              "Restricted",
            )
            : h(
              "span",
              { class: "card-status-pill is-clean" },
              icon("check"),
              "Clean",
            ),
        }),
      );
    }

    function draw() {
      let emptyTitle = "Nobody Here";
      let emptyText = "Members will appear in this list.";
      if (state.term) {
        emptyTitle = `No members match "${state.term}"`;
        emptyText = "Try a different name or member ID, or clear your search.";
      } else if (state.tab === "pending") {
        emptyTitle = "No members waiting for approval";
        emptyText =
          "When new members sign up, their applications will show up here for review.";
      } else if (state.tab === "active") {
        emptyTitle = "No active members yet";
        emptyText = "Approved members will appear here.";
      } else if (state.tab === "suspended") {
        emptyTitle = "No suspended members";
        emptyText = "Suspended member accounts will appear here.";
      } else if (state.tab === "rejected") {
        emptyTitle = "No rejected members";
        emptyText = "Rejected membership applications will appear here.";
      } else if (state.tab === "archived") {
        emptyTitle = "No archived members";
        emptyText = "Archived members will appear here.";
      } else if (state.tab === "new") {
        emptyTitle = "No pending invitations";
        emptyText =
          "Imported or invited members who have not signed in yet will appear here.";
      } else if (state.tab === "deleted") {
        emptyTitle = "No deleted members";
        emptyText = "Soft-deleted member records will appear here.";
      }

      tableHost.replaceChildren(dataTable({
        schema,
        rows: state.rows,
        state: state.status,
        searchable: false,
        hasFilters: Boolean(state.term),
        onRetry: load,
        onReset: () => {
          clearTimeout(timer);
          search.value = "";
          state.term = "";
          state.page = 1;
          load();
        },
        emptyTitle,
        emptyText,
        resetLabel: "Clear Search",
        ariaLabel: "Members",
      }));
      pagerHost.replaceChildren(
        state.status === "ready"
          ? pagination({
            page: state.page,
            pageSize: PAGE_SIZE,
            total: state.total,
            onPage: (p) => {
              state.page = p;
              load();
            },
          })
          : "",
      );
    }

    async function loadCounts() {
      try {
        const totals = await Promise.all(
          TABS.map((item) => countOf(item.statuses, Boolean(item.deleted))),
        );
        TABS.forEach((item, index) => {
          counts[item.id] = totals[index];
        });
      } catch { /* the numbers are a convenience */ }
      drawKpis();
      drawStatusFilter();
    }

    async function load() {
      state.status = "loading";
      draw();
      try {
        const { rows, total } = await loadPage({
          statuses: TABS.find((t) => t.id === state.tab).statuses,
          deleted: Boolean(TABS.find((t) => t.id === state.tab).deleted),
          term: state.term,
          page: state.page,
        });
        state.rows = rows;
        state.total = total;
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    async function refresh() {
      await Promise.all([load(), loadCounts()]);
    }

    const manilaDate = new Intl.DateTimeFormat("en-PH", {
      timeZone: "Asia/Manila",
      weekday: "short",
      month: "short",
      day: "numeric",
      year: "numeric",
    }).format(new Date());

    const hero = h(
      "section",
      {
        class: "dash-hero is-admin",
        "aria-label": "Members Directory",
      },
      h(
        "div",
        { class: "dash-hero-copy" },
        h(
          "div",
          { class: "dash-hero-chips" },
          h(
            "span",
            { class: "dash-chip is-role" },
            icon("medal"),
            "Admin Console",
          ),
          h(
            "span",
            { class: "dash-chip is-date" },
            icon("calendar"),
            manilaDate,
          ),
          h(
            "span",
            { class: "dash-chip is-status" },
            h("span", { class: "status-dot-pulse", "aria-hidden": "true" }),
            "Members Management",
          ),
        ),
        h(
          "h1",
          { class: "dash-hero-title", id: "page-title", tabindex: "-1" },
          "Members Directory",
        ),
        h(
          "p",
          { class: "dash-hero-sub" },
          "Approve new members, and suspend or restore existing ones. Every decision is recorded.",
        ),
      ),
      h(
        "div",
        { class: "dash-hero-actions" },
        button({
          label: "Refresh List",
          icon: "refresh",
          variant: "secondary",
          onClick: refresh,
        }),
      ),
    );

    root.append(
      hero,
      kpis,
      h(
        "div",
        { class: "toolbar admin-members-toolbar has-status-badges" },
        searchBox,
        statusFilter,
      ),
      h("div", { class: "member-directory-card" }, tableHost, pagerHost),
    );
    drawKpis();
    drawStatusFilter();
    draw();
    refresh();
    return root;
  }

  return { membersPage };
}
