-- 006 · Cola de correos, recordatorios automáticos y tareas programadas
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- Reclama correos pendientes (sin que dos ejecuciones envíen el mismo)
create function public.claim_outbox(p_limit int) returns setof public.outbox_emails
language sql security definer set search_path = '' as $$
  update public.outbox_emails o set attempts = o.attempts + 1
  where o.id in (
    select id from public.outbox_emails
    where status = 'pending' and attempts < 5
    order by created_at limit p_limit for update skip locked)
  returning o.*
$$;
revoke all on function public.claim_outbox(int) from public, anon, authenticated;
grant execute on function public.claim_outbox(int) to service_role;

-- Recordatorio ~24 h antes (solo citas confirmadas, con email, negocio con licencia activa)
create function public.enqueue_reminders() returns int
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
      and a.starts_at > now() + interval '2 hours' and a.starts_at <= now() + interval '24 hours'
      and a.created_at < now() - interval '6 hours'
    returning a.tenant_id, c.email, a.code, a.starts_at, s.name as sname, e.name as ename, t.name as bname, c.name as cname
  ), ins as (
    insert into public.outbox_emails(tenant_id, to_email, template, payload)
    select tenant_id, email, 'reminder',
           jsonb_build_object('code', code, 'starts_at', starts_at, 'service', sname, 'employee', ename, 'business', bname, 'name', cname)
    from due returning 1)
  select count(*) into n from ins;
  return n;
end $$;
revoke all on function public.enqueue_reminders() from public, anon, authenticated;

-- Limpieza de intentos antiguos (límite de reservas)
create function public.cleanup_attempts() returns void
language sql security definer set search_path = '' as $$
  delete from public.booking_attempts where created_at < now() - interval '2 days'
$$;
revoke all on function public.cleanup_attempts() from public, anon, authenticated;

-- Tareas programadas
select cron.schedule('enqueue-reminders', '*/15 * * * *', $$select public.enqueue_reminders()$$);
select cron.schedule('cleanup-attempts', '17 3 * * *', $$select public.cleanup_attempts()$$);
-- Cada minuto: si hay correos pendientes, avisa a la función de envío (la clave anon es pública por diseño)
select cron.schedule('send-emails', '* * * * *', $$
  select net.http_post(
    url := 'https://jiokzzzdepinumbrjalm.supabase.co/functions/v1/send-emails',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imppb2t6enpkZXBpbnVtYnJqYWxtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI3NzI0OTYsImV4cCI6MjEwODM0ODQ5Nn0.ztvIlZQkTO1xtZwRM_hSC-E6UwXIuHJegrRvHRaJdww'),
    body := '{}'::jsonb)
  where exists (select 1 from public.outbox_emails where status = 'pending' and attempts < 5)
$$);
