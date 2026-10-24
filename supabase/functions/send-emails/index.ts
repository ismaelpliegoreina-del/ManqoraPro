import { createClient } from 'npm:@supabase/supabase-js@2';
import { build } from './template.ts';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const RESEND_KEY = Deno.env.get('RESEND_API_KEY') || '';
const FROM_EMAIL = Deno.env.get('FROM_EMAIL') || 'onboarding@resend.dev';
const TEST_TO = Deno.env.get('TEST_TO') || '';
const SITE_URL = Deno.env.get('SITE_URL') || 'https://manqorapro.com/reservas.html';
const TEST_MODE = FROM_EMAIL.toLowerCase().endsWith('@resend.dev');

type Row = { id: string; tenant_id: string; to_email: string; template: string; payload: Record<string, any>; attempts: number };

async function sendOne(row: Row, cache: Map<string, any>) {
  let t = cache.get(row.tenant_id);
  if (!t) {
    const { data: ten } = await sb.from('tenants').select('slug,name').eq('id', row.tenant_id).single();
    const { data: ts } = await sb.from('tenant_settings').select('business').eq('tenant_id', row.tenant_id).maybeSingle();
    const bz = (ts?.business as any) || {};
    t = { slug: ten?.slug || '', name: ten?.name || '', replyTo: bz.email || '', biz: { name: bz.name || ten?.name, address: bz.address, phone: bz.phone, logo: bz.logo, hero: bz.hero } };
    cache.set(row.tenant_id, t);
  }
  const built = build(row, t.slug, t.biz, SITE_URL);
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
