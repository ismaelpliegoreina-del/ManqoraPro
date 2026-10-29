-- 018 · Los recordatorios se envían en cuanto se encolan (antes esperaban hasta 1 min al reloj de envíos)
-- Se mantiene el reloj de cada minuto como red de seguridad.
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
  if n > 0 then
    begin
      perform net.http_post(
        url := 'https://jiokzzzdepinumbrjalm.supabase.co/functions/v1/send-emails',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imppb2t6enpkZXBpbnVtYnJqYWxtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI3NzI0OTYsImV4cCI6MjEwODM0ODQ5Nn0.ztvIlZQkTO1xtZwRM_hSC-E6UwXIuHJegrRvHRaJdww'),
        body := '{}'::jsonb);
    exception when others then null; -- si falla el aviso, lo envía el reloj de cada minuto
    end;
  end if;
  return n;
end $$;
