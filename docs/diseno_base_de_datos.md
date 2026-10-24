# Manqora Pro · Diseño de base de datos (borrador para aprobar)

Proyecto Supabase: `manqora` (antes `tonsora`) (eu-west-1). **Nada de esto está aplicado todavía.**

## 1. Principios

1. **Un solo proyecto, muchos negocios (multi-tenant).** Cada fila lleva `tenant_id`. El aislamiento lo garantizan las reglas RLS, no la aplicación.
2. **El cliente web nunca toca tablas.** La web pública solo llama a funciones (RPC) con permisos mínimos.
3. **Las fechas se guardan como `timestamptz` (UTC) y se muestran siempre en Europe/Madrid.** El cambio de hora de verano e invierno lo resuelve la base de datos.
4. **Las reglas importantes viven en el servidor:** no doble reserva, licencia activa, numeración de recibos sin saltos.
5. **Nunca claves secretas en el HTML.** Solo la clave pública (`anon/publishable`).

## 2. Tablas

| Tabla | Contenido | Notas |
|---|---|---|
| `tenants` | id, slug (único), nombre, `timezone` ('Europe/Madrid'), `license_status` (active/readonly/suspended), `license_until` | La licencia la cambias tú, no el cliente |
| `tenant_settings` | tenant_id, `business` (jsonb: CIF, dirección, teléfono…), `settings` (jsonb: horario, módulos, fidelización, legal…) | jsonb para migrar rápido la configuración actual |
| `members` | tenant_id, user_id (auth), `role` (owner/manager/staff), employee_id opcional, active | Quién entra al panel y con qué rol |
| `employees` | tenant_id, nombre, color, % comisión, horario (jsonb), active | |
| `services` | tenant_id, nombre, duración, precio (IVA incl.), active | |
| `upsells` | tenant_id, nombre, precio, duración extra | Extras |
| `clients` | tenant_id, nombre, teléfono, email, notas, faltas, `consent_marketing`, `anonymized_at` | Único por (tenant, teléfono) |
| `appointments` | tenant_id, client_id, service_id, employee_id, `starts_at`, `ends_at`, status, `code`, paid, source | **Con regla anti doble reserva** (ver 3) |
| `appointment_addons` | appointment_id, upsell_id | |
| `sales` | tenant_id, appointment_id, client_id, employee_id, `sold_at`, subtotal, IVA, total, propina, pago, `receipt_no`, `annul_of`, `annul_reason`, `comm_pct` | Anulaciones = venta negativa enlazada |
| `sale_items` | sale_id, service/producto, cantidad, precio | |
| `receipt_counters` | tenant_id, año, último número | Numeración correlativa atómica |
| `products`, `stock_movements` | stock, mínimo, coste, venta, proveedor | |
| `expenses` | fecha, concepto, categoría, base, IVA, total | |
| `cash_closures` | fecha, esperado, contado, desvío, estado | |
| `waitlist` | cliente, servicio, día deseado | |
| `closures_days` | días cerrados y festivos | |
| `outbox_emails` | destinatario, plantilla, estado, intentos | La Edge Function los envía con Resend |
| `audit_log` | quién, qué, cuándo (cambios sensibles, anulaciones, cambios de licencia) | Solo lectura |

## 3. Anti doble reserva (la regla clave)

```sql
create extension if not exists btree_gist;

alter table appointments add constraint no_solape_por_profesional
  exclude using gist (
    employee_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status in ('pending','confirmed'));
```

Si dos clientes reservan a la vez, la base de datos acepta una y rechaza la otra. La web le muestra «esa hora acaba de ocuparse» y le ofrece las libres. No depende del navegador.

## 4. Seguridad (RLS)

- RLS activado en **todas** las tablas. Sin política, nadie accede.
- Funciones auxiliares `security definer` con `search_path` fijo:
  - `is_member(tenant)` y `role_in(tenant)`.
  - `tenant_writable(tenant)`: devuelve falso si la licencia es `readonly` o `suspended`.
- Patrón de política:
  - **Leer:** el usuario es miembro del negocio (y su rol tiene permiso sobre esa tabla).
  - **Escribir:** además `tenant_writable(tenant_id)`.
- Permisos por rol (igual que ahora): owner todo; manager todo salvo ajustes de licencia y miembros; staff solo agenda, cobros y clientes.
- `tenants.license_status` solo se modifica con tu cuenta de plataforma, nunca desde el panel del negocio.
- El PIN actual pasa a ser comodidad para cambiar de usuario en un dispositivo compartido; **la seguridad real es el login y el rol en base de datos.**

## 5. Web pública: solo funciones (RPC)

| Función | Qué hace |
|---|---|
| `public_business(slug)` | Nombre, servicios, profesionales, horario público. Nada privado |
| `public_slots(slug, servicio, día, profesional?)` | Horas libres calculadas en el servidor |
| `public_book(slug, servicio, profesional, inicio, nombre, teléfono, email, consentimientos)` | Comprueba licencia y datos, crea o reutiliza cliente, inserta la cita, devuelve código |
| `public_get_appointment(slug, code)` | Datos de «Mi cita» |
| `public_cancel(slug, code)` / `public_reschedule(...)` | Respetando el plazo mínimo de cancelación |

Protecciones: validación de campos, límite de intentos por IP/teléfono, códigos largos y aleatorios, y respuestas iguales aunque el código no exista (para no revelar datos).

## 6. Emails y tareas programadas

- **Edge Function `send-emails`** (Resend): lee `outbox_emails`, envía y marca el estado. La clave de Resend vive en secretos de Supabase.
- **Recordatorios:** tarea programada (pg_cron) que encola recordatorios 24 h antes.
- **Licencia:** tarea diaria que pasa a `readonly` o `suspended` según `license_until`.

## 7. Datos y migración

- Los datos de prueba de Gloria **no** se cargan en Manqora. Se crea un negocio de demo aparte.
- Para el piloto, una función de importación acepta el JSON exportado desde el HTML actual.
- Copias de seguridad: automáticas en plan Pro; hasta entonces, exportación manual semanal.

## 8. Decisiones que necesito de ti

1. **Un proyecto para todos los negocios con `tenant_id`** (mi recomendación) o un proyecto de Supabase por cliente.
2. **Quién inicia sesión:** solo propietario y encargado con email, y los empleados con PIN en el dispositivo del local (recomendado para empezar), o una cuenta por empleado.
3. **Reserva online:** ¿exigimos teléfono y email siempre, o solo teléfono?
4. **Dirección pública:** `slug.manqora.app` / ruta `/gloria-bendita` o dominio propio de cada negocio (más adelante).
5. **Plazo de cancelación** por defecto: ¿2 h, 12 h, 24 h?

## 9. Orden de ejecución tras tu aprobación

1. Crear la rama de pruebas de Supabase y aplicar migraciones (tablas, constraint, RLS, funciones).
2. Pruebas de seguridad: usuario de otro negocio, usuario anónimo, licencia suspendida, reservas simultáneas.
3. Revisar los avisos de seguridad (advisors) y corregir.
4. Conectar el HTML (login, datos en la nube, reserva pública) y subir a GitHub.
