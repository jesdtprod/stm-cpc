-- 1440_unique_member_email: two live members cannot share an email address.
--   * A trigger on persons refuses a second live member person with the same email (case and spaces ignored) with a
--     plain message, whatever the route: sign-up, the profile screen, an import, or an admin edit.
--   * signup_email_taken(email): lets the sign-up function say so before it creates the Auth account (service role only).
-- Existing data: 65 addresses are already shared by 143 imported members (families, schools), so a unique index cannot be
-- created. The rule applies to NEW addresses only: it fires when a member person is created or its email changes, and never
-- touches a member whose shared address is left as it is. The club can clean those up over time.

create or replace function core.tg_persons_email_unique() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind = 'member' and new.deleted_at is null and nullif(btrim(coalesce(new.email, '')), '') is not null
     and (tg_op = 'INSERT' or new.email is distinct from old.email or old.deleted_at is not null) then
    -- (a restore of a deleted record counts as a new use of its address)
    if exists (
      select 1 from public.persons p
      where p.org_id = new.org_id and p.kind = 'member' and p.deleted_at is null and p.id <> new.id
        and lower(btrim(p.email)) = lower(btrim(new.email))
    ) then
      raise exception 'that email is already used by another member' using errcode = '23505';
    end if;
  end if;
  return new;
end $$;
revoke all on function core.tg_persons_email_unique() from public, anon, authenticated;
create trigger a3_persons_email_unique before insert or update of email, deleted_at on public.persons
  for each row execute function core.tg_persons_email_unique();

create or replace function public.signup_email_taken(p_email text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.persons p
    where p.kind = 'member' and p.deleted_at is null and lower(btrim(p.email)) = lower(btrim(coalesce(p_email, '')))
      and btrim(coalesce(p_email, '')) <> ''
  )
$$;
revoke all on function public.signup_email_taken(text) from public, anon, authenticated;
grant execute on function public.signup_email_taken(text) to service_role;
