-- 001 · Tablas base de Manqora Pro (multi-negocio)
create extension if not exists btree_gist with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  name text not null check (length(trim(name)) > 0),
  timezone text not null default 'Europe/Madrid',
  license_status text not null default 'active' check (license_status in ('active','readonly','suspended')),
  license_until date,
  cancel_min_hours int not null default 5 check (cancel_min_hours between 0 and 168),
  created_at timestamptz not null default now()
);

create table public.tenant_settings (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  business jsonb not null default '{}'::jsonb,
  settings jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table public.members (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','manager','staff')),
  employee_id uuid,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (tenant_id, user_id)
);

create table public.employees (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  color text,
  commission_pct numeric(5,2) not null default 0 check (commission_pct between 0 and 100),
  schedule jsonb not null default '{}'::jsonb,  -- {"1":{"on":true,"from":"09:00","to":"20:00","brk":{"from":"14:00","to":"16:00"}}, ...} (0 = domingo)
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, tenant_id)
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  duration_min int not null check (duration_min between 5 and 480),
  price numeric(10,2) not null check (price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, tenant_id)
);
create unique index services_name_uq on public.services (tenant_id, lower(name));

create table public.upsells (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  price numeric(10,2) not null check (price >= 0),
  extra_min int not null default 0 check (extra_min between 0 and 240),
  active boolean not null default true,
  unique (id, tenant_id)
);

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  phone text,
  phone_norm text,
  email text,
  notes text,
  noshows int not null default 0,
  loyalty jsonb not null default '{}'::jsonb,
  consent_marketing boolean not null default false,
  consent_at timestamptz,
  anonymized_at timestamptz,
  created_at timestamptz not null default now(),
  unique (id, tenant_id)
);
create unique index clients_phone_uq on public.clients (tenant_id, phone_norm) where anonymized_at is null;
create index clients_tenant_idx on public.clients (tenant_id);

create table public.appointments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  client_id uuid not null,
  service_id uuid not null,
  employee_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'confirmed' check (status in ('pending','confirmed','completed','cancelled','noshow')),
  code text not null default upper(encode(extensions.gen_random_bytes(6),'hex')),
  paid boolean not null default false,
  source text not null default 'agenda' check (source in ('agenda','online')),
  cancelled_by text check (cancelled_by in ('staff','client')),
  cancelled_at timestamptz,
  reminded_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  unique (id, tenant_id),
  unique (tenant_id, code),
  foreign key (client_id, tenant_id) references public.clients(id, tenant_id),
  foreign key (service_id, tenant_id) references public.services(id, tenant_id),
  foreign key (employee_id, tenant_id) references public.employees(id, tenant_id),
  -- un profesional no puede tener dos citas activas solapadas
  constraint no_solape_por_profesional exclude using gist (
    employee_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status in ('pending','confirmed'))
);
create index appointments_tenant_start_idx on public.appointments (tenant_id, starts_at);
create index appointments_client_idx on public.appointments (client_id);

create table public.appointment_addons (
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  upsell_id uuid not null references public.upsells(id),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  price numeric(10,2) not null check (price >= 0),
  primary key (appointment_id, upsell_id)
);

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  appointment_id uuid references public.appointments(id),
  client_id uuid,
  employee_id uuid,
  sold_at timestamptz not null default now(),
  subtotal numeric(10,2) not null,
  vat numeric(10,2) not null,
  total numeric(10,2) not null,
  tip numeric(10,2) not null default 0,
  payment text not null check (payment in ('cash','card','bizum')),
  receipt_no text,
  annul_of uuid references public.sales(id),
  annul_reason text,
  comm_pct numeric(5,2) not null default 0,
  created_by uuid,
  unique (id, tenant_id),
  unique (tenant_id, receipt_no),
  foreign key (client_id, tenant_id) references public.clients(id, tenant_id),
  foreign key (employee_id, tenant_id) references public.employees(id, tenant_id)
);
create unique index sales_annul_uq on public.sales (annul_of) where annul_of is not null;
create index sales_tenant_date_idx on public.sales (tenant_id, sold_at);

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete cascade,
  service_id uuid,
  product_id uuid,
  upsell_id uuid,
  name text not null,
  qty int not null default 1,
  price numeric(10,2) not null
);
create index sale_items_sale_idx on public.sale_items (sale_id);

create table public.receipt_counters (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  year int not null,
  last int not null default 0,
  primary key (tenant_id, year)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  supplier text,
  stock int not null default 0,
  min_stock int not null default 0,
  cost numeric(10,2) not null default 0,
  sale numeric(10,2) not null default 0,
  active boolean not null default true,
  unique (id, tenant_id)
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  product_id uuid not null references public.products(id),
  qty int not null,
  reason text,
  created_by uuid,
  created_at timestamptz not null default now()
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  spent_on date not null,
  concept text not null,
  category text,
  supplier text,
  base numeric(10,2) not null,
  vat numeric(10,2) not null default 0,
  total numeric(10,2) not null,
  created_at timestamptz not null default now()
);

create table public.cash_closures (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  day date not null,
  expected numeric(10,2) not null,
  counted numeric(10,2) not null,
  deviation numeric(10,2) not null,
  status text not null,
  notes text,
  created_at timestamptz not null default now(),
  unique (tenant_id, day)
);

create table public.waitlist (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  client_name text not null,
  phone text,
  email text,
  service_id uuid,
  wanted_day date,
  created_at timestamptz not null default now()
);

create table public.closed_days (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  day date not null,
  reason text,
  primary key (tenant_id, day)
);

create table public.time_blocks (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  employee_id uuid,                       -- null = todo el negocio
  from_day date not null,
  to_day date not null,
  kind text not null default 'off' check (kind in ('off','partial')),
  start_time time,
  end_time time,
  reason text,
  check (from_day <= to_day)
);

create table public.outbox_emails (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  to_email text not null,
  template text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','sent','error')),
  attempts int not null default 0,
  error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index outbox_pending_idx on public.outbox_emails (status, created_at);

create table public.audit_log (
  id bigint generated always as identity primary key,
  tenant_id uuid references public.tenants(id) on delete cascade,
  user_id uuid,
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.booking_attempts (
  id bigint generated always as identity primary key,
  key text not null,
  created_at timestamptz not null default now()
);
create index booking_attempts_idx on public.booking_attempts (key, created_at);

alter table public.members
  add constraint members_employee_fk foreign key (employee_id) references public.employees(id) on delete set null;
