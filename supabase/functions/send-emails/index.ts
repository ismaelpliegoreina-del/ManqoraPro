import { createClient } from 'npm:@supabase/supabase-js@2';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const RESEND_KEY = Deno.env.get('RESEND_API_KEY') || '';
const FROM_EMAIL = Deno.env.get('FROM_EMAIL') || 'onboarding@resend.dev';
const TEST_TO = Deno.env.get('TEST_TO') || '';
const SITE_URL = Deno.env.get('SITE_URL') || 'https://ismaelpliegoreina-del.github.io/Project-Tonsora/reservas.html';
const TEST_MODE = FROM_EMAIL.toLowerCase().endsWith('@resend.dev');
const TZ = 'Europe/Madrid';

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const fmtDay = (iso: string) => new Intl.DateTimeFormat('es-ES', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long' }).format(new Date(iso));
const fmtHour = (iso: string) => new Intl.DateTimeFormat('es-ES', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(iso));

type Row = { id: string; tenant_id: string; to_email: string; template: string; payload: Record<string, any>; attempts: number };

function build(row: Row, slug: string) {
  const p = row.payload || {};
  const biz = esc(p.business || 'Tu barbería');
  const name = esc(String(p.name || '').split(' ')[0] || 'hola');
  const when = p.starts_at ? `${esc(fmtDay(p.starts_at))} a las ${esc(fmtHour(p.starts_at))}` : '';
  const url = `${SITE_URL}?n=${encodeURIComponent(slug)}&cita=${encodeURIComponent(p.code || '')}`;
  const box = `<table style="width:100%;border-collapse:collapse;margin:16px 0">`
    + `<tr><td style="padding:6px 0;color:#6b7280">Servicio</td><td style="padding:6px 0;text-align:right"><b>${esc(p.service)}</b></td></tr>`
    + `<tr><td style="padding:6px 0;color:#6b7280">Cuándo</td><td style="padding:6px 0;text-align:right"><b>${when}</b></td></tr>`
    + (p.employee ? `<tr><td style="padding:6px 0;color:#6b7280">Con</td><td style="padding:6px 0;text-align:right"><b>${esc(p.employee)}</b></td></tr>` : '')
    + `<tr><td style="padding:6px 0;color:#6b7280">Código</td><td style="padding:6px 0;text-align:right"><b>${esc(p.code)}</b></td></tr></table>`;
  const btn = `<p><a href="${esc(url)}" style="display:inline-block;background:#2d6a3e;color:#fff;text-decoration:none;padding:12px 20px;border-radius:10px;font-weight:bold">Ver, cambiar o cancelar mi cita</a></p>`;
  const wrap = (title: string, intro: string, withBox = true, withBtn = true) =>
    `<div style="font-family:system-ui,Segoe UI,Arial,sans-serif;max-width:520px;margin:0 auto;color:#17202a">`
    + `<h2 style="margin:0 0 8px">${title}</h2><p>Hola ${name}, ${intro}</p>${withBox ? box : ''}${withBtn ? btn : ''}`
    + `<p style="color:#6b7280;font-size:13px;margin-top:24px">${biz}</p></div>`;
  switch (row.template) {
    case 'confirm': return { subject: `Cita confirmada · ${p.business}`, html: wrap('¡Tu cita está confirmada!', 'te esperamos. Estos son los datos:') };
    case 'pending': return { subject: `Hemos recibido tu reserva · ${p.business}`, html: wrap('Reserva recibida', 'el negocio debe confirmar tu cita. Te avisaremos en cuanto lo haga.') };
    case 'cancel': return { subject: `Cita cancelada · ${p.business}`, html: wrap('Tu cita ha sido cancelada', 'esta es la cita que se ha cancelado:', true, false) };
    case 'change': return { subject: `Tu cita ha cambiado · ${p.business}`, html: wrap('Tu cita se ha modificado', 'estos son los nuevos datos:') };
    case 'reminder': return { subject: `Recordatorio de tu cita · ${p.business}`, html: wrap('Te recordamos tu cita', 'te esperamos pronto:') };
    default: return null;
  }
}

async function sendOne(row: Row, cache: Map<string, any>) {
  let t = cache.get(row.tenant_id);
  if (!t) {
    const { data: ten } = await sb.from('tenants').select('slug,name').eq('id', row.tenant_id).single();
    const { data: ts } = await sb.from('tenant_settings').select('business').eq('tenant_id', row.tenant_id).maybeSingle();
    t = { slug: ten?.slug || '', name: ten?.name || '', replyTo: (ts?.business as any)?.email || '' };
    cache.set(row.tenant_id, t);
  }
  const built = build(row, t.slug);
  if (!built) return { ok: false, error: 'plantilla desconocida: ' + row.template, final: true };
  let to = row.to_email, subject = built.subject, html = built.html;
  if (TEST_MODE) {
    if (!TEST_TO) return { ok: false, error: 'Modo prueba: falta el secreto TEST_TO', final: false };
    subject = `[PRUEBA para ${row.to_email}] ${subject}`;
    to = TEST_TO;
  }
  const body: Record<string, unknown> = { from: `${(t.name || 'Reservas').replace(/[<>"]/g, '')} <${FROM_EMAIL}>`, to: [to], subject, html };
  if (t.replyTo && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(t.replyTo)) body.reply_to = t.replyTo;
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (r.ok) return { ok: true };
  const txt = (await r.text()).slice(0, 300);
  return { ok: false, error: `Resend ${r.status}: ${txt}`, final: r.status >= 400 && r.status < 500 && r.status !== 429 };
}

Deno.serve(async () => {
  if (!RESEND_KEY) return new Response(JSON.stringify({ ok: false, error: 'Falta el secreto RESEND_API_KEY' }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  const { data, error } = await sb.rpc('claim_outbox', { p_limit: 20 });
  if (error) return new Response(JSON.stringify({ ok: false, error: error.message }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  const rows = (data || []) as Row[];
  const cache = new Map<string, any>();
  let sent = 0, failed = 0;
  for (const row of rows) {
    let res;
    try { res = await sendOne(row, cache); } catch (e) { res = { ok: false, error: String((e as Error).message || e), final: false }; }
    if (res.ok) {
      sent++;
      await sb.from('outbox_emails').update({ status: 'sent', sent_at: new Date().toISOString(), error: null }).eq('id', row.id);
    } else {
      failed++;
      const giveUp = res.final || row.attempts >= 5;
      await sb.from('outbox_emails').update({ status: giveUp ? 'error' : 'pending', error: res.error }).eq('id', row.id);
    }
  }
  return new Response(JSON.stringify({ ok: true, claimed: rows.length, sent, failed, testMode: TEST_MODE }), { headers: { 'Content-Type': 'application/json' } });
});
