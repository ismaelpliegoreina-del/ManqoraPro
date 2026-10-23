-- 010 · La web pública también devuelve logo, emblema, foto de cabecera y fotos del local (rutas guardadas en tenant_settings.business)
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
      'hero', ts.business -> 'hero', 'photos', coalesce(ts.business -> 'photos', '[]'::jsonb)),
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
