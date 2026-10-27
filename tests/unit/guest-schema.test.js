import assert from "node:assert/strict";
import {
  isGuestSchemaUnavailable,
  readGuestCompatible,
} from "../../web/lib/guest-schema.js";

Deno.test("guest rollout: existing events load before the guest migration", async () => {
  const rows = [{ id: "fake-event", name: "Fake Existing Event" }];
  let fallback = 0;
  const error = new Error("Request failed", {
    cause: {
      code: "42703",
      message: "column events.allow_guest_players does not exist",
    },
  });
  assert.equal(
    await readGuestCompatible(() => Promise.reject(error), () => {
      fallback++;
      return rows;
    }),
    rows,
  );
  assert.equal(fallback, 1);
});

Deno.test("guest rollout: migrated screens keep guest fields", async () => {
  const rows = [{ id: "fake-event", allow_guest_players: true }];
  assert.equal(
    await readGuestCompatible(() => Promise.resolve(rows), () => {
      throw new Error("Unexpected fallback");
    }),
    rows,
  );
});

Deno.test("guest rollout: only missing guest fields and relationships permit fallback", () => {
  for (
    const [code, message] of [
      ["42703", "column registrations.guest_participant_id does not exist"],
      [
        "42703",
        "column payment_submissions.payer_name_snapshot does not exist",
      ],
      ["42703", "column event_participants.dupr_id_snapshot does not exist"],
      [
        "PGRST200",
        "Could not find a relationship between entries and entry_guests in the schema cache",
      ],
    ]
  ) assert(isGuestSchemaUnavailable({ code, message }));
  for (
    const [code, message] of [
      ["42501", "Permission denied for entry_guests"],
      ["42703", "column events.name does not exist"],
      ["network", "allow_guest_players unavailable"],
    ]
  ) assert(!isGuestSchemaUnavailable({ code, message }));
});

Deno.test("guest rollout: other failures and legacy query failures stay visible", async () => {
  const permission = { code: "42501", message: "Permission denied" };
  let fallback = false;
  await assert.rejects(
    readGuestCompatible(() => Promise.reject(permission), () => {
      fallback = true;
    }),
  );
  assert.equal(fallback, false);
  const missing = {
    code: "42703",
    message: "column events.allow_guest_players does not exist",
  };
  const failure = new Error("Legacy read failed");
  await assert.rejects(
    readGuestCompatible(
      () => Promise.reject(missing),
      () => Promise.reject(failure),
    ),
    failure,
  );
});
