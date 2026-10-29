-- 022 · Gastos por profesional (solo en negocios con staff_own_only): cada Empleado crea, ve, edita y borra los suyos.
alter table public.expenses add column if not exists employee_id uuid references public.employees(id) on delete set null;

create or replace function public.staff_own_expense(t uuid, emp uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.role_in(t) = 'staff'
     and coalesce((select x.staff_own_only from public.tenants x where x.id = t), false)
     and emp is not null and emp = public.my_employee(t)
$$;
revoke all on function public.staff_own_expense(uuid, uuid) from public, anon;
grant execute on function public.staff_own_expense(uuid, uuid) to authenticated;

create or replace function public.expenses_set_owner() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if public.role_in(new.tenant_id) = 'staff'
     and coalesce((select x.staff_own_only from public.tenants x where x.id = new.tenant_id), false) then
    new.employee_id := public.my_employee(new.tenant_id);
  end if;
  return new;
end $$;
drop trigger if exists expenses_set_owner on public.expenses;
create trigger expenses_set_owner before insert on public.expenses for each row execute function public.expenses_set_owner();

drop policy expenses_sel on public.expenses;
create policy expenses_sel on public.expenses for select to authenticated using (
  public.role_in(tenant_id) in ('owner', 'manager') or public.staff_own_expense(tenant_id, employee_id));
drop policy expenses_ins on public.expenses;
create policy expenses_ins on public.expenses for insert to authenticated with check (
  public.tenant_writable(tenant_id) and (public.role_in(tenant_id) in ('owner', 'manager') or public.staff_own_expense(tenant_id, employee_id)));
drop policy expenses_upd on public.expenses;
create policy expenses_upd on public.expenses for update to authenticated
  using (public.tenant_writable(tenant_id) and (public.role_in(tenant_id) in ('owner', 'manager') or public.staff_own_expense(tenant_id, employee_id)))
  with check (public.tenant_writable(tenant_id) and (public.role_in(tenant_id) in ('owner', 'manager') or public.staff_own_expense(tenant_id, employee_id)));
drop policy expenses_del on public.expenses;
create policy expenses_del on public.expenses for delete to authenticated using (
  public.tenant_writable(tenant_id) and (public.role_in(tenant_id) in ('owner', 'manager') or public.staff_own_expense(tenant_id, employee_id)));
