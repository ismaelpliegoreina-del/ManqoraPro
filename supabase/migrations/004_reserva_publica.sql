-- 004 · Reserva pública: funciones (RPC) que usa la web del cliente. Sin acceso directo a tablas.

create function public.req_ip() returns text
language sql stable set search_path = '' as $$
  select coalesce(nullif(split_part(coalesce((nullif(current_setting('request.headers', true), ''))::json ->> 'x-forwarded-for', ''), ',', 1), ''), 'noip')
$$;

-- Límite de intentos: devuelve false si se supera
create function public.rl_hit(p_key text, p_max int, p_window interval) returns boolean
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into public.booking_attempts(key) values (p_key);
  select count(*) into n from public.booking_attempts where key = p_key and created_at > now() - p_window;
  return n <= p_max;
end $$;

-- ¿Cabe un servicio de p_dur minutos en esa hora con ese profesional? (horario, descansos, bloqueos, festivos)
create function public.slot_valid(p_tenant uuid, p_emp uuid, p_dur int, p_starts timestamptz) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz text; ls timestamp; le timestamp; d date; dow int; sch jsonb; st jsonb; brk jsonb;
  v_open time := '09:00'; v_close time := '20:00'; f time; tt time;
begin
  if p_starts <= now() then return false; end if;
  select timezone into v_tz from public.tenants where id = p_tenant;
  ls := p_starts at time zone v_tz;
  le := ls + make_interval(mins => p_dur);
  d := ls::date;
  if le::date <> d then return false; end if;
  select schedule into sch from public.employees where id = p_emp and tenant_id = p_tenant and active;
  if not found then return false; end if;
  dow := extract(dow from d)::int;
  st := coalesce(sch -> (dow::text), jsonb_build_object('on', dow <> 0));
  if not coalesce((st ->> 'on')::boolean, true) then return false; end if;
  select coalesce(nullif(ts.settings ->> 'opening', ''), '09:00')::time, coalesce(nullif(ts.settings ->> 'closing', ''), '20:00')::time
    into v_open, v_close from public.tenant_settings ts where ts.tenant_id = p_tenant;
  f := coalesce(nullif(st ->> 'from', ''), v_open::text)::time;
  tt := coalesce(nullif(st ->> 'to', ''), v_close::text)::time;
  if ls::time < f or le::time > tt then return false; end if;
  brk := st -> 'brk';
  if brk is not null and jsonb_typeof(brk) = 'object' and (brk ->> 'from') is not null and (brk ->> 'to') is not null then
    if ls::time < (brk ->> 'to')::time and le::time > (brk ->> 'from')::time then return false; end if;
  end if;
  if exists (select 1 from public.closed_days c where c.tenant_id = p_tenant and c.day = d) then return false; end if;
  if exists (select 1 from public.time_blocks b
             where b.tenant_id = p_tenant and (b.employee_id is null or b.employee_id = p_emp)
               and d between b.from_day and b.to_day
               and (b.kind = 'off'
                    or (ls::time < coalesce(b.end_time, time '23:59:59') and le::time > coalesce(b.start_time, time '00:00')))) then
    return false;
  end if;
  return true;
end $$;

revoke all on function public.req_ip(), public.rl_hit(text,int,interval), public.slot_valid(uuid,uuid,int,timestamptz) from public, anon, authenticated;

-- Datos públicos del negocio para pintar la web de reservas
create function public.public_business(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare t public.tenants; ts public.tenant_settings;
begin
  select * into t from public.tenants where slug = lower(coalesce(p_slug, ''));
  if not found or t.license_status = 'suspended' then
    return jsonb_build_object('ok', false, 'error', 'unavailable');
  end if;
  select * into ts from public.tenant_settings where tenant_id = t.id;
  return jsonb_build_object(
    'ok', true,
    'name', t.name,
    'timezone', t.timezone,
    'bookable', (t.license_status = 'active' and (t.license_until is null or t.license_until >= current_date)),
    'cancel_min_hours', t.cancel_min_hours,
    'business', jsonb_build_object(
      'name', ts.business -> 'name', 'address', ts.business -> 'address',
      'phone', ts.business -> 'phone', 'email', ts.business -> 'email'),
    'opening', coalesce(nullif(ts.settings ->> 'opening', ''), '09:00'),
    'closing', coalesce(nullif(ts.settings ->> 'closing', ''), '20:00'),
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'duration_min', s.duration_min, 'price', s.price) order by s.name)
                          from public.services s where s.tenant_id = t.id and s.active), '[]'::jsonb),
    'employees', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'color', e.color) order by e.name)
                           from public.employees e where e.tenant_id = t.id and e.active), '[]'::jsonb),
    'upsells', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'price', u.price, 'extra_min', u.extra_min) order by u.name)
                         from public.upsells u where u.tenant_id = t.id and u.active), '[]'::jsonb)
  );
