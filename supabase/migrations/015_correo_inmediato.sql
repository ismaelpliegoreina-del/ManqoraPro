-- 015 · Correo inmediato: al encolar un correo, se avisa enseguida a la función send-emails
-- (antes esperaba al aviso de cada minuto). El aviso de cada minuto se mantiene como red de seguridad.
-- pg_net envía la llamada después de confirmar la transacción, así que el correo ya está guardado cuando la función lo busca.
-- Los recordatorios no lo necesitan: los envía el aviso periódico.
create function public.kick_send_emails() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'pending' and new.template <> 'reminder' then
    perform net.http_post(
      url := 'https://jiokzzzdepinumbrjalm.supabase.co/functions/v1/send-emails',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imppb2t6enpkZXBpbnVtYnJqYWxtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI3NzI0OTYsImV4cCI6MjEwODM0ODQ5Nn0.ztvIlZQkTO1xtZwRM_hSC-E6UwXIuHJegrRvHRaJdww'),
      body := '{}'::jsonb);
  end if;
  return null;
exception when others then
  return null; -- nunca impedir una reserva por un fallo del aviso
end $$;
revoke all on function public.kick_send_emails() from public, anon, authenticated;
create trigger outbox_kick after insert on public.outbox_emails
  for each row execute function public.kick_send_emails();
