-- Set the club's inactivity timeout to 30 minutes; read by the app at sign-in.
-- Applied after the original seed on both existing and fresh databases.
update public.settings set value = '30'::jsonb
where key = 'session.idle_minutes' and deleted_at is null
  and value is distinct from '30'::jsonb;
