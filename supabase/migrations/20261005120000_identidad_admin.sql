-- ===========================================================================
--  20261005120000_identidad_admin.sql
--
--  CADA ADMIN CON SU NOMBRE Y SU CODIGO
--
--  EL PROBLEMA, QUE LO VIO JOTA MIRANDO EL REGISTRO NUEVO:
--  todas las filas de admin_actions decian "Super Admin". No es un detalle
--  estetico: con un solo usuario admin, la bitacora NO PUEDE responder quien
--  hizo que, que es literalmente para lo que existe. Servia para saber que
--  paso, no quien lo hizo.
--
--  Y para alquilar la aplicacion es peor. El licenciatario va a tener dos o
--  tres personas en caja. Si comparten una cuenta, el dia que falte dinero no
--  hay forma de saber de quien fue la mano -- y ahi el software deja de
--  protegerlo, que es justo lo que se le esta vendiendo.
--
--  COMO NACE UN ADMIN (decidido por Jota el 05/10/2026)
--  La persona se registra como cualquier cliente en /register, y un super
--  admin la promueve. NO se crea desde cero con la clave `service_role`.
--
--  La alternativa -- una Edge Function con `service_role` que cree el usuario
--  de una vez -- es mas comoda y se descarto a proposito: obliga a tener esa
--  clave configurada en CADA instalacion de licenciatario, y esa clave es
--  acceso total a la base de ese cliente, por encima de toda la RLS. Un
--  secreto que hay que repartir N veces es un secreto que se filtra una vez.
--  El camino elegido no necesita ningun secreto nuevo: todo pasa por RPC
--  `security definer` con guarda de super admin y queda auditado.
--
--  EL CODIGO LO ESCRIBE UNA PERSONA. Entre 2 y 6 caracteres, letras y
--  numeros. "JOTA" o "C01" le dicen algo a quien lee el registro tres meses
--  despues; "X7K" generado al azar, no.
--
--  UN CODIGO NO SE REUTILIZA NUNCA, ni despues de quitarle el cargo a alguien.
--  Por eso `quitar_admin` baja las banderas pero CONSERVA codigo y nombre: si
--  el codigo se reciclara, las filas viejas del registro pasarian a apuntar a
--  otra persona, y una bitacora que cambia de version del pasado no vale nada.
--
--  Y POR ESO MISMO, LA FOTO EN admin_actions.
--  El registro guarda el codigo y el nombre tal como estaban EN EL MOMENTO.
--  Si manana alguien se casa y cambia de apellido, o se le corrige el codigo,
--  lo que paso en marzo se sigue leyendo como se leia en marzo. Mismo criterio
--  que `motivo_etiqueta` el 01/10, y por la misma razon.
-- ===========================================================================

--  UNA NOTA DE SINTAXIS QUE COSTO UNA EJECUCION
--  `returns table (... es_admin boolean, es_super_admin boolean ...)` convierte
--  esos nombres en VARIABLES de plpgsql. A partir de ahi, un
--  `select es_super_admin from public.profiles` sin cualificar es ambiguo y la
--  funcion aborta con 42702: Postgres no sabe si te refieres a la columna o a
--  la variable. Por eso todas las consultas de este archivo llevan alias de
--  tabla, incluidas las de las funciones que devuelven `text` y no lo
--  necesitarian: una regla que se aplica a veces es una regla que se olvida.
--
--  No lo caza leer el archivo. Lo cazo ejecutarlo contra un Postgres 16.13 con
--  el esquema montado, antes de entregarlo.
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  PASO 1 - La identidad en el perfil
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists admin_codigo text,
  add column if not exists admin_nombre text;

comment on column public.profiles.admin_codigo is
  'Codigo corto del admin (2-6 caracteres). Se conserva aunque se le quite el cargo: no se reutiliza nunca, para que el registro no cambie de version del pasado.';
