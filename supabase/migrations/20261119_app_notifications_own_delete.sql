-- Lets each user delete their own alerts (inbox "Delete" / "Select all").
grant delete on public.app_notifications to authenticated;
create policy app_notifications_own_delete on public.app_notifications
  for delete to authenticated using (user_id = auth.uid());
