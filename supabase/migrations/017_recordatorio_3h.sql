-- 017 · Recordatorio 3 h antes para citas reservadas con poco margen
-- Reglas (cada cita recibe como máximo UN recordatorio):
--   · Reservada con más de 24 h de margen  -> recordatorio unas 24 h antes (como en la 016).
--   · Reservada con menos de 24 h pero con 3,5 h o más de margen -> recordatorio unas 3 h antes.
--   · Reservada con menos de 3,5 h de margen -> sin recordatorio (acaba de recibir la confirmación).
-- reminded_at ya marca que se envió, así que el de 3 h solo sale si no se envió el de 24 h.
-- El aviso periódico corre cada 5 min.
create or replace function public.enqueue_reminders() returns integer
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  with due as (
    update public.appointments a set reminded_at = now()
    from public.clients c, public.services s, public.employees e, public.tenants t
    where c.id = a.client_id and s.id = a.service_id and e.id = a.employee_id and t.id = a.tenant_id
      and a.status = 'confirmed' and a.reminded_at is null
      and c.email is not null and c.anonymized_at is null
      and t.license_status = 'active'
      and (
        (a.starts_at > now() + interval '23 hours' and a.starts_at <= now() + interval '24 hours'
          and a.created_at <= a.starts_at - interval '24 hours')
        or
        (a.starts_at > now() + interval '2 hours 30 minutes' and a.starts_at <= now() + interval '3 hours'
          and a.created_at <= a.starts_at - interval '3 hours 30 minutes')
      )
    returning a.tenant_id, c.email, a.code, a.starts_at, s.name as sname, e.name as ename, t.name as bname, c.name as cname
  ), ins as (
    insert into public.outbox_emails(tenant_id, to_email, template, payload)
    select tenant_id, email, 'reminder',
           jsonb_build_object('code', code, 'starts_at', starts_at, 'service', sname, 'employee', ename, 'business', bname, 'name', cname)
    from due returning 1)
  select count(*) into n from ins;
  return n;
end $$;
