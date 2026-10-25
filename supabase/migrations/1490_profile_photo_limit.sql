-- Align private profile-photo storage with the 3 MB file-picker limit.
update storage.buckets
set file_size_limit = 3145728
where id = 'avatars';
