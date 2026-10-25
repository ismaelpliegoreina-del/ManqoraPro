-- 013 · Manqora Pro no emite tickets ni facturas: se deja de numerar los cobros.
-- No se borra nada: la tabla receipt_counters, la función next_receipt_no y la columna
-- sales.receipt_no quedan sin usar (los números antiguos se conservan tal cual).
create or replace function public.sales_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.receipt_no := null;                      -- ya no se asigna número correlativo
  new.created_by := coalesce(new.created_by, (select auth.uid()));
  return new;
end $$;
revoke all on function public.sales_before_insert() from public, anon, authenticated;
