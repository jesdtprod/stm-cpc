-- Open pages hear about registration changes at once (an administrator approves or rejects, a payment is verified, a
-- waitlisted entry is confirmed). Realtime follows row-level security: a member is told only about their own registrations,
-- staff about the registrations they can read.
do $$
begin
  alter publication supabase_realtime add table public.registrations;
exception when others then
  null; -- no realtime publication (a bare local database) or already added
end $$;
