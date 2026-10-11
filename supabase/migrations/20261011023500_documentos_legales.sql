-- ===========================================================================
--  20261011023500_documentos_legales.sql
--
--  QUE SE PUEDA DEMOSTRAR QUIEN ACEPTO QUE, Y CUANDO
--
--  La casa es del licenciatario y el dinero lo mueve el. Pero la marca que ve
--  el jugador es la de la plataforma (decision del 09/10, franquicia), asi que
--  el jugador que pierda dinero va a escribirle a la PLATAFORMA. La respuesta a
--  esa reclamacion es un descargo -- y un descargo solo sirve si se puede
--  demostrar que esa persona lo acepto.
--
--  LO QUE PROTEGE NO ES LA CASILLA, ES EL REGISTRO. En un clickwrap los
--  tribunales miran aviso, acto afirmativo, oportunidad real de leer... y la
--  PRUEBA, cuya carga es de quien la invoca. Lo que hay que conservar es quien
--  acepto, cuando, y QUE VERSION del texto estaba viva en ese momento.
--
--  POR ESO LAS VERSIONES PUBLICADAS SON INMUTABLES. Editar el texto de una
--  version ya aceptada cambiaria, hacia atras, lo que acepto cada persona --
--  y convertiria todos los consentimientos anteriores en papel mojado.
--  `publicar_documento()` SIEMPRE crea una version nueva. No hay forma de
--  editar una publicada, ni para el super admin, ni desde la aplicacion.
--
--  LA VERSION LA PONE LA BASE, NO EL CLIENTE. El navegador dice QUE documentos
--  acepta; el numero de version lo resuelve la base contra lo que esta
--  publicado en ese instante. Un cliente manipulado no puede afirmar haber
--  aceptado una version vieja ni una inventada.
--
--  EL CONSENTIMIENTO Y EL ALTA, EN LA MISMA TRANSACCION. `handle_new_user()`
--  escribe las aceptaciones a la vez que crea el perfil y la cartera. Si fuera
--  una llamada aparte despues del registro habria una ventana con usuarios sin
--  consentimiento -- y con la confirmacion de correo activada ni siquiera hay
--  sesion para hacer esa llamada.
--
--  LO QUE ESTA MIGRACION NO HACE, A PROPOSITO: no impide pujar ni recargar a
--  quien no haya aceptado. `mis_documentos_pendientes()` deja la puerta puesta
--  para que la aplicacion lo exija, pero meter esa comprobacion dentro de
--  `hacer_puja` es una decision sobre el dinero y se toma aparte.
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  1. Los documentos. (codigo, version) es la clave: el historial se queda.
-- ---------------------------------------------------------------------------
create table if not exists public.documentos_legales (
  codigo       text    not null
               check (codigo in ('terminos', 'privacidad', 'aviso_legal')),
  version      integer not null check (version >= 1),
  titulo       text    not null,
  cuerpo       text    not null,
  -- `obligatorio` = hay que aceptarlo para usar la casa. Los terminos lo son;
  -- la politica de privacidad y el aviso legal se informan, no se firman.
  obligatorio  boolean not null default false,
  publicado_en timestamptz,
  creado_en    timestamptz not null default now(),
  primary key (codigo, version)
);

comment on table public.documentos_legales is
  'Textos legales de ESTA casa, con historial. Una version publicada NO se edita nunca: publicar_documento() crea siempre una nueva. Ver 20261011023500.';

-- Vigente = la version publicada mas alta de cada codigo. Sin bandera
-- `vigente` que pueda quedar en dos filas a la vez: el estado se deduce, no se
-- mantiene.
create index if not exists ix_documentos_publicados
  on public.documentos_legales (codigo, version desc)
  where publicado_en is not null;


-- ---------------------------------------------------------------------------
--  2. Las aceptaciones.
-- ---------------------------------------------------------------------------
create table if not exists public.aceptaciones_legales (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  codigo      text    not null,
  version     integer not null,
  aceptado_en timestamptz not null default now(),
  foreign key (codigo, version) references public.documentos_legales(codigo, version),
  -- Aceptar dos veces la misma version es el mismo hecho, no dos.
  unique (user_id, codigo, version)
);

