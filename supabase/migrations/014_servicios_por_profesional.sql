-- 014 · Servicios y extras por profesional
-- El panel guarda en employees.data las listas de lo que el profesional NO ofrece:
--   data.hideServices = [app_id de servicios], data.hideUpsells = [app_id de extras]
-- Sin listas = ofrece todo (los negocios existentes siguen igual y los servicios nuevos aparecen para todos).

create function public.emp_offers(p_emp uuid, p_kind text, p_item_app_id bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select not coalesce(
    (case when jsonb_typeof(e.data -> (case p_kind when 'service' then 'hideServices' else 'hideUpsells' end)) = 'array'
          then (e.data -> (case p_kind when 'service' then 'hideServices' else 'hideUpsells' end)) @> to_jsonb(p_item_app_id)
          else false end), false)
  from public.employees e where e.id = p_emp
$$;
revoke all on function public.emp_offers(uuid, text, bigint) from public, anon, authenticated;

-- La web pública recibe, por profesional, qué servicios y extras ofrece (listas de ids permitidos)
create or replace function public.public_business(p_slug text) returns jsonb
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
      'phone', ts.business -> 'phone', 'email', ts.business -> 'email',
      'logo', ts.business -> 'logo', 'emblem', ts.business -> 'emblem',
      'hero', ts.business -> 'hero', 'icon', ts.business -> 'icon', 'photos', coalesce(ts.business -> 'photos', '[]'::jsonb)),
    'opening', coalesce(nullif(ts.settings ->> 'opening', ''), '09:00'),
    'closing', coalesce(nullif(ts.settings ->> 'closing', ''), '20:00'),
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'duration_min', s.duration_min, 'price', s.price) order by s.name)
                          from public.services s where s.tenant_id = t.id and s.active), '[]'::jsonb),
    'employees', coalesce((select jsonb_agg(jsonb_build_object(
                             'id', e.id, 'name', e.name, 'color', e.color,
                             'service_ids', coalesce((select jsonb_agg(s.id) from public.services s
                                                       where s.tenant_id = t.id and s.active and public.emp_offers(e.id, 'service', s.app_id)), '[]'::jsonb),
                             'upsell_ids', coalesce((select jsonb_agg(u.id) from public.upsells u
                                                      where u.tenant_id = t.id and u.active and public.emp_offers(e.id, 'upsell', u.app_id)), '[]'::jsonb)
                           ) order by e.name)
                           from public.employees e where e.tenant_id = t.id and e.active), '[]'::jsonb),
    'upsells', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'price', u.price, 'extra_min', u.extra_min) order by u.name)
                         from public.upsells u where u.tenant_id = t.id and u.active), '[]'::jsonb)
  );
end $$;

-- Horas libres: solo con profesionales que ofrecen ese servicio
create or replace function public.public_slots(p_slug text, p_service uuid, p_day date, p_employee uuid default null, p_upsells uuid[] default '{}')
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
  for r in select e.id from public.employees e
           where e.tenant_id = t.id and e.active and (p_employee is null or e.id = p_employee)
             and public.emp_offers(e.id, 'service', s.app_id)
           order by e.name loop
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

-- Reservar: el profesional debe ofrecer el servicio; los extras que no ofrece se descartan
create or replace function public.public_book(
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
  if not public.emp_offers(e.id, 'service', s.app_id) then return jsonb_build_object('ok', false, 'error', 'invalid_service'); end if;
  p_upsells := coalesce((select array_agg(u.id) from public.upsells u
                         where u.id = any(coalesce(p_upsells, '{}')) and u.tenant_id = t.id and u.active
                           and public.emp_offers(e.id, 'upsell', u.app_id)), '{}');
  v_dur := s.duration_min + coalesce((select sum(u.extra_min) from public.upsells u where u.id = any(p_upsells) and u.tenant_id = t.id and u.active), 0);
  if not public.slot_valid(t.id, e.id, v_dur, p_starts) then
    return jsonb_build_object('ok', false, 'error', 'slot_unavailable');
  end if;
  v_ends := p_starts + make_interval(mins => v_dur);

  insert into public.clients(tenant_id, name, phone, email, consent_marketing, consent_at)
  values (t.id, v_name, p_phone, v_email, coalesce(p_consent_marketing, false), now())
  on conflict (tenant_id, phone_norm) where anonymized_at is null do nothing;
  select * into c from public.clients where tenant_id = t.id and phone_norm = v_phone and anonymized_at is null;
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
  select a.id, u.id, t.id, u.price from public.upsells u where u.id = any(p_upsells) and u.tenant_id = t.id and u.active;

  insert into public.outbox_emails(tenant_id, to_email, template, payload)
  values (t.id, c.email, case when v_status = 'pending' then 'pending' else 'confirm' end,
          jsonb_build_object('code', a.code, 'starts_at', a.starts_at, 'service', s.name, 'employee', e.name, 'business', t.name, 'name', c.name));

  return jsonb_build_object('ok', true, 'code', a.code, 'status', a.status, 'starts_at', a.starts_at, 'ends_at', a.ends_at);
end $$;
