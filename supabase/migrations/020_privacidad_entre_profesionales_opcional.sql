-- 020 · "Cada Empleado solo ve lo suyo" (citas y ventas) es opcional por negocio.
-- Activado solo en gloria-bendita. Para activarlo en otro: update tenants set staff_own_only = true where slug = '...';
alter table public.tenants add column if not exists staff_own_only boolean not null default false;
update public.tenants set staff_own_only = true where slug = 'gloria-bendita';

create or replace function public.staff_can_see(t uuid, emp uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_member(t) and (
    public.role_in(t) in ('owner', 'manager')
    or not coalesce((select x.staff_own_only from public.tenants x where x.id = t), false)
    or emp = public.my_employee(t)
  )
$$;
revoke all on function public.staff_can_see(uuid, uuid) from public, anon;
grant execute on function public.staff_can_see(uuid, uuid) to authenticated;

drop policy appointments_sel on public.appointments;
create policy appointments_sel on public.appointments for select to authenticated using (public.staff_can_see(tenant_id, employee_id));

drop policy sales_sel on public.sales;
create policy sales_sel on public.sales for select to authenticated using (public.staff_can_see(tenant_id, employee_id));

drop policy sale_items_sel on public.sale_items;
create policy sale_items_sel on public.sale_items for select to authenticated using (
  public.is_member(tenant_id) and exists (select 1 from public.sales s where s.id = sale_id));
