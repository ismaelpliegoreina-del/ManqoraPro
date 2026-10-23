-- 002 · Seguridad: funciones auxiliares, permisos y RLS

-- Funciones auxiliares (security definer, solo para usuarios autenticados)
create function public.is_member(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m
    where m.tenant_id = t and m.user_id = (select auth.uid()) and m.active)
$$;

create function public.role_in(t uuid) returns text
language sql stable security definer set search_path = '' as $$
  select m.role from public.members m
  where m.tenant_id = t and m.user_id = (select auth.uid()) and m.active
$$;

create function public.tenant_writable(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tenants x
    where x.id = t and x.license_status = 'active'
      and (x.license_until is null or x.license_until >= current_date))
$$;

revoke all on function public.is_member(uuid), public.role_in(uuid), public.tenant_writable(uuid) from public, anon;
grant execute on function public.is_member(uuid), public.role_in(uuid), public.tenant_writable(uuid) to authenticated;

-- RLS en todas las tablas
do $$
declare t text;
begin
  foreach t in array array['tenants','tenant_settings','members','employees','services','upsells','clients',
    'appointments','appointment_addons','sales','sale_items','receipt_counters','products','stock_movements',
    'expenses','cash_closures','waitlist','closed_days','time_blocks','outbox_emails','audit_log','booking_attempts']
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Quitar permisos por defecto a anon y authenticated; se conceden solo los necesarios
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- 1) Lectura para cualquier miembro; escritura solo propietario/encargado y licencia activa
do $$
declare t text;
begin
  foreach t in array array['employees','services','upsells','products','closed_days','time_blocks']
  loop
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_member(tenant_id))', t||'_sel', t);
    execute format($f$create policy %I on public.%I for insert to authenticated with check (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id))$f$, t||'_ins', t);
    execute format($f$create policy %I on public.%I for update to authenticated using (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id)) with check (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id))$f$, t||'_upd', t);
    execute format($f$create policy %I on public.%I for delete to authenticated using (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id))$f$, t||'_del', t);
  end loop;
end $$;

-- 2) Operativa diaria: cualquier miembro lee y escribe (con licencia activa)
do $$
declare t text;
begin
  foreach t in array array['clients','appointments','appointment_addons','waitlist']
  loop
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_member(tenant_id))', t||'_sel', t);
    execute format($f$create policy %I on public.%I for insert to authenticated with check (public.role_in(tenant_id) is not null and public.tenant_writable(tenant_id))$f$, t||'_ins', t);
    execute format($f$create policy %I on public.%I for update to authenticated using (public.role_in(tenant_id) is not null and public.tenant_writable(tenant_id)) with check (public.role_in(tenant_id) is not null and public.tenant_writable(tenant_id))$f$, t||'_upd', t);
  end loop;
end $$;
-- borrar citas/clientes/lista de espera: solo propietario o encargado
create policy clients_del on public.clients for delete to authenticated
  using (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id));
create policy appointments_del on public.appointments for delete to authenticated
  using (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id));
create policy appointment_addons_del on public.appointment_addons for delete to authenticated
  using (public.role_in(tenant_id) is not null and public.tenant_writable(tenant_id));
create policy waitlist_del on public.waitlist for delete to authenticated
  using (public.role_in(tenant_id) is not null and public.tenant_writable(tenant_id));

-- 3) Ventas: se pueden leer y crear, nunca modificar ni borrar (las correcciones son anulaciones)
grant select, insert on public.sales, public.sale_items, public.stock_movements to authenticated;
create policy sales_sel on public.sales for select to authenticated using (public.is_member(tenant_id));
create policy sales_ins on public.sales for insert to authenticated
  with check (public.role_in(tenant_id) is not null and public.tenant_writable(tenant_id));
create policy sale_items_sel on public.sale_items for select to authenticated using (public.is_member(tenant_id));
create policy sale_items_ins on public.sale_items for insert to authenticated
  with check (public.role_in(tenant_id) is not null and public.tenant_writable(tenant_id));
create policy stock_movements_sel on public.stock_movements for select to authenticated using (public.is_member(tenant_id));
create policy stock_movements_ins on public.stock_movements for insert to authenticated
  with check (public.role_in(tenant_id) is not null and public.tenant_writable(tenant_id));

-- 4) Gestión económica: solo propietario y encargado
do $$
declare t text;
begin
  foreach t in array array['expenses','cash_closures']
  loop
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format($f$create policy %I on public.%I for select to authenticated using (public.role_in(tenant_id) in ('owner','manager'))$f$, t||'_sel', t);
    execute format($f$create policy %I on public.%I for insert to authenticated with check (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id))$f$, t||'_ins', t);
    execute format($f$create policy %I on public.%I for update to authenticated using (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id)) with check (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id))$f$, t||'_upd', t);
    execute format($f$create policy %I on public.%I for delete to authenticated using (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id))$f$, t||'_del', t);
  end loop;
end $$;

-- 5) Negocio y ajustes
grant select on public.tenants to authenticated;
create policy tenants_sel on public.tenants for select to authenticated using (public.is_member(id));
-- (la licencia solo se cambia desde el panel de Supabase / cuenta de plataforma)

grant select, update on public.tenant_settings to authenticated;
create policy tenant_settings_sel on public.tenant_settings for select to authenticated using (public.is_member(tenant_id));
create policy tenant_settings_upd on public.tenant_settings for update to authenticated
  using (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id))
  with check (public.role_in(tenant_id) in ('owner','manager') and public.tenant_writable(tenant_id));

-- 6) Miembros: se ven a sí mismos; propietario y encargado ven a todos; solo el propietario gestiona
grant select, insert, update, delete on public.members to authenticated;
create policy members_sel on public.members for select to authenticated
  using (user_id = (select auth.uid()) or public.role_in(tenant_id) in ('owner','manager'));
create policy members_ins on public.members for insert to authenticated
  with check (public.role_in(tenant_id) = 'owner');
create policy members_upd on public.members for update to authenticated
  using (public.role_in(tenant_id) = 'owner') with check (public.role_in(tenant_id) = 'owner');
create policy members_del on public.members for delete to authenticated
  using (public.role_in(tenant_id) = 'owner');

-- 7) Solo lectura para propietario y encargado
grant select on public.outbox_emails, public.audit_log to authenticated;
create policy outbox_sel on public.outbox_emails for select to authenticated using (public.role_in(tenant_id) in ('owner','manager'));
create policy audit_sel on public.audit_log for select to authenticated using (public.role_in(tenant_id) in ('owner','manager'));

-- receipt_counters y booking_attempts: sin políticas ni permisos (solo funciones internas)
