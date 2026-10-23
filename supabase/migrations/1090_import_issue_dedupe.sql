-- 1090_import_issue_dedupe (PLAN 3.2)
-- A re-run of the import (after the club fixes rows in Excel) sends the same unresolved problems again.
-- Record an issue only if the same problem (same spreadsheet row, same kind, same member number) is not
-- already open from an earlier batch, so the review list does not fill with copies.

create or replace function core.import_issue(
  p_batch_id text, p_source_row integer, p_member_no text, p_code text, p_member_id text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  org text;
begin
  select org_id into org from public.import_batches where id = p_batch_id;
  if org is null then
    raise exception 'unknown import batch' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.member_import_issues i
    where i.org_id = org and i.source_row = p_source_row and i.issue_code = p_code
      and i.member_no_claimed is not distinct from p_member_no
      and i.resolved_at is null and i.deleted_at is null and i.batch_id <> p_batch_id
  ) then
    return;
  end if;
  insert into public.member_import_issues (org_id, batch_id, member_id, source_row, member_no_claimed, issue_code)
  values (org, p_batch_id, p_member_id, p_source_row, p_member_no, p_code)
  on conflict (batch_id, source_row, issue_code) where deleted_at is null do nothing;
end $$;
