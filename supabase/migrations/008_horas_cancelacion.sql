-- 008 · El propietario/encargado puede cambiar el plazo mínimo para cancelar o cambiar citas
create function public.set_cancel_hours(p_tenant uuid, p_hours int) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(public.role_in(p_tenant), '') not in ('owner', 'manager') or not public.tenant_writable(p_tenant) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.tenants set cancel_min_hours = greatest(0, least(168, p_hours)) where id = p_tenant;
end $$;
revoke all on function public.set_cancel_hours(uuid, int) from public, anon;
grant execute on function public.set_cancel_hours(uuid, int) to authenticated;