end $$;

-- Horas libres de un día (el servidor calcula; el navegador solo las pinta)
create function public.public_slots(p_slug text, p_service uuid, p_day date, p_employee uuid default null, p_upsells uuid[] default '{}')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t public.tenants; s public.services; v_dur int; r record; m int; ls timestamp; v_start timestamptz; v_out jsonb := '[]'::jsonb;
begin
  select * into t from public.tenants where slug = lower(coalesce(p_slug, ''));
  if not found or t.license_status <> 'active' or (t.license_until is not null and t.license_until < current_date) then
    return jsonb_build_object('ok', false, 'error', 'unavailable');
  end if;
  if p_day is null or p_day < (now() at time zone t.timezone)::date or p_day > (now() at time zone t.timezone)::date + 120 then
    return jsonb_build_object('ok', false, 'error', 'invalid_day');
  end if;
  select * into s from public.services where id = p_service and tenant_id = t.id and active;
  if not found then return jsonb_build_object('ok', false, 'error', 'invalid_service'); end if;
  v_dur := s.duration_min + coalesce((select sum(u.extra_min) from public.upsells u where u.id = any(coalesce(p_upsells, '{}')) and u.tenant_id = t.id and u.active), 0);
  for r in select e.id from public.employees e where e.tenant_id = t.id and e.active and (p_employee is null or e.id = p_employee) order by e.name loop
    for m in 0..1410 by 30 loop
      ls := p_day::timestamp + make_interval(mins => m);
      v_start := ls at time zone t.timezone;
      if public.slot_valid(t.id, r.id, v_dur, v_start)
         and not exists (select 1 from public.appointments a
                         where a.employee_id = r.id and a.status in ('pending', 'confirmed')
                           and tstzrange(a.starts_at, a.ends_at, '[)') && tstzrange(v_start, v_start + make_interval(mins => v_dur), '[)')) then
        v_out := v_out || jsonb_build_object('employee_id', r.id, 'time', to_char(ls, 'HH24:MI'), 'starts_at', v_start);
      end if;
    end loop;
  end loop;
  return jsonb_build_object('ok', true, 'duration_min', v_dur, 'slots', v_out);
end $$;

