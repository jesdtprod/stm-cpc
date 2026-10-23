-- 0008_storage_payment_proofs (PLAN 1B.8)
-- Private bucket for payment proofs. Object path convention: <org_id>/<profile_id>/<file>.
--   upload : a member with payments.submit, only under their own profile folder
--   read   : the uploader, or anyone with payments.verify in that org
--   update / delete : nobody from a client (no upsert, no hard delete); removal is a soft delete
--                     of the files row plus a service-side purge after retention.
-- Size and type limits are enforced by the Storage API from the bucket settings below.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'payment-proofs', 'payment-proofs', false, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy payment_proofs_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'payment-proofs'
    and (storage.foldername(name))[2] = core.current_profile_id()
    and core.has_permission((storage.foldername(name))[1], null, 'payments.submit')
  );

create policy payment_proofs_select on storage.objects for select to authenticated
  using (
    bucket_id = 'payment-proofs'
    and (
      (storage.foldername(name))[2] = core.current_profile_id()
      or core.has_permission((storage.foldername(name))[1], null, 'payments.verify')
    )
  );
