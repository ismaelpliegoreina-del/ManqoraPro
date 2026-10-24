# Manqora Pro · Booking & Management

Aplicación de reservas y gestión para barberías y peluquerías.

- `index.html` · web de venta de Manqora Pro (página pública)
- `admin.html` · panel de administración (en la web: `/admin`)
- `reservas.html` · página de reservas de cada negocio (en la web: `/r/<negocio>`)
- `_redirects` y `_headers` · reglas de Cloudflare Pages
- `config.js` · configuración del negocio (tenant, licencia, datos del negocio)

Estado: prototipo en un solo HTML con datos locales. Siguiente fase: Supabase (multi-negocio, login, reservas sin doble reserva).

> No subir nunca claves secretas (service_role, Resend) a este repositorio.

## Base de datos (Supabase)

Migraciones en `supabase/migrations/` (001–005): tablas, seguridad (RLS), reglas automáticas, funciones de reserva pública e índices.
Diseño y decisiones en `docs/diseno_base_de_datos.md`.
