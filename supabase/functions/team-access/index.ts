// Gestión de accesos del equipo: solo el PROPIETARIO del negocio puede usarla.
// Acciones: list · create (crea la cuenta con contraseña inicial) · reset (nueva contraseña temporal) · revoke (quita el acceso)
import { createClient } from 'npm:@supabase/supabase-js@2';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const admin = createClient(URL_, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const out = (o: unknown) => new Response(JSON.stringify(o), { headers: { ...CORS, 'Content-Type': 'application/json' } });
const fail = (error: string) => out({ ok: false, error });
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const authz = req.headers.get('Authorization') || '';
    const uc = createClient(URL_, ANON, { global: { headers: { Authorization: authz } } });
    const { data: u } = await uc.auth.getUser();
    if (!u?.user) return fail('no_session');
    const body = await req.json().catch(() => ({}));

    // El que llama debe ser propietario activo de un negocio
    const { data: owns } = await admin.from('members').select('tenant_id').eq('user_id', u.user.id).eq('role', 'owner').eq('active', true);
    const tenants = (owns || []).map((m: any) => m.tenant_id);
    const tenant = body.tenant_id ? String(body.tenant_id) : tenants.length === 1 ? tenants[0] : '';
    if (!tenant || !tenants.includes(tenant)) return fail('not_owner');

    const empUuid = async (appId: unknown) => {
      const n = Number(appId);
      if (!Number.isFinite(n)) return null;
      const { data } = await admin.from('employees').select('id').eq('tenant_id', tenant).eq('app_id', n).maybeSingle();
      return data?.id as string | null;
    };

    const action = String(body.action || '');

    if (action === 'list') {
      const { data: ms } = await admin.from('members').select('user_id,role,active,employee_id').eq('tenant_id', tenant);
      const { data: emps } = await admin.from('employees').select('id,app_id').eq('tenant_id', tenant);
      const appOf = new Map((emps || []).map((e: any) => [e.id, e.app_id]));
      const rows = [];
      for (const m of ms || []) {
        const { data: au } = await admin.auth.admin.getUserById(m.user_id);
        rows.push({
          user_id: m.user_id, role: m.role, active: m.active,
          email: au?.user?.email || '', employee_app_id: m.employee_id ? appOf.get(m.employee_id) ?? null : null,
          must_change: !!au?.user?.user_metadata?.must_change_password,
        });
      }
      return out({ ok: true, members: rows });
    }

    if (action === 'create') {
      const email = String(body.email || '').trim().toLowerCase();
      const password = String(body.password || '');
      const role = body.role === 'manager' ? 'manager' : 'staff';
      if (!EMAIL.test(email) || email.length > 120) return fail('invalid_email');
      if (password.length < 8 || password.length > 72) return fail('weak_password');
      const eid = await empUuid(body.employee_app_id);
      if (!eid) return fail('invalid_employee');
      const { data: ex } = await admin.from('members').select('user_id').eq('tenant_id', tenant).eq('employee_id', eid).maybeSingle();
      if (ex) return fail('already_has_access');
      const { data: cu, error: ce } = await admin.auth.admin.createUser({
        email, password, email_confirm: true, user_metadata: { must_change_password: true },
      });
      if (ce || !cu?.user) return fail(/already|registered|exists/i.test(ce?.message || '') ? 'email_in_use' : 'create_failed');
      const { error: me } = await admin.from('members').insert({ tenant_id: tenant, user_id: cu.user.id, role, employee_id: eid, active: true });
      if (me) { await admin.auth.admin.deleteUser(cu.user.id); return fail('create_failed'); }
      return out({ ok: true });
    }

    if (action === 'reset' || action === 'revoke') {
      const eid = await empUuid(body.employee_app_id);
      if (!eid) return fail('invalid_employee');
      const { data: m } = await admin.from('members').select('user_id,role').eq('tenant_id', tenant).eq('employee_id', eid).maybeSingle();
      if (!m) return fail('no_access');
      if (m.role === 'owner') return fail('is_owner');
      if (action === 'revoke') {
        await admin.from('members').delete().eq('tenant_id', tenant).eq('user_id', m.user_id);
        return out({ ok: true });
      }
      const password = String(body.password || '');
      if (password.length < 8 || password.length > 72) return fail('weak_password');
      const { error } = await admin.auth.admin.updateUserById(m.user_id, { password, user_metadata: { must_change_password: true } });
      return error ? fail('reset_failed') : out({ ok: true });
    }

    return fail('unknown_action');
  } catch (_e) {
    return fail('server_error');
  }
});