-- Crear una reserva online. Teléfono y email obligatorios. La base de datos impide el solape.
create function public.public_book(
  p_slug text, p_service uuid, p_employee uuid, p_starts timestamptz,
  p_name text, p_phone text, p_email text,
  p_consent_privacy boolean, p_consent_marketing boolean default false, p_upsells uuid[] default '{}'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  t public.tenants; s public.services; e public.employees; c public.clients; a public.appointments;
  v_phone text; v_email text; v_name text; v_dur int; v_lim int; v_status text; v_ends timestamptz;
begin
  if not public.rl_hit('ip:' || public.req_ip(), 30, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  select * into t from public.tenants where slug = lower(coalesce(p_slug, ''));
  if not found or t.license_status <> 'active' or (t.license_until is not null and t.license_until < current_date) then
    return jsonb_build_object('ok', false, 'error', 'unavailable');
  end if;
  if coalesce(p_consent_privacy, false) is not true then
    return jsonb_build_object('ok', false, 'error', 'consent_required');
  end if;
  v_name := trim(coalesce(p_name, ''));
  if length(v_name) < 2 or length(v_name) > 80 then return jsonb_build_object('ok', false, 'error', 'invalid_name'); end if;
  v_email := lower(trim(coalesce(p_email, '')));
  if length(v_email) > 120 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'invalid_email'); end if;
  v_phone := public.norm_phone(p_phone);
  if v_phone is null or length(v_phone) < 9 or length(v_phone) > 15 then return jsonb_build_object('ok', false, 'error', 'invalid_phone'); end if;
  if not public.rl_hit('ph:' || t.id || ':' || v_phone, 5, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  select * into s from public.services where id = p_service and tenant_id = t.id and active;
  if not found then return jsonb_build_object('ok', false, 'error', 'invalid_service'); end if;
  select * into e from public.employees where id = p_employee and tenant_id = t.id and active;
  if not found then return jsonb_build_object('ok', false, 'error', 'invalid_employee'); end if;
  v_dur := s.duration_min + coalesce((select sum(u.extra_min) from public.upsells u where u.id = any(coalesce(p_upsells, '{}')) and u.tenant_id = t.id and u.active), 0);
  if not public.slot_valid(t.id, e.id, v_dur, p_starts) then
    return jsonb_build_object('ok', false, 'error', 'slot_unavailable');
  end if;
  v_ends := p_starts + make_interval(mins => v_dur);

  insert into public.clients(tenant_id, name, phone, email, consent_marketing, consent_at)
  values (t.id, v_name, p_phone, v_email, coalesce(p_consent_marketing, false), now())
  on conflict (tenant_id, phone_norm) where anonymized_at is null do nothing;
  select * into c from public.clients where tenant_id = t.id and phone_norm = v_phone and anonymized_at is null;
  -- un cliente existente no se modifica desde la web pública, salvo rellenar un email vacío
  if c.email is null then update public.clients set email = v_email where id = c.id returning * into c; end if;

  v_lim := coalesce(nullif((select ts.settings ->> 'noshowLimit' from public.tenant_settings ts where ts.tenant_id = t.id), '')::int, 2);
  v_status := case when c.noshows >= v_lim then 'pending' else 'confirmed' end;

  begin
    insert into public.appointments(tenant_id, client_id, service_id, employee_id, starts_at, ends_at, status, source)
    values (t.id, c.id, s.id, e.id, p_starts, v_ends, v_status, 'online')
    returning * into a;
  exception when exclusion_violation then
    return jsonb_build_object('ok', false, 'error', 'slot_taken');
  end;

  insert into public.appointment_addons(appointment_id, upsell_id, tenant_id, price)
  select a.id, u.id, t.id, u.price from public.upsells u where u.id = any(coalesce(p_upsells, '{}')) and u.tenant_id = t.id and u.active;

  insert into public.outbox_emails(tenant_id, to_email, template, payload)
  values (t.id, c.email, case when v_status = 'pending' then 'pending' else 'confirm' end,
          jsonb_build_object('code', a.code, 'starts_at', a.starts_at, 'service', s.name, 'employee', e.name, 'business', t.name, 'name', c.name));

  return jsonb_build_object('ok', true, 'code', a.code, 'status', a.status, 'starts_at', a.starts_at, 'ends_at', a.ends_at);
end $$;

-- «Mi cita»
create function public.public_get_appointment(p_slug text, p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t public.tenants; a public.appointments; s public.services; e public.employees; c public.clients;
begin
  if not public.rl_hit('get:' || public.req_ip(), 60, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  select * into t from public.tenants where slug = lower(coalesce(p_slug, ''));
  if not found or t.license_status = 'suspended' then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select * into a from public.appointments where tenant_id = t.id and code = upper(trim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select * into s from public.services where id = a.service_id;
  select * into e from public.employees where id = a.employee_id;
  select * into c from public.clients where id = a.client_id;
  return jsonb_build_object('ok', true, 'code', a.code, 'status', a.status, 'starts_at', a.starts_at, 'ends_at', a.ends_at,
    'service', s.name, 'price', s.price, 'employee', e.name, 'first_name', split_part(c.name, ' ', 1), 'business', t.name,
    'can_change', (a.status in ('pending', 'confirmed') and a.starts_at - make_interval(hours => t.cancel_min_hours) > now()),
    'cancel_min_hours', t.cancel_min_hours);
end $$;

create function public.public_cancel(p_slug text, p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t public.tenants; a public.appointments; c public.clients; s public.services;
begin
  if not public.rl_hit('can:' || public.req_ip(), 20, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  select * into t from public.tenants where slug = lower(coalesce(p_slug, ''));
  if not found or t.license_status = 'suspended' then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select * into a from public.appointments where tenant_id = t.id and code = upper(trim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if a.status not in ('pending', 'confirmed') then return jsonb_build_object('ok', false, 'error', 'not_cancellable'); end if;
  if a.starts_at - make_interval(hours => t.cancel_min_hours) <= now() then
    return jsonb_build_object('ok', false, 'error', 'too_late', 'cancel_min_hours', t.cancel_min_hours);
  end if;
  update public.appointments set status = 'cancelled', cancelled_by = 'client', cancelled_at = now() where id = a.id;
  select * into c from public.clients where id = a.client_id;
  select * into s from public.services where id = a.service_id;
  if c.email is not null then
    insert into public.outbox_emails(tenant_id, to_email, template, payload)
    values (t.id, c.email, 'cancel', jsonb_build_object('code', a.code, 'starts_at', a.starts_at, 'service', s.name, 'business', t.name, 'name', c.name));
  end if;
  return jsonb_build_object('ok', true);
end $$;

create function public.public_reschedule(p_slug text, p_code text, p_new_start timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t public.tenants; a public.appointments; c public.clients; s public.services; v_dur int;
begin
  if not public.rl_hit('res:' || public.req_ip(), 20, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  select * into t from public.tenants where slug = lower(coalesce(p_slug, ''));
  if not found or t.license_status <> 'active' or (t.license_until is not null and t.license_until < current_date) then
    return jsonb_build_object('ok', false, 'error', 'unavailable');
  end if;
  select * into a from public.appointments where tenant_id = t.id and code = upper(trim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if a.status not in ('pending', 'confirmed') then return jsonb_build_object('ok', false, 'error', 'not_changeable'); end if;
  if a.starts_at - make_interval(hours => t.cancel_min_hours) <= now() then
    return jsonb_build_object('ok', false, 'error', 'too_late', 'cancel_min_hours', t.cancel_min_hours);
  end if;
  v_dur := (extract(epoch from (a.ends_at - a.starts_at)) / 60)::int;
  if not public.slot_valid(t.id, a.employee_id, v_dur, p_new_start) then
    return jsonb_build_object('ok', false, 'error', 'slot_unavailable');
  end if;
  begin
    update public.appointments set starts_at = p_new_start, ends_at = p_new_start + make_interval(mins => v_dur), reminded_at = null where id = a.id
    returning * into a;
  exception when exclusion_violation then
    return jsonb_build_object('ok', false, 'error', 'slot_taken');
  end;
  select * into c from public.clients where id = a.client_id;
  select * into s from public.services where id = a.service_id;
  if c.email is not null then
    insert into public.outbox_emails(tenant_id, to_email, template, payload)
    values (t.id, c.email, 'change', jsonb_build_object('code', a.code, 'starts_at', a.starts_at, 'service', s.name, 'business', t.name, 'name', c.name));
  end if;
  return jsonb_build_object('ok', true, 'starts_at', a.starts_at, 'ends_at', a.ends_at);
end $$;

revoke all on function public.public_business(text), public.public_slots(text,uuid,date,uuid,uuid[]),
  public.public_book(text,uuid,uuid,timestamptz,text,text,text,boolean,boolean,uuid[]),
  public.public_get_appointment(text,text), public.public_cancel(text,text), public.public_reschedule(text,text,timestamptz) from public;
grant execute on function public.public_business(text), public.public_slots(text,uuid,date,uuid,uuid[]),
  public.public_book(text,uuid,uuid,timestamptz,text,text,text,boolean,boolean,uuid[]),
  public.public_get_appointment(text,text), public.public_cancel(text,text), public.public_reschedule(text,text,timestamptz) to anon, authenticated;