comment on column public.profiles.admin_nombre is
  'Nombre visible del admin en el registro y en el panel.';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_admin_codigo_formato'
  ) then
    alter table public.profiles
      add constraint profiles_admin_codigo_formato
      check (admin_codigo is null or admin_codigo ~ '^[A-Z0-9]{2,6}$');
  end if;
end $$;

-- Unico ignorando mayusculas y solo entre los que lo tienen. Un indice parcial
-- y no una restriccion `unique` porque la inmensa mayoria de los perfiles son
-- jugadores y tienen el campo nulo.
create unique index if not exists ux_profiles_admin_codigo
  on public.profiles (upper(admin_codigo))
  where admin_codigo is not null;

-- ---------------------------------------------------------------------------
--  PASO 2 - La foto en la bitacora
--
--  log_admin_action pasa a copiar el codigo y el nombre del admin en cada
--  asiento. Las filas viejas se quedan con los dos campos nulos, y la pantalla
--  cae a resolverlo contra `profiles` -- que sigue siendo correcto para ellas,
--  porque hoy solo hay un admin.
-- ---------------------------------------------------------------------------
alter table public.admin_actions
  add column if not exists admin_codigo text,
  add column if not exists admin_nombre text;

comment on column public.admin_actions.admin_codigo is
  'Foto del codigo del admin en el momento de la accion. No es una clave foranea a proposito: el registro tiene que sobrevivir a cualquier cambio posterior.';

