begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

select ok(core.booking_window_contains('2030-02-04 23:00', '2030-02-05 00:00', '08:00', '23:59'),
  '11 PM to midnight is inside 23:59 closing hours');
select ok(core.booking_window_contains('2030-02-04 23:00', '2030-02-05 00:00', '08:00', '23:59:59'),
  'legacy 23:59:59 closing hours allow midnight');
select ok(core.booking_window_contains('2030-02-04 23:00', '2030-02-05 00:00', '08:00', '24:00'),
  '24:00 closing hours allow midnight');
select ok(not core.booking_window_contains('2030-02-04 23:00', '2030-02-05 00:00', '08:00', '21:00'),
  'midnight does not bypass an earlier closing time');
select ok(not core.booking_window_contains('2030-02-04 23:00', '2030-02-05 01:00', '08:00', '23:59'),
  'a session cannot extend past midnight');
select ok(not core.booking_window_contains('2030-02-04 07:00', '2030-02-04 08:00', '08:00', '23:59'),
  'a session cannot start before opening');
select ok(core.booking_window_contains('2030-02-04 20:00', '2030-02-04 21:00', '08:00', '21:00'),
  'ending exactly at an ordinary closing time is allowed');
select ok(not core.booking_window_contains('2030-02-04 21:00', '2030-02-04 22:00', '08:00', '21:00'),
  'a session after an ordinary closing time is refused');

select * from finish();
rollback;
