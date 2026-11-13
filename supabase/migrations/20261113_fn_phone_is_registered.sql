create or replace function public.fn_phone_is_registered(p_phone text) returns boolean
language sql security definer set search_path=public stable as $$
  select exists(select 1 from user_profiles where right(regexp_replace(coalesce(phone,''),'\D','','g'),10)=p_phone and coalesce(is_active,true))
      or exists(select 1 from pending_role_invites where right(regexp_replace(coalesce(phone,''),'\D','','g'),10)=p_phone)
      or exists(select 1 from students where right(regexp_replace(coalesce(parent_phone,''),'\D','','g'),10)=p_phone);
$$;
revoke all on function public.fn_phone_is_registered(text) from public;
grant execute on function public.fn_phone_is_registered(text) to anon, authenticated;
