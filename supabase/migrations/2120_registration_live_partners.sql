-- A member partner may read their team's registration, including after withdrawal/rejection.
-- This also permits Realtime to deliver those changes. All writes still use existing RPC permissions.
create policy registrations_partner_select on public.registrations for select to authenticated
  using (core.has_permission(org_id,null,'events.register')
    and core.is_own_member(meta->>'partner_member_id'));

-- Events and divisions drive the surrounding registration screen (closed/cancelled events, counts and actions).
do $$
declare table_name text;
begin
  if exists(select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach table_name in array array['registrations','events','divisions'] loop
      if not exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime'
        and schemaname = 'public' and tablename = table_name) then
        execute format('alter publication supabase_realtime add table public.%I',table_name);
      end if;
    end loop;
  end if;
end $$;
notify pgrst, 'reload schema';
