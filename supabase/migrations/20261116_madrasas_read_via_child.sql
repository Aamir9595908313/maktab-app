-- Parents/students could not read the madrasas table (it is scoped to staff
-- madrasas), so the app could not resolve the child's Maktab id and the
-- Attendance report showed "Could not load attendance". Allow reading a
-- madrasa row only when the user can already see a student of that madrasa
-- (the students RLS inside the subquery limits this to their own children).
drop policy if exists madrasas_read_via_child on public.madrasas;
create policy madrasas_read_via_child on public.madrasas for select to authenticated
using (exists (select 1 from public.students s where s.madrasa_id = madrasas.id));