create or replace function public.log_admin_action(
  p_admin_id uuid, p_action text, p_target_table text, p_target_id text,
  p_details jsonb, p_success boolean default true, p_error text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_codigo text;
  v_nombre text;
begin
  -- Se lee aqui y no se deja para la pantalla: lo que importa es quien era esa
  -- persona CUANDO lo hizo, no quien es ahora.
  if p_admin_id is not null then
    select admin_codigo, coalesce(admin_nombre, username)
      into v_codigo, v_nombre
    from public.profiles where id = p_admin_id;
  end if;

  insert into public.admin_actions (
    admin_id, action, target_table, target_id, details, success, error,
    admin_codigo, admin_nombre
  ) values (
    p_admin_id, p_action, p_target_table, p_target_id, p_details,
    coalesce(p_success, true), p_error, v_codigo, v_nombre
  );
exception when others then
  raise warning 'log_admin_action no pudo auditar "%": %', p_action, sqlerrm;
end;
$fn$;

-- ---------------------------------------------------------------------------
--  PASO 3 - Buscar a quien promover
--
--  Exige al menos 3 caracteres: sin eso, un super admin podria vaciar la lista
--  de correos de todos los jugadores con una cadena vacia. El correo sale de
--  auth.users, que ninguna pantalla puede leer directamente.
-- ---------------------------------------------------------------------------
create or replace function public.buscar_usuario_para_admin(p_texto text)
returns table (
  user_id uuid, username text, correo text,
  es_admin boolean, es_super_admin boolean, admin_codigo text
)
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_yo uuid := auth.uid();
  v_soy_super boolean;
  v_t text := trim(coalesce(p_texto, ''));
begin
  if v_yo is null then
    raise exception 'No autenticado';
  end if;

  -- El alias `pr.` es obligatorio aqui: ver la nota del encabezado (42702).
  select coalesce(pr.es_super_admin, false) into v_soy_super
  from public.profiles pr where pr.id = v_yo;

  if coalesce(v_soy_super, false) = false then
    raise exception 'No autorizado: solo un super admin puede buscar usuarios';
  end if;

  if length(v_t) < 3 then
    raise exception 'Escribe al menos 3 caracteres para buscar';
  end if;

  return query
  select p.id, p.username, u.email::text,
         coalesce(p.es_admin, false), coalesce(p.es_super_admin, false),
         p.admin_codigo
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.username ilike '%' || v_t || '%'
     or u.email ilike '%' || v_t || '%'
     or coalesce(p.telefono, '') ilike '%' || v_t || '%'
  order by p.username
  limit 20;
end;
$fn$;

-- ---------------------------------------------------------------------------
--  PASO 4 - La lista de admins
-- ---------------------------------------------------------------------------
create or replace function public.listar_admins()
returns table (
  user_id uuid, username text, correo text,
  admin_codigo text, admin_nombre text,
  es_admin boolean, es_super_admin boolean,
  acciones bigint, ultima_accion timestamptz
)
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_yo uuid := auth.uid();
  v_soy_super boolean;
begin
  if v_yo is null then
    raise exception 'No autenticado';
  end if;

  -- El alias `pr.` es obligatorio aqui: ver la nota del encabezado (42702).
  select coalesce(pr.es_super_admin, false) into v_soy_super
  from public.profiles pr where pr.id = v_yo;

  if coalesce(v_soy_super, false) = false then
    raise exception 'No autorizado: solo un super admin puede ver la lista de admins';
  end if;

  return query
  select p.id, p.username, u.email::text,
         p.admin_codigo, p.admin_nombre,
         coalesce(p.es_admin, false), coalesce(p.es_super_admin, false),
         -- Cuanto ha hecho cada uno. Es el dato que convierte una lista de
         -- nombres en algo que se puede supervisar.
         (select count(*) from public.admin_actions a where a.admin_id = p.id),
         (select max(a.created_at) from public.admin_actions a where a.admin_id = p.id)
  from public.profiles p
  join auth.users u on u.id = p.id
  -- Los que ya no son admin pero lo fueron siguen en la lista: su codigo sigue
  -- reservado y sus acciones siguen en el registro.
  where coalesce(p.es_admin, false) or coalesce(p.es_super_admin, false)
     or p.admin_codigo is not null
  order by coalesce(p.es_super_admin, false) desc,
           coalesce(p.es_admin, false) desc,
           p.admin_codigo;
end;
$fn$;

-- ---------------------------------------------------------------------------
--  PASO 5 - Nombrar
-- ---------------------------------------------------------------------------
create or replace function public.nombrar_admin(
  p_user_id uuid, p_codigo text, p_nombre text, p_es_super boolean default false)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_yo uuid := auth.uid();
  v_soy_super boolean;
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_perfil public.profiles%rowtype;
  v_duenio uuid;
begin
  if v_yo is null then
    raise exception 'No autenticado';
  end if;

  -- El alias `pr.` es obligatorio aqui: ver la nota del encabezado (42702).
  select coalesce(pr.es_super_admin, false) into v_soy_super
  from public.profiles pr where pr.id = v_yo;

  if coalesce(v_soy_super, false) = false then
    raise exception 'No autorizado: solo un super admin puede nombrar administradores';
  end if;

  select * into v_perfil from public.profiles where id = p_user_id;
  if not found then
    raise exception 'Ese usuario no existe. Tiene que registrarse primero en la aplicacion.';
  end if;

  if v_codigo !~ '^[A-Z0-9]{2,6}$' then
    raise exception 'El codigo tiene entre 2 y 6 caracteres, solo letras y numeros. Recibido: "%"', v_codigo;
  end if;

  if length(v_nombre) < 3 then
    raise exception 'El nombre visible tiene que tener al menos 3 caracteres';
  end if;

  -- El indice unico ya lo impide, pero un error de clave duplicada no le dice
  -- nada a quien esta rellenando un formulario. Aqui se dice de quien es.
  select id into v_duenio
  from public.profiles
  where upper(admin_codigo) = v_codigo and id <> p_user_id;

  if v_duenio is not null then
    raise exception 'El codigo % ya es de otra persona. Los codigos no se reutilizan, ni siquiera los de quien ya no es admin.', v_codigo;
  end if;

  update public.profiles
     set admin_codigo   = v_codigo,
         admin_nombre   = v_nombre,
         es_admin       = true,
         es_super_admin = coalesce(p_es_super, false) or coalesce(es_super_admin, false)
   where id = p_user_id;

  perform public.log_admin_action(
    v_yo, 'nombrar_admin', 'profiles', p_user_id::text,
    jsonb_build_object(
      'codigo', v_codigo, 'nombre', v_nombre,
      'es_super_admin', coalesce(p_es_super, false),
      'antes', jsonb_build_object(
        'es_admin', coalesce(v_perfil.es_admin, false),
        'es_super_admin', coalesce(v_perfil.es_super_admin, false),
        'codigo', v_perfil.admin_codigo)),
    true, null);

  return 'Listo: ' || v_codigo || ' · ' || v_nombre;
end;
$fn$;

-- ---------------------------------------------------------------------------
--  PASO 6 - Quitar
--
--  Dos guardas que no son burocracia:
--
--   - NADIE SE QUITA EL CARGO A SI MISMO. Un clic sin querer y el licenciatario
--     se queda fuera de su propio panel, sin nadie que pueda devolverselo.
--   - SIEMPRE TIENE QUE QUEDAR UN SUPER ADMIN. Lo mismo, pero sin vuelta atras
--     posible desde la aplicacion: habria que entrar a la base a mano.
-- ---------------------------------------------------------------------------
create or replace function public.quitar_admin(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_yo uuid := auth.uid();
  v_soy_super boolean;
  v_perfil public.profiles%rowtype;
  v_supers int;
begin
  if v_yo is null then
    raise exception 'No autenticado';
  end if;

  -- El alias `pr.` es obligatorio aqui: ver la nota del encabezado (42702).
  select coalesce(pr.es_super_admin, false) into v_soy_super
  from public.profiles pr where pr.id = v_yo;

  if coalesce(v_soy_super, false) = false then
    raise exception 'No autorizado: solo un super admin puede quitar administradores';
  end if;

  if p_user_id = v_yo then
    raise exception 'No puedes quitarte el cargo a ti mismo. Pideselo a otro super admin.';
  end if;

  select * into v_perfil from public.profiles where id = p_user_id;
  if not found then
    raise exception 'Ese usuario no existe';
  end if;

  if not (coalesce(v_perfil.es_admin, false) or coalesce(v_perfil.es_super_admin, false)) then
    raise exception 'Esa persona ya no es administradora';
  end if;

  if coalesce(v_perfil.es_super_admin, false) then
    select count(*) into v_supers
    from public.profiles where coalesce(es_super_admin, false);
    if v_supers <= 1 then
      raise exception 'Es el ultimo super admin. Nombra a otro antes de quitarle el cargo a este.';
    end if;
  end if;

  -- El codigo y el nombre NO se borran. Ver la cabecera: un codigo reutilizado
  -- reescribiria el pasado del registro.
  update public.profiles
     set es_admin = false, es_super_admin = false
   where id = p_user_id;

  perform public.log_admin_action(
    v_yo, 'quitar_admin', 'profiles', p_user_id::text,
    jsonb_build_object(
      'codigo', v_perfil.admin_codigo,
      'nombre', v_perfil.admin_nombre,
      'antes', jsonb_build_object(
        'es_admin', coalesce(v_perfil.es_admin, false),
        'es_super_admin', coalesce(v_perfil.es_super_admin, false))),
    true, null);

  return 'Cargo retirado. El codigo ' || coalesce(v_perfil.admin_codigo, '(sin codigo)') ||
         ' queda reservado para que el registro siga siendo legible.';
end;
$fn$;

-- ---------------------------------------------------------------------------
--  PASO 7 - Permisos. Inventario declarado, como manda el 20260929110000.
-- ---------------------------------------------------------------------------
revoke all on function public.buscar_usuario_para_admin(text)            from public, anon;
revoke all on function public.listar_admins()                            from public, anon;
revoke all on function public.nombrar_admin(uuid, text, text, boolean)   from public, anon;
revoke all on function public.quitar_admin(uuid)                         from public, anon;

grant execute on function public.buscar_usuario_para_admin(text)          to authenticated;
grant execute on function public.listar_admins()                          to authenticated;
grant execute on function public.nombrar_admin(uuid, text, text, boolean) to authenticated;
grant execute on function public.quitar_admin(uuid)                       to authenticated;
