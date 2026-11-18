-- 025 · business.cif visible en la reserva pública (lo necesita la política de privacidad: responsable del tratamiento).
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.public_business(text)'::regprocedure);
  if d like '%''cif''%' then return; end if;
  n := replace(d, '''photosTitle'', ts.business -> ''photosTitle'',', '''photosTitle'', ts.business -> ''photosTitle'', ''cif'', ts.business -> ''cif'',');
  if n = d then raise exception 'no se encontro el punto de insercion'; end if;
  execute n;
end $$;
