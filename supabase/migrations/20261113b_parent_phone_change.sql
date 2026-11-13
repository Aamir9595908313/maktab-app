-- When a student's parent_phone changes: the child's records already follow the
-- number (parents are matched by students.parent_phone), so the NEW number sees
-- the child automatically. This trigger also (1) pre-registers the new number as
-- a parent so the right role is assigned at first login, and (2) retires the OLD
-- number's parent login if it no longer has any child.
create or replace function public.fn_parent_phone_changed() returns trigger
language plpgsql security definer set search_path=public as $$
declare o text; n text;
begin
  o := right(regexp_replace(coalesce(old.parent_phone,''),'\D','','g'),10);
  n := right(regexp_replace(coalesce(new.parent_phone,''),'\D','','g'),10);
  if o = n or length(n) <> 10 then return new; end if;

  if not exists (select 1 from user_profiles where right(regexp_replace(coalesce(phone,''),'\D','','g'),10)=n)
     and not exists (select 1 from pending_role_invites where right(regexp_replace(coalesce(phone,''),'\D','','g'),10)=n) then
    insert into pending_role_invites(phone, base_role, full_name, created_by)
    values ('91'||n, 'parent', coalesce(new.father_name, 'Parent'), auth.uid())
    on conflict (phone) do nothing;
  end if;

  if length(o) = 10 and not exists (select 1 from students where id <> new.id
       and right(regexp_replace(coalesce(parent_phone,''),'\D','','g'),10)=o) then
    update user_profiles set is_active=false
      where right(regexp_replace(coalesce(phone,''),'\D','','g'),10)=o and base_role='parent';
    delete from pending_role_invites
      where right(regexp_replace(coalesce(phone,''),'\D','','g'),10)=o and base_role='parent';
  end if;
  return new;
end $$;
drop trigger if exists trg_parent_phone_changed on public.students;
create trigger trg_parent_phone_changed after update of parent_phone on public.students
  for each row execute function public.fn_parent_phone_changed();