comment on table public.aceptaciones_legales is
  'Quien acepto que, en que version y cuando. Es la prueba: sin ella un descargo no se puede invocar. Ver 20261011023500.';

create index if not exists ix_aceptaciones_usuario
  on public.aceptaciones_legales (user_id);


-- ---------------------------------------------------------------------------
--  3. Lectura publica: lo vigente, con texto.
--
--  La lee `anon` a proposito: los terminos se leen ANTES de abrir la cuenta.
--  Exigir sesion para leer lo que hay que aceptar para tener sesion seria un
--  circulo.
-- ---------------------------------------------------------------------------
create or replace function public.documentos_vigentes()
returns table (codigo text, version integer, titulo text, cuerpo text, obligatorio boolean)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select distinct on (d.codigo)
         d.codigo, d.version, d.titulo, d.cuerpo, d.obligatorio
  from public.documentos_legales d
  where d.publicado_en is not null
  order by d.codigo, d.version desc;
$fn$;

comment on function public.documentos_vigentes() is
  'La version publicada mas alta de cada documento, con su texto. La lee cualquiera: los terminos se leen antes de registrarse.';

revoke all on function public.documentos_vigentes() from public;
grant execute on function public.documentos_vigentes() to anon, authenticated;


-- ---------------------------------------------------------------------------
--  4. Que le falta por aceptar a quien pregunta.
--
--  Sirve para dos cosas: el aviso de re-aceptacion cuando se publica una
--  version nueva, y la puerta que la aplicacion puede cerrar mas adelante.
-- ---------------------------------------------------------------------------
create or replace function public.mis_documentos_pendientes()
returns table (codigo text, version integer, titulo text)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select v.codigo, v.version, v.titulo
  from public.documentos_vigentes() v
  where v.obligatorio
    and auth.uid() is not null
    and not exists (
      select 1 from public.aceptaciones_legales a
      where a.user_id = auth.uid()
        and a.codigo  = v.codigo
        and a.version = v.version
    );
$fn$;

comment on function public.mis_documentos_pendientes() is
  'Documentos obligatorios vigentes que quien llama todavia no ha aceptado. Vacio si no hay sesion.';

revoke all on function public.mis_documentos_pendientes() from public, anon;
grant execute on function public.mis_documentos_pendientes() to authenticated;


-- ---------------------------------------------------------------------------
--  5. Aceptar. Para la RE-aceptacion; el alta la resuelve el trigger.
--
--  El cliente dice QUE acepta. La VERSION la pone la base.
-- ---------------------------------------------------------------------------
create or replace function public.aceptar_documentos(p_codigos text[])
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_uid uuid := auth.uid();
  v_n   integer := 0;
begin
  if v_uid is null then
    raise exception 'Hay que iniciar sesion.';
  end if;

  if p_codigos is null or array_length(p_codigos, 1) is null then
    raise exception 'No llego ningun documento que aceptar.';
  end if;

  with nuevas as (
    insert into public.aceptaciones_legales (user_id, codigo, version)
    select v_uid, v.codigo, v.version
    from public.documentos_vigentes() v
    where v.codigo = any (p_codigos)
    on conflict (user_id, codigo, version) do nothing
    returning 1
  )
  select count(*)::integer into v_n from nuevas;

  return v_n;
end $fn$;

comment on function public.aceptar_documentos(text[]) is
  'Registra que quien llama acepta los documentos nombrados, en su version vigente AHORA. Repetir no duplica. Ver 20261011023500.';

revoke all on function public.aceptar_documentos(text[]) from public, anon;
grant execute on function public.aceptar_documentos(text[]) to authenticated;


-- ---------------------------------------------------------------------------
--  6. Publicar. Solo super admin, y SIEMPRE una version nueva.
-- ---------------------------------------------------------------------------
create or replace function public.publicar_documento(
  p_codigo      text,
  p_titulo      text,
  p_cuerpo      text,
  p_obligatorio boolean default false)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_uid     uuid := auth.uid();
  v_version integer;
