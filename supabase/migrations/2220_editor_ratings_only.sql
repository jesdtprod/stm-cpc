-- The Editor edits member ratings only. Profile editing is withdrawn: the function is removed and nothing checks the permission.
-- Ratings (self-assessment, Singles and Doubles) are changed by anyone holding ranks.override: Editor, Manager, Admin.
-- A member can set their own rating once; after that, or once staff has set it, only those roles can change it.
drop function if exists public.admin_update_member_profile(text, text, text, text, text, text, text, text, text, text, date, text, text, text);
drop function if exists core.admin_update_member_profile(text, text, text, text, text, text, text, text, text, text, date, text, text, text);

-- The members.edit_profile permission row stays (rows are never hard-deleted); nothing checks it any more.

update public.roles set description = 'Can set and change member ratings. Cannot edit profiles, approve, suspend or delete members.'
where code = 'editor' and deleted_at is null;

-- The Manager can override ratings too (Admin already holds every permission).
insert into public.role_permissions (org_id, role_id, permission_id)
select r.org_id, r.id, pe.id
from public.roles r
join public.orgs o on o.id = r.org_id and o.code = 'cpc'
join public.permissions pe on pe.code = 'ranks.override' and pe.deleted_at is null
where r.code = 'manager' and r.deleted_at is null
on conflict (role_id, permission_id) where deleted_at is null do nothing;

notify pgrst, 'reload schema';
