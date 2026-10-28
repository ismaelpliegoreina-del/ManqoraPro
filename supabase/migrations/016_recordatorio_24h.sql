-- 016 · Recordatorio siempre unas 24 h antes de la cita
-- Antes: se enviaba al primer aviso periódico dentro de las 24 h previas (entre 2 y 24 h antes), y se saltaba si la cita se había reservado hacía menos de 6 h.
-- Ahora: solo cuando faltan entre 23 y 24 h (el aviso corre cada 5 min, así sale entre 23 h 55 min y 24 h antes).
-- Las citas reservadas con menos de 24 h de margen no reciben recordatorio (ya tienen la confirmación recién enviada).
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
      and a.starts_at > now() + interval '23 hours' and a.starts_at <= now() + interval '24 hours'
      and a.created_at <= a.starts_at - interval '24 hours'
    returning a.tenant_id, c.email, a.code, a.starts_at, s.name as sname, e.name as ename, t.name as bname, c.name as cname
  ), ins as (
    insert into public.outbox_emails(tenant_id, to_email, template, payload)
    select tenant_id, email, 'reminder',
           jsonb_build_object('code', code, 'starts_at', starts_at, 'service', sname, 'employee', ename, 'business', bname, 'name', cname)
    from due returning 1)
  select count(*) into n from ins;
  return n;
end $$;

select cron.alter_job((select jobid from cron.job where jobname = 'enqueue-reminders'), schedule := '*/5 * * * *');
