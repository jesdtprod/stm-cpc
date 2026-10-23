-- 1180_no_password_expiry
-- Club decision: first passwords do not expire. They are still replaced at the first sign-in (forced change), and
-- the other safeguards stay (Turnstile, lockout, generic errors, the password policy).
-- temp_password_expires_at stays in the schema (null means no expiry) so an expiry can be switched on again
-- later by setting members.temp_password_days above 0 and stamping new accounts.

update public.member_access set temp_password_expires_at = null where temp_password_expires_at is not null;

update public.settings set value = '0'::jsonb
where key = 'members.temp_password_days' and deleted_at is null and unit_id is null;
