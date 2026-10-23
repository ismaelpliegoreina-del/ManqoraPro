-- 009 · Alta de un negocio nuevo con una sola orden (solo desde el panel de Supabase / SQL editor)
-- Uso:  select public.alta_negocio('nombre-del-negocio', 'Nombre Comercial', 'email-del-dueño@correo.com');
-- Antes hay que crear al dueño en Authentication > Users (Auto Confirm User).
create function public.alta_negocio(p_slug text, p_name text, p_owner_email text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid; u uuid; e uuid; v_slug text := lower(trim(p_slug));
begin
  select id into u from auth.users where lower(email) = lower(trim(p_owner_email));
  if u is null then
    raise exception 'No existe el usuario %. Créalo antes en Authentication > Users.', p_owner_email;
  end if;
  insert into public.tenants(slug, name) values (v_slug, trim(p_name)) returning id into t;
  insert into public.tenant_settings(tenant_id, business, settings)
    values (t, jsonb_build_object('name', trim(p_name)), jsonb_build_object('opening', '09:00', 'closing', '20:00'));
  insert into public.employees(tenant_id, name, commission_pct, schedule)
    values (t, 'Profesional 1', 0,
      (select jsonb_object_agg(d::text, jsonb_build_object('on', d <> 0, 'from', '', 'to', '', 'brk', 'null'::jsonb))
         from generate_series(0, 6) d))
    returning id into e;
  insert into public.services(tenant_id, name, duration_min, price) values (t, 'Corte', 30, 15);
  insert into public.members(tenant_id, user_id, role, employee_id) values (t, u, 'owner', e);
  return jsonb_build_object('tenant_id', t, 'slug', v_slug, 'enlace_reservas', 'reservas.html?n=' || v_slug);
end $$;
revoke all on function public.alta_negocio(text, text, text) from public, anon, authenticated;
