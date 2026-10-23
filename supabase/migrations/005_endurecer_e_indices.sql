-- 005 · Endurecimiento (funciones de trigger no invocables desde la API) e índices de claves foráneas
revoke all on function public.sales_audit(), public.sales_before_insert(), public.tenants_audit() from public, anon, authenticated;

drop index if exists public.appointments_client_idx;
create index appointments_client_fk_idx on public.appointments (client_id, tenant_id);
create index appointments_employee_fk_idx on public.appointments (employee_id, tenant_id);
create index appointments_service_fk_idx on public.appointments (service_id, tenant_id);
create index appointment_addons_tenant_idx on public.appointment_addons (tenant_id);
create index appointment_addons_upsell_idx on public.appointment_addons (upsell_id);
create index audit_log_tenant_idx on public.audit_log (tenant_id, created_at);
create index employees_tenant_idx on public.employees (tenant_id);
create index expenses_tenant_idx on public.expenses (tenant_id, spent_on);
create index members_employee_idx on public.members (employee_id);
create index members_user_idx on public.members (user_id);
create index outbox_tenant_idx on public.outbox_emails (tenant_id);
create index products_tenant_idx on public.products (tenant_id);
create index sale_items_tenant_idx on public.sale_items (tenant_id);
create index sales_appointment_idx on public.sales (appointment_id);
create index sales_client_fk_idx on public.sales (client_id, tenant_id);
create index sales_employee_fk_idx on public.sales (employee_id, tenant_id);
create index stock_movements_product_idx on public.stock_movements (product_id);
create index stock_movements_tenant_idx on public.stock_movements (tenant_id);
create index time_blocks_tenant_idx on public.time_blocks (tenant_id);
create index upsells_tenant_idx on public.upsells (tenant_id);
create index waitlist_tenant_idx on public.waitlist (tenant_id);