begin
  if v_uid is null then
    raise exception 'Hay que iniciar sesion.';
  end if;

  if not public.is_super_admin() then
    raise exception 'Solo el super administrador publica los documentos de la casa.';
  end if;

  if coalesce(btrim(p_titulo), '') = '' then
    raise exception 'El documento necesita un titulo.';
  end if;

  if length(coalesce(btrim(p_cuerpo), '')) < 200 then
    raise exception 'El texto es demasiado corto para ser un documento legal (% caracteres). Si era una prueba, no la publiques.',
      length(coalesce(btrim(p_cuerpo), ''));
  end if;

  -- Dos publicaciones a la vez se darian el mismo numero de version y la
  -- segunda rebotaria contra la clave primaria. El candado las pone en fila.
  perform pg_advisory_xact_lock(12, hashtext(p_codigo));

  select coalesce(max(d.version), 0) + 1 into v_version
  from public.documentos_legales d
  where d.codigo = p_codigo;

  insert into public.documentos_legales (codigo, version, titulo, cuerpo, obligatorio, publicado_en)
  values (p_codigo, v_version, btrim(p_titulo), p_cuerpo, coalesce(p_obligatorio, false), now());

  perform public.log_admin_action(
    v_uid, 'publicar_documento', 'documentos_legales',
    p_codigo || ' v' || v_version,
    jsonb_build_object(
      'codigo', p_codigo,
      'version', v_version,
      'titulo', btrim(p_titulo),
      'obligatorio', coalesce(p_obligatorio, false),
      'caracteres', length(p_cuerpo)),
    true, null);

  return v_version;
end $fn$;

comment on function public.publicar_documento(text,text,text,boolean) is
  'Publica una version NUEVA de un documento legal. Nunca edita una existente: eso cambiaria hacia atras lo que acepto cada persona. Ver 20261011023500.';

revoke all on function public.publicar_documento(text,text,text,boolean) from public, anon;
grant execute on function public.publicar_documento(text,text,text,boolean) to authenticated;


-- ---------------------------------------------------------------------------
--  7. El alta escribe el consentimiento, en la misma transaccion.
--
--  Se regenera `handle_new_user()` entera (ADR-021: el cuerpo original se
--  conserva tal cual y solo se le anade el bloque nuevo).
--
--  NO REVIENTA SI FALTA. Si el navegador no manda `acepta` -- porque todavia
--  no se desplego la pantalla nueva, y con un repositorio sirviendo a N casas
--  eso pasa -- el alta sigue funcionando y la persona queda con sus documentos
--  pendientes. Hacer fallar el registro ahi dejaria una casa entera sin poder
--  registrar a nadie por un desfase de despliegue.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  -- profiles (usa metadata del usuario)
  insert into public.profiles (id, username, telefono, es_admin)
  values (
    new.id,
    nullif(new.raw_user_meta_data->>'username',''),
    nullif(new.raw_user_meta_data->>'telefono',''),
    false
  )
  on conflict (id) do update
    set username = excluded.username,
        telefono = excluded.telefono;

  -- wallets (si no existe)
  insert into public.wallets (user_id, saldo_disponible, saldo_bloqueado)
  values (new.id, 0, 0)
  on conflict (user_id) do nothing;

  -- consentimiento legal: el cliente dice QUE acepta, la base pone la VERSION
  insert into public.aceptaciones_legales (user_id, codigo, version)
  select new.id, v.codigo, v.version
  from public.documentos_vigentes() v
  where v.codigo in (
    select jsonb_array_elements_text(
      case
        when jsonb_typeof(new.raw_user_meta_data->'acepta') = 'array'
          then new.raw_user_meta_data->'acepta'
        else '[]'::jsonb
      end)
  )
  on conflict (user_id, codigo, version) do nothing;

  return new;
end $fn$;


-- ---------------------------------------------------------------------------
--  8. Permisos. Las tablas, cerradas: todo pasa por las funciones.
-- ---------------------------------------------------------------------------
revoke all on table public.documentos_legales    from public, anon, authenticated;
revoke all on table public.aceptaciones_legales  from public, anon, authenticated;
revoke all on sequence public.aceptaciones_legales_id_seq from public, anon, authenticated;

alter table public.documentos_legales   enable row level security;
alter table public.aceptaciones_legales enable row level security;

revoke all on function public.handle_new_user() from public, anon, authenticated;
