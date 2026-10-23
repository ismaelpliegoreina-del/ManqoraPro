-- 003 · Reglas automáticas: teléfonos, recibos correlativos, duración de citas, auditoría

create function public.norm_phone(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(
    case
      when d like '0034%' then substr(d, 5)
      when length(d) = 11 and d like '34%' then substr(d, 3)
      else d
    end, '')
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) s
$$;

create function public.clients_before_write() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.name := trim(new.name);
  new.phone_norm := public.norm_phone(new.phone);
  new.email := nullif(lower(trim(coalesce(new.email, ''))), '');
  return new;
end $$;
create trigger clients_bw before insert or update on public.clients
  for each row execute function public.clients_before_write();

-- Numeración de recibos correlativa y atómica (un rollback también devuelve el número)
create function public.next_receipt_no(p_tenant uuid, p_at timestamptz) returns text
language plpgsql security definer set search_path = '' as $$
declare v_tz text; v_year int; v_n int;
begin
  select timezone into v_tz from public.tenants where id = p_tenant;
  v_year := extract(year from (p_at at time zone coalesce(v_tz, 'Europe/Madrid')))::int;
  insert into public.receipt_counters(tenant_id, year, last) values (p_tenant, v_year, 1)
  on conflict (tenant_id, year) do update set last = public.receipt_counters.last + 1
  returning last into v_n;
  return 'R-' || v_year || '-' || lpad(v_n::text, 4, '0');
end $$;
revoke all on function public.next_receipt_no(uuid, timestamptz) from public, anon, authenticated;

create function public.sales_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.receipt_no := public.next_receipt_no(new.tenant_id, new.sold_at);
  new.created_by := coalesce(new.created_by, (select auth.uid()));
  return new;
end $$;
create trigger sales_bi before insert on public.sales
  for each row execute function public.sales_before_insert();

-- La hora de fin se calcula (duración del servicio) si no se indica
create function public.appointments_before_insert() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.ends_at is null then
    select new.starts_at + make_interval(mins => s.duration_min)
    into new.ends_at from public.services s where s.id = new.service_id;
  end if;
  return new;
end $$;
create trigger appointments_bi before insert on public.appointments
  for each row execute function public.appointments_before_insert();

-- Auditoría de cambios de licencia
create function public.tenants_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.license_status is distinct from old.license_status or new.license_until is distinct from old.license_until then
    insert into public.audit_log(tenant_id, user_id, action, detail)
    values (new.id, (select auth.uid()), 'license_change',
      jsonb_build_object('from', old.license_status, 'to', new.license_status,
                         'until_from', old.license_until, 'until_to', new.license_until));
  end if;
  return new;
end $$;
create trigger tenants_au after update on public.tenants
  for each row execute function public.tenants_audit();

-- Auditoría de anulaciones de ventas
create function public.sales_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.annul_of is not null then
    insert into public.audit_log(tenant_id, user_id, action, detail)
    values (new.tenant_id, (select auth.uid()), 'sale_annulled',
      jsonb_build_object('sale', new.annul_of, 'receipt', new.receipt_no, 'reason', new.annul_reason));
  end if;
  return new;
end $$;
create trigger sales_ai after insert on public.sales
  for each row execute function public.sales_audit();

create function public.touch_settings() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
create trigger tenant_settings_touch before update on public.tenant_settings
  for each row execute function public.touch_settings();
