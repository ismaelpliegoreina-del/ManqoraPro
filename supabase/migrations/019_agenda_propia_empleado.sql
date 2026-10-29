-- 019 · Un Empleado (staff) solo ve sus propias citas; propietario y encargado ven todas.
create or replace function public.my_employee(t uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select m.employee_id from public.members m
  where m.tenant_id = t and m.user_id = (select auth.uid()) and m.active limit 1
$$;
revoke all on function public.my_employee(uuid) from public, anon;
grant execute on function public.my_employee(uuid) to authenticated;

drop policy appointments_sel on public.appointments;
create policy appointments_sel on public.appointments for select to authenticated using (
  public.is_member(tenant_id) and (
    public.role_in(tenant_id) in ('owner', 'manager') or employee_id = public.my_employee(tenant_id)
  )
);

drop policy appointment_addons_sel on public.appointment_addons;
create policy appointment_addons_sel on public.appointment_addons for select to authenticated using (
  public.is_member(tenant_id) and exists (select 1 from public.appointments a where a.id = appointment_id)
);
