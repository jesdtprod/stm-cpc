// Keep existing screens usable while the guest migration is awaiting rollout.
// Only missing guest schema errors qualify; permission/network errors still fail.
export function isGuestSchemaUnavailable(error) {
  const cause = error?.cause ?? error;
  return ["42703", "42P01", "PGRST200", "PGRST204", "PGRST205"].includes(
    cause?.code ?? error?.code,
  ) &&
    /\b(allow_guest_players|guest_participant_id|guest_partner_participant_id|guest_name_snapshot|guest_partner_name_snapshot|guest_rank_id|guest_partner_rank_id|payer_name_snapshot|entry_guests|dupr_id_snapshot)\b/
      .test(cause?.message ?? "");
}

export async function readGuestCompatible(read, legacyRead) {
  try {
    return await read();
  } catch (error) {
    if (!isGuestSchemaUnavailable(error)) throw error;
    return await legacyRead();
  }
}
