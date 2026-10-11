-- ===========================================================================
--  20261011162000_logo_de_la_casa.sql
--
--  QUE EL DUENO SUBA SU LOGO, NO QUE PEGUE UNA URL
--
--  `casa_logo_url` nacio el 11/10 (ADR-047) como un campo de texto donde hay
--  que escribir una URL. Un dueno de remates tiene un PNG en el telefono, no
--  una URL. Lo dijo Jota en cuanto lo vio: "debiste haberle puesto en la
--  pasada anterior para subir imagen directo". Tenia razon.
--
--  Y desde el ADR-049, con la marca de la casa mandando en la pantalla del
--  jugador, esto dejo de ser un detalle: sin subida, la mayoria de las casas
--  se quedan con el nombre en texto.
--
--  POR QUE UN BUCKET Y NO LA BASE. Una imagen en una columna obliga a leerla
--  por la base en cada peticion y a pagarla en cada copia de seguridad. El
--  almacenamiento de objetos esta para esto.
--
--  EL BUCKET ES PUBLICO, Y ESO ES LO CORRECTO AQUI. Lo que guarda es un logo
--  que se ensena en la portada a cualquiera que entre, sin sesion. Un bucket
--  privado obligaria a firmar una URL por visita para mostrar algo que ya es
--  publico por definicion.
--
--  ESCRIBIR, SOLO EL SUPER ADMIN. Es la misma regla que los datos de cobro
--  (ADR-047): lo que ve el jugador en la cabecera de la casa no lo cambia
--  cualquiera con sesion.
--
--  SIN SVG, A PROPOSITO. Un SVG es un documento con scripts dentro. Aceptar
--  SVG de subida en un bucket publico es aceptar codigo ajeno. El navegador
--  recorta y reconvierte a PNG antes de subir, asi que no hace falta.
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  1. El bucket.
--
--  `on conflict do update` y no `do nothing`: si una instalacion ya lo tenia
--  creado a mano desde el panel de Supabase -- sin limite de tamano y
--  aceptando cualquier tipo -- esta migracion le pone los limites.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'marca',
  'marca',
  true,
  2097152,                                      -- 2 MB
  array['image/png', 'image/jpeg', 'image/webp']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;


-- ---------------------------------------------------------------------------
--  2. Quien lee y quien escribe.
--
--  Las politicas van sobre `storage.objects` y se acotan por `bucket_id`: esta
--  tabla la comparten TODOS los buckets de la instalacion, asi que una
--  politica sin ese filtro abriria tambien los que vengan despues.
-- ---------------------------------------------------------------------------
drop policy if exists marca_lectura_publica on storage.objects;
create policy marca_lectura_publica on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'marca');

drop policy if exists marca_sube_super on storage.objects;
create policy marca_sube_super on storage.objects
  for insert to authenticated
  with check (bucket_id = 'marca' and public.is_super_admin());

drop policy if exists marca_actualiza_super on storage.objects;
create policy marca_actualiza_super on storage.objects
  for update to authenticated
  using (bucket_id = 'marca' and public.is_super_admin())
  with check (bucket_id = 'marca' and public.is_super_admin());

drop policy if exists marca_borra_super on storage.objects;
create policy marca_borra_super on storage.objects
  for delete to authenticated
  using (bucket_id = 'marca' and public.is_super_admin());
