import {
  badge,
  dropdownMenu,
  h,
  icon,
  iconButton,
  openModal,
  selectControl,
  toast,
} from "../ui.js";
import { avatarImage } from "./avatar.js";

/** Pre-draw roster editing. The server validates and commits each swap atomically. */
export function openRosterEditor(
  { api, event, division, registrations, partners = {}, photos, editable, onSaved },
) {
  const active = registrations.filter((r) =>
    ["requested", "confirmed"].includes(r.status)
  ).sort((a, b) =>
    Number(a.meta?.roster_position ?? Infinity) -
    Number(b.meta?.roster_position ?? Infinity)
  );
  const waiting = registrations.filter((r) => r.status === "waitlisted");
  const players = (r) => [
    {
      key: r.member_id ? `m:${r.member_id}` : `g:${r.guest_participant_id}`,
      name: r.guest_name_snapshot ?? r.member?.person?.display_name ??
        "Participant",
      guest: !r.member_id,
      memberId: r.member_id ?? null,
      participantId: r.guest_participant_id ?? null,
    },
    ...(r.guest_partner_participant_id || r.meta?.partner_member_id
      ? [{
        key: r.guest_partner_participant_id
          ? `g:${r.guest_partner_participant_id}`
          : `m:${r.meta.partner_member_id}`,
        name: r.guest_partner_name_snapshot ??
          partners[r.meta?.partner_member_id]?.person?.display_name ??
          "Partner",
        guest: Boolean(r.guest_partner_participant_id),
        memberId: r.guest_partner_participant_id
          ? null
          : (r.meta?.partner_member_id ?? null),
        participantId: r.guest_partner_participant_id ?? null,
      }]
      : []),
  ];
  const teamName = (r) => players(r).map((p) => p.name).join(" & ");
  let dragging = null;
  let busy = false;
  const feedback = h("p", {
    class: "sub",
    role: "status",
    "aria-live": "polite",
  });
  const send = async (payload) => {
    if (busy) throw new Error("Wait for the current roster change to finish.");
    busy = true;
    feedback.textContent = "Saving roster change…";
    try {
      await api.rpc("edit_division_roster", {
        p_division_id: division.id,
        ...payload,
      });
      feedback.textContent = "Roster saved.";
      await onSaved();
      dialog.close();
      toast("Event roster updated. The official draw has been preserved.", {
        tone: "success",
      });
    } catch (error) {
      feedback.textContent = error?.cause?.message || error.message ||
        "The roster could not be saved. Try again.";
      throw error;
    } finally {
      busy = false;
    }
  };
  async function action(
    kind,
    source,
    sourcePlayer,
    target = null,
    targetPlayer = null,
  ) {
    if (!editable || busy) return;
    const key = api.newKey();
    const options = [];
    if (kind === "replace") {
      try {
        const choices = await api.rpc("roster_replacement_choices", {
          p_registration_id: source.id,
          p_player: sourcePlayer,
        }) ?? [];
        const occupied = new Set(
          [...active, ...waiting].flatMap((r) => players(r).map((p) => p.key)),
        );
        for (const p of choices) {
          const value = p.member_id ? `m:${p.member_id}` : `g:${p.id}`;
          if (!occupied.has(value)) {
            options.push({
              value,
              label: p.rank_name
                ? `${p.display_name} · ${p.rank_name}`
                : p.display_name,
              name: p.display_name,
              entry: p.rank_name ?? "Replacement player",
            });
          }
        }
      } catch (error) {
        feedback.textContent = error.message;
        return;
      }
    } else {
      for (const r of active.filter((r) => r.id !== source.id)) {
        if (kind === "team_swap") {
          options.push({
            value: r.id,
            label: `Entry ${active.indexOf(r) + 1} · ${teamName(r)}`,
            name: teamName(r),
            entry: `Entry ${active.indexOf(r) + 1}`,
            members: players(r),
          });
        } else {players(r).forEach((p, index) =>
            options.push({
              value: `${r.id}:${index + 1}`,
              label: `Entry ${active.indexOf(r) + 1} · ${p.name}`,
              name: p.name,
              entry: `Entry ${active.indexOf(r) + 1}`,
            })
          );}
      }
    }
    const fixed = target
      ? kind === "team_swap" ? target.id : `${target.id}:${targetPlayer}`
      : "";
    const sourcePlayers = players(source);
    const activeSourcePlayer = sourcePlayer ? sourcePlayers[sourcePlayer - 1] : null;
    const sourcePartner = sourcePlayer && sourcePlayers.length > 1
      ? sourcePlayers.find((_, idx) => idx !== sourcePlayer - 1)
      : null;
    const sourceRoleMeta = activeSourcePlayer
      ? `${activeSourcePlayer.guest ? "Guest Player" : "Club Member"}${
        sourcePartner ? ` · Partner: ${sourcePartner.name}` : ""
      }`
      : null;
    const personCard = (
      name,
      entry,
      pending = false,
      members = null,
      { roleLabel = "", sideLabel = "", isSource = false } = {},
    ) =>
      h(
        "div",
        {
          class: `roster-person-card${pending ? " is-pending" : " is-filled"}${
            members ? " is-team" : ""
          }${isSource ? " is-source" : " is-target"}`,
        },
        h(
          "div",
          { class: "roster-person-card-top" },
          h(
            "span",
            { class: "roster-person-side-pill" },
            sideLabel || (isSource ? "Current" : pending ? "Awaiting" : "Selected"),
          ),
          h("span", { class: "sub roster-person-entry-tag" }, entry),
        ),
        h(
          "div",
          { class: "roster-person-main" },
          h(
            "span",
            { class: "roster-person-avatar", "aria-hidden": "true" },
            icon(kind === "team_swap" ? "layers" : "user"),
          ),
          h(
            "div",
            { class: "roster-person-copy" },
            members
              ? h(
                "div",
                { class: "roster-team-members" },
                ...members.map((p) =>
                  h(
                    "div",
                    { class: "roster-team-player" },
                    h("span", {
                      class: "roster-team-player-icon",
                      "aria-hidden": "true",
                    }, icon("user")),
                    h(
                      "div",
                      {},
                      h("strong", {}, p.name),
                      h(
                        "span",
                        { class: "sub" },
                        p.guest ? "Guest Player" : "Member",
                      ),
                    ),
                  )
                ),
              )
              : [
                h("strong", {}, name),
                roleLabel
                  ? h("span", { class: "sub roster-person-role" }, roleLabel)
                  : null,
              ],
          ),
        ),
      );
    const targetPreview = h("div", { class: "roster-target-preview" });
    const updatePreview = () => {
      const selected = options.find((o) => o.value === select.value);
      const selectedRole = selected
        ? (kind === "replace"
          ? (selected.value.startsWith("g:") ? "Eligible Guest" : "Eligible Member")
          : kind === "player_swap"
          ? "Teammate Swap Target"
          : "")
        : (kind === "team_swap"
          ? "Select destination slot below"
          : kind === "replace"
          ? "Select eligible replacement below"
          : "Select player to exchange with");
      targetPreview.replaceChildren(
        personCard(
          selected?.name ??
            (kind === "team_swap" ? "Choose a team" : "Choose a player"),
          selected?.entry ??
            (kind === "team_swap"
              ? "Destination entry"
              : kind === "replace"
              ? "Replacement player"
              : "Swap with"),
          !selected,
          selected?.members,
          {
            roleLabel: selectedRole,
            sideLabel: kind === "replace"
              ? (selected ? "Replacement" : "Incoming")
              : (selected ? "Target" : "Destination"),
            isSource: false,
          },
        ),
      );
    };
    const select = selectControl(
      {
        class: "input select-input",
        "aria-label": kind === "replace"
          ? "Replacement player"
          : kind === "team_swap"
          ? "Destination entry"
          : "Swap with",
        required: true,
        onChange: updatePreview,
      },
      h("option", { value: "", disabled: true, selected: !fixed }, "Choose…"),
      ...options.map((o) =>
        h("option", { value: o.value, selected: o.value === fixed }, o.label)
      ),
    );
    updatePreview();
    const reasonCount = h(
      "span",
      { class: "sub roster-char-counter", "aria-live": "polite" },
      "0 / 500",
    );
    const reason = h("textarea", {
      class: "input",
      name: "roster-reason",
      rows: 3,
      minlength: 3,
      maxlength: 500,
      required: kind !== "team_swap",
      "aria-label": "Reason for roster change",
      placeholder: kind === "replace"
        ? "e.g. Original player withdrew; replacement confirmed."
        : "e.g. Both teams agreed to exchange players before the draw.",
      onInput: () => {
        reasonCount.textContent = `${reason.value.length} / 500`;
      },
    });
    const errorLine = h("p", { class: "field-error", role: "alert" });
    let request = null;
    const selectLabelText = kind === "replace"
      ? "Replacement player"
      : kind === "team_swap"
      ? "Destination entry"
      : "Swap with";
    openModal({
      title: kind === "team_swap"
        ? "Move Team"
        : kind === "replace"
        ? "Replace Player"
        : "Swap Players",
      eyebrow: division.name,
      icon: kind === "replace" ? "edit" : "shuffle",
      size: kind === "team_swap" ? "lg" : "md",
      confirmLabel: kind === "player_swap"
        ? "Confirm Swap"
        : kind === "replace"
        ? "Confirm Replacement"
        : "Confirm Move",
      body: h(
        "div",
        { class: "entry-roster-form" },
        h(
          "div",
          { class: "roster-swap-preview" },
          personCard(
            kind === "team_swap"
              ? teamName(source)
              : players(source)[sourcePlayer - 1]?.name,
            `Entry ${active.indexOf(source) + 1}`,
            false,
            kind === "team_swap" ? players(source) : null,
            {
              roleLabel: sourceRoleMeta,
              sideLabel: kind === "replace" ? "Outgoing" : "Source",
              isSource: true,
            },
          ),
          h(
            "span",
            { class: "roster-swap-direction", "aria-hidden": "true" },
            icon("shuffle"),
          ),
          targetPreview,
        ),
        h(
          "div",
          { class: "roster-form-card" },
          h(
            "label",
            { class: "roster-field-label" },
            h(
              "span",
              { class: "roster-field-label-row" },
              h("span", { class: "roster-field-title" }, selectLabelText),
              h("span", { class: "roster-required-pill" }, "Required"),
            ),
            select,
          ),
          kind === "replace"
            ? h(
              "p",
              { class: "sub roster-eligibility-hint" },
              icon("checkCircle"),
              h(
                "span",
                {},
                `Only available players within ${division.name} eligibility and rank/rating limits are shown.`,
              ),
            )
            : null,
          kind === "replace" && !options.length
            ? h(
              "p",
              { class: "sub roster-empty-choices-hint" },
              icon("alert"),
              h(
                "span",
                {},
                "No eligible replacements. Add a player within this division’s rank/rating range through Add Guest. Eligible members appear automatically in the partner search.",
              ),
            )
            : null,
          kind !== "team_swap"
            ? h(
              "div",
              { class: "roster-reason-field" },
              h(
                "label",
                { class: "roster-field-label" },
                h(
                  "span",
                  { class: "roster-field-label-row" },
                  h("span", { class: "roster-field-title" }, "Reason for change"),
                  h("span", { class: "roster-required-pill" }, "Audit Log"),
                ),
                reason,
              ),
              h(
                "div",
                { class: "roster-reason-hint" },
                h("span", { class: "sub" }, "Required · At least 3 characters"),
                reasonCount,
              ),
            )
            : null,
        ),
        h(
          "div",
          { class: "roster-change-note" },
          h("span", { class: "roster-change-note-icon", "aria-hidden": "true" }, icon("info")),
          h(
            "span",
            { class: "sub" },
            kind === "team_swap"
              ? "Both teams exchange entry positions. The official draw stays unchanged."
              : "Original registrations stay in history. Verified payment credit stays with the same payer.",
          ),
        ),
        errorLine,
      ),
      onConfirm: async () => {
        if (
          !select.value ||
          (kind !== "team_swap" && reason.value.trim().length < 3)
        ) {
          errorLine.textContent =
            "Choose a player or entry and provide the required reason.";
          return false;
        }
        const [targetId, player] = select.value.split(":");
        const chosen = active.find((r) => r.id === targetId);
        const payload = {
          p_action: kind,
          p_source_id: source.id,
          p_target_id: kind === "replace" ? null : targetId,
          p_source_player: sourcePlayer ?? null,
          p_target_player: kind === "player_swap" ? Number(player) : null,
          p_replacement: kind === "replace" ? select.value : null,
          p_reason: kind === "team_swap" ? null : reason.value.trim(),
          p_versions: Object.fromEntries(
            [source, chosen].filter(Boolean).map((r) => [r.id, r.version]),
          ),
        };
        // Reuse the key for an identical retry; edited submissions get a new intent.
        const fingerprint = JSON.stringify(payload);
        request = request?.fingerprint === fingerprint
          ? request
          : { fingerprint, key: request ? api.newKey() : key };
        try {
          await send({ ...payload, p_key: request.key });
        } catch (error) {
          errorLine.textContent = error?.cause?.message || error.message;
          return false;
        }
      },
    });
  }
  const confirmedCount = active.filter((r) => r.status === "confirmed").length;
  const pendingCount = active.length - confirmedCount;
  const card = (r, index, canChange) => {
    const stateBadge = r.status === "confirmed"
      ? badge("Confirmed", "success")
      : r.status === "waitlisted"
      ? badge("Waitlisted", "info")
      : badge("Pending", "warning");
    const teamPlayers = players(r);
    const team = h(
      "article",
      {
        class: `entry-team-card is-${r.status || "requested"}`,
        "aria-label": `Entry ${index + 1}`,
        draggable: canChange ? "true" : null,
        onDragstart: (e) => {
          if (!canChange || busy) {
            e.preventDefault();
            return;
          }
          dragging = { kind: "team_swap", source: r };
          e.currentTarget.classList.add("is-dragging");
          if (e.dataTransfer) {
            e.dataTransfer.effectAllowed = "move";
            e.dataTransfer.setData("text/plain", r.id);
          }
        },
        onDragover: (e) => {
          if (dragging?.kind === "team_swap" && dragging.source.id !== r.id) {
            e.preventDefault();
            e.currentTarget.classList.add("is-drop-target");
          }
        },
        onDragleave: (e) => e.currentTarget.classList.remove("is-drop-target"),
        onDrop: (e) => {
          e.preventDefault();
          e.currentTarget.classList.remove("is-drop-target");
          if (
            dragging?.kind === "team_swap" && dragging.source.id !== r.id
          ) action("team_swap", dragging.source, null, r);
          dragging = null;
        },
        onDragend: () => {
          dragging = null;
          for (
            const el of body.querySelectorAll(".is-dragging, .is-drop-target")
          ) el.classList.remove("is-dragging", "is-drop-target");
        },
      },
      h(
        "div",
        { class: "entry-team-heading" },
        h(
          "span",
          { class: "entry-team-label" },
          canChange
            ? h(
              "span",
              { class: "entry-drag-handle", "aria-hidden": "true", title: "Drag to move entry" },
              "⠿",
            )
            : null,
          h("span", { class: "entry-seed-num" }, `#${index + 1}`),
          h("span", { class: "entry-seed-text" }, r.meta?.team_name ?? `Entry ${index + 1}`),
        ),
        h(
          "div",
          { class: "entry-team-meta" },
          stateBadge,
          canChange
            ? iconButton({
              label: `Move Entry ${index + 1}`,
              icon: "shuffle",
              size: "sm",
              variant: "secondary",
              onClick: () => action("team_swap", r),
            })
            : null,
        ),
      ),
      h(
        "div",
        { class: "entry-team-players" },
        ...teamPlayers.map((p, playerIndex) =>
          h(
            "div",
            {
              class: `entry-player-card ${p.guest ? "is-guest" : "is-member"}`,
              draggable: canChange ? "true" : null,
              onDragstart: (e) => {
                e.stopPropagation();
                if (!canChange || busy) {
                  e.preventDefault();
                  return;
                }
                dragging = {
                  kind: "player_swap",
                  source: r,
                  player: playerIndex + 1,
                };
                e.currentTarget.classList.add("is-dragging");
                if (e.dataTransfer) {
                  e.dataTransfer.effectAllowed = "move";
                  e.dataTransfer.setData("text/plain", p.key);
                }
              },
              onDragover: (e) => {
                if (
                  dragging?.kind === "player_swap" && dragging.source.id !== r.id
                ) {
                  e.preventDefault();
                  e.stopPropagation();
                  e.currentTarget.classList.add("is-drop-target");
                }
              },
              onDragleave: (e) =>
                e.currentTarget.classList.remove("is-drop-target"),
              onDrop: (e) => {
                if (dragging?.kind !== "player_swap") return;
                e.preventDefault();
                e.stopPropagation();
                e.currentTarget.classList.remove("is-drop-target");
                if (dragging.source.id !== r.id) {
                  action(
                    "player_swap",
                    dragging.source,
                    dragging.player,
                    r,
                    playerIndex + 1,
                  );
                }
                dragging = null;
              },
            },
            h(
              "span",
              {
                class: `entry-player-icon ${p.guest ? "is-guest" : "is-member"}`,
                "aria-hidden": "true",
              },
              avatarImage(
                p.memberId ? photos?.get?.(p.memberId) : photos?.get?.(`g:${p.participantId}`),
                p.name,
              ),
            ),
            h(
              "div",
              { class: "entry-player-copy" },
              h("strong", { class: "entry-player-name" }, p.name),
              h(
                "div",
                { class: "entry-player-subrow" },
                h(
                  "span",
                  { class: `sub entry-player-role ${p.guest ? "is-guest" : "is-member"}` },
                  p.guest ? "Guest Player" : "Member",
                ),
                teamPlayers.length > 1
                  ? h("span", { class: "sub entry-player-slot" }, `· P${playerIndex + 1}`)
                  : null,
              ),
            ),
            canChange
              ? dropdownMenu({
                trigger: iconButton({
                  label: `Actions for ${p.name}`,
                  icon: "edit",
                  size: "sm",
                  variant: "secondary",
                }),
                items: [{
                  label: "Swap Player",
                  icon: "shuffle",
                  onClick: () => action("player_swap", r, playerIndex + 1),
                }, {
                  label: "Replace Player",
                  icon: "edit",
                  onClick: () => action("replace", r, playerIndex + 1),
                }],
              })
              : null,
          )
        ),
      ),
    );
    return team;
  };
  const matchupElements = Array.from(
    { length: Math.ceil(active.length / 2) },
    (_, index) =>
      h(
        "section",
        { class: "entry-matchup" },
        card(active[index * 2], index * 2, editable),
        h(
          "div",
          { class: "entry-game" },
          h("span", { class: "entry-game-pill" },
            icon("layers"),
            h("span", { class: "sub" }, "Roster"),
          ),
        ),
        active[index * 2 + 1]
          ? card(active[index * 2 + 1], index * 2 + 1, editable)
          : h(
            "div",
            { class: "entry-team-card is-pending" },
            h("span", { class: "entry-open-slot-icon", "aria-hidden": "true" }, icon("userPlus")),
            h("strong", { class: "entry-open-slot-title" }, "Open entry slot"),
            h("span", { class: "sub" }, "Awaiting paired registration"),
          ),
      ),
  );
  const filterEmpty = h(
    "p",
    { class: "sub entry-filter-empty", hidden: true },
    "No entries match your search.",
  );
  const filterInput = active.length > 2
    ? h("input", {
      type: "search",
      class: "input entry-roster-search-input",
      placeholder: "Search player or entry #…",
      "aria-label": "Filter division entries",
      onInput: (e) => {
        const q = e.target.value.trim().toLowerCase();
        let visibleCount = 0;
        for (const el of matchupElements) {
          const matched = !q || el.textContent.toLowerCase().includes(q);
          el.hidden = !matched;
          if (matched) visibleCount++;
        }
        filterEmpty.hidden = visibleCount > 0;
      },
    })
    : null;
  const body = h(
    "div",
    { class: "entry-matchups" },
    h(
      "div",
      { class: "entry-matchups-summary" },
      h(
        "div",
        { class: "entry-summary-head" },
        h(
          "div",
          { class: "entry-summary-title-group" },
          h("span", { class: "entry-summary-icon", "aria-hidden": "true" }, icon("layers")),
          h(
            "div",
            { class: "entry-summary-copy" },
            h(
              "div",
              { class: "entry-summary-title-row" },
              h("strong", {}, "Division Roster"),
              badge(`${active.length} Entries`, "neutral"),
              confirmedCount > 0 ? badge(`${confirmedCount} Confirmed`, "success") : null,
              pendingCount > 0 ? badge(`${pendingCount} Pending`, "warning") : null,
            ),
            h(
              "p",
              { class: "sub" },
              editable
                ? "Drag teams to move entries. Drag players to swap teammates. Review and save each change before the draw."
                : "Roster editing is available to administrators before the draw.",
            ),
          ),
        ),
        filterInput
          ? h(
            "div",
            { class: "entry-roster-search-wrap" },
            icon("search"),
            filterInput,
          )
          : null,
      ),
      editable && active.length > 0
        ? h(
          "div",
          { class: "entry-roster-legend" },
          h("span", { class: "entry-legend-item" }, h("kbd", {}, "⠿"), "Drag card to move team"),
          h("span", { class: "entry-legend-item" }, icon("shuffle"), "Drag player to swap partner"),
          h("span", { class: "entry-legend-item" }, icon("edit"), "Use player menu to swap or replace"),
        )
        : null,
    ),
    feedback,
    h(
      "div",
      { class: "entry-matchups-list" },
      ...matchupElements,
    ),
    filterEmpty,
    !active.length ? h("p", { class: "sub" }, "No active entries yet.") : null,
    waiting.length
      ? h(
        "section",
        { class: "entry-waitlist" },
        h(
          "div",
          { class: "entry-waitlist-head" },
          h("strong", {}, `Waitlist · ${waiting.length}`),
          h("span", { class: "sub" }, "Promoted in order when a confirmed slot opens"),
        ),
        h(
          "div",
          { class: "entry-waitlist-grid" },
          ...waiting.map((r, index) => card(r, index, false)),
        ),
      )
      : null,
  );
  const dialog = openModal({
    title: "Division Entries",
    eyebrow: `${event.name} · ${division.name}`,
    icon: "users",
    size: "lg",
    cancelLabel: "Close",
    confirmLabel: null,
    body,
  });
  return dialog;
}
