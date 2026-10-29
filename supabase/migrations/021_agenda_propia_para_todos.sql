-- 021 · La agenda propia del Empleado vale para todos los negocios; ventas/ganancias siguen siendo opcionales (staff_own_only).
create or replace function public.staff_sees_appt(t uuid, emp uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_member(t) and (public.role_in(t) in ('owner', 'manager') or emp = public.my_employee(t))
$$;
revoke all on function public.staff_sees_appt(uuid, uuid) from public, anon;
grant execute on function public.staff_sees_appt(uuid, uuid) to authenticated;
drop policy appointments_sel on public.appointments;
create policy appointments_sel on public.appointments for select to authenticated using (public.staff_sees_appt(tenant_id, employee_id));
