-- 1441_unique_member_email_normalized (fixes 1440): saving a profile lowercases the email, so a member whose shared address is
-- stored in another case would look like a change and be refused. Compare the cleaned addresses instead.
create or replace function core.tg_persons_email_unique() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind = 'member' and new.deleted_at is null and nullif(btrim(coalesce(new.email, '')), '') is not null
     and (tg_op = 'INSERT' or old.deleted_at is not null
          or lower(btrim(new.email)) is distinct from lower(btrim(coalesce(old.email, '')))) then
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
