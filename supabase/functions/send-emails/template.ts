// Plantillas de correo (HTML compatible con Gmail, Outlook y móviles: tablas y estilos en línea).
const TZ = 'Europe/Madrid';
const ACCENT = '#2d6a3e';

export const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const fmtDay = (iso: string) => cap(new Intl.DateTimeFormat('es-ES', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long' }).format(new Date(iso)));
const fmtHour = (iso: string) => new Intl.DateTimeFormat('es-ES', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(iso));
const gcal = (iso: string) => iso.replace(/[-:]/g, '').replace(/\.\d+/, '').replace(/\+00:00$/, 'Z');

// Solo rutas de imagen seguras: relativas dentro de /assets/ o https
export function imgUrl(p: unknown, siteBase: string): string {
  const v = String(p ?? '');
  if (/^assets\/[a-z0-9_-]+\/[A-Za-z0-9._-]+$/i.test(v)) return new URL(v, siteBase).toString();
  if (/^https:\/\/[^\s"'<>()]+$/i.test(v)) return v;
  return '';
}

type Biz = { name?: string; address?: string; phone?: string; logo?: string; hero?: string };
type Row = { template: string; payload: Record<string, any> };

const LABEL = (t: string) => `<td style="padding:9px 0;color:#6b7280;font-size:14px;border-bottom:1px solid #eef0f3">${t}</td>`;
const VAL = (t: string) => `<td style="padding:9px 0;text-align:right;font-size:15px;border-bottom:1px solid #eef0f3"><b>${t}</b></td>`;

export function build(row: Row, slug: string, biz: Biz, siteUrl: string) {
  const p = row.payload || {};
  const siteBase = siteUrl.replace(/[^/]*$/, ''); // carpeta donde está reservas.html
  const bizName = esc(p.business || biz.name || 'Tu peluquería');
  const first = esc(String(p.name || '').split(' ')[0] || '');
  const hello = first ? `Hola ${first},` : 'Hola,';
  const logo = imgUrl(biz.logo, siteBase), hero = imgUrl(biz.hero, siteBase);
  const link = `${siteUrl}?n=${encodeURIComponent(slug)}&cita=${encodeURIComponent(p.code || '')}`;
  const day = p.starts_at ? fmtDay(p.starts_at) : '', hour = p.starts_at ? fmtHour(p.starts_at) : '';
  const maps = biz.address ? `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(biz.address)}` : '';
  const endIso = p.ends_at || (p.starts_at ? new Date(Date.parse(p.starts_at) + 30 * 60000).toISOString() : '');
  const cal = p.starts_at
    ? `https://calendar.google.com/calendar/render?action=TEMPLATE&text=${encodeURIComponent(`${p.service || 'Cita'} · ${p.business || biz.name || ''}`)}&dates=${gcal(new Date(p.starts_at).toISOString())}/${gcal(new Date(endIso).toISOString())}&location=${encodeURIComponent(biz.address || '')}`
    : '';

  const btn = (href: string, text: string, filled = true) =>
    `<a href="${esc(href)}" style="display:inline-block;${filled ? `background:${ACCENT};color:#ffffff;` : `background:#ffffff;color:${ACCENT};border:1.5px solid ${ACCENT};`}text-decoration:none;padding:13px 22px;border-radius:10px;font-weight:700;font-size:15px;margin:4px 6px 4px 0">${text}</a>`;

  const details = `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:18px 0 6px">`
    + `<tr>${LABEL('Servicio')}${VAL(esc(p.service))}</tr>`
    + `<tr>${LABEL('Día')}${VAL(esc(day))}</tr>`
    + `<tr>${LABEL('Hora')}${VAL(esc(hour))}</tr>`
    + (p.employee ? `<tr>${LABEL('Con')}${VAL(esc(p.employee))}</tr>` : '')
    + (biz.address ? `<tr>${LABEL('Dónde')}${VAL(esc(biz.address))}</tr>` : '')
    + `<tr>${LABEL('Código de tu cita')}${VAL(`<span style="font-family:Menlo,Consolas,monospace;letter-spacing:1px">${esc(p.code)}</span>`)}</tr></table>`;

  const wrap = (pre: string, title: string, intro: string, opts: { box?: boolean; manage?: boolean; extras?: boolean } = {}) => {
    const { box = true, manage = true, extras = true } = opts;
    return `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>${title}</title></head>`
    + `<body style="margin:0;padding:0;background:#f3f4f6">`
    + `<div style="display:none;max-height:0;overflow:hidden;opacity:0">${esc(pre)}</div>`
    + `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6"><tr><td align="center" style="padding:20px 10px">`
    + `<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;background:#ffffff;border-radius:16px;overflow:hidden;font-family:system-ui,-apple-system,'Segoe UI',Roboto,Arial,sans-serif;color:#17202a">`
    + (hero ? `<tr><td style="padding:0"><img src="${esc(hero)}" width="600" alt="${bizName}" style="display:block;width:100%;height:auto;border:0"></td></tr>` : '')
    + (logo ? `<tr><td align="center" style="padding:${hero ? '18px' : '26px'} 24px 0"><img src="${esc(logo)}" height="86" alt="${bizName}" style="display:block;height:86px;width:auto;border:0"></td></tr>` : `<tr><td align="center" style="padding:26px 24px 0;font-size:20px;font-weight:800">${bizName}</td></tr>`)
    + `<tr><td style="padding:22px 28px 6px"><h1 style="margin:0 0 8px;font-size:23px;line-height:1.25">${title}</h1><p style="margin:0;font-size:16px;line-height:1.5;color:#374151">${hello} ${intro}</p>${box ? details : ''}`
    + (manage ? `<p style="margin:18px 0 4px">${btn(link, 'Ver, cambiar o cancelar mi cita')}</p>` : '')
    + (extras && (cal || maps) ? `<p style="margin:6px 0 0">${cal ? btn(cal, '📅 Añadir al calendario', false) : ''}${maps ? btn(maps, '📍 Cómo llegar', false) : ''}</p>` : '')
    + `</td></tr>`
    + `<tr><td style="padding:22px 28px 26px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid #eef0f3"><tr><td style="padding-top:16px;font-size:13px;line-height:1.5;color:#6b7280">`
    + `<b style="color:#374151">${bizName}</b>${biz.address ? `<br>${esc(biz.address)}` : ''}${biz.phone ? `<br>${esc(biz.phone)}` : ''}`
    + `</td></tr></table></td></tr></table>`
    + `<p style="margin:14px 0 0;font:12px system-ui,Arial,sans-serif;color:#9ca3af">Reservas con Tonsora Pro</p>`
    + `</td></tr></table></body></html>`;
  };

  const t = row.template, b = p.business || biz.name || '';
  switch (t) {
    case 'confirm': return { subject: `Cita confirmada · ${b}`, html: wrap(`Tu cita: ${day} a las ${hour}`, '¡Tu cita está confirmada!', 'te esperamos. Estos son los datos:') };
    case 'pending': return { subject: `Hemos recibido tu reserva · ${b}`, html: wrap('Tu reserva está pendiente de confirmar', 'Reserva recibida', 'el negocio debe confirmar tu cita. Te avisaremos en cuanto lo haga.') };
    case 'cancel': return { subject: `Cita cancelada · ${b}`, html: wrap('Tu cita se ha cancelado', 'Tu cita ha sido cancelada', 'esta es la cita que se ha cancelado:', { manage: false, extras: false }) };
    case 'change': return { subject: `Tu cita ha cambiado · ${b}`, html: wrap(`Nueva hora: ${day} a las ${hour}`, 'Tu cita se ha modificado', 'estos son los nuevos datos:') };
    case 'reminder': return { subject: `Recordatorio de tu cita · ${b}`, html: wrap(`Te esperamos ${day} a las ${hour}`, 'Te recordamos tu cita', 'te esperamos pronto:') };
    default: return null;
  }
}
