-- ===========================================================================
--  20261010193000_fundar_super_admin.sql
--
--  QUE ARREGLA  (pendiente 5.3, y el unico paso manual del alta de un cliente)
--
--  Hasta hoy, el primer administrador de una instalacion nueva se creaba con
--  un UPDATE a mano en el SQL Editor. Funciona, y tiene dos problemas que no
--  son de comodidad:
--
--    1. QUIEN LO HACE ES JERCOL, DENTRO DE LA BASE DEL CLIENTE. Esa base va a
--       tener el dinero de sus jugadores. Que el proveedor del software entre
--       ahi no solo es incomodo de vender: si manana falta un bolivar, el
--       ultimo que toco esa base fue el proveedor. Lo mejor que le puede pasar
--       a Jercol es NO PODER entrar.
--
--    2. Con N clientes son N oportunidades de escribir mal un correo, de
--       olvidar el `admin_codigo` (ADR-027) o de afectar cero filas y no
--       darse cuenta.
--
--  POR QUE NO SE PUEDE SIMPLEMENTE PONER UN BOTON
--
--  Huevo y gallina a proposito: `nombrar_admin` exige un super admin para
--  funcionar, y en una base nueva no hay ninguno. Si el primer super admin se
--  pudiera crear desde la pantalla sin mas, **el primero que se registrara se
--  quedaria con la casa** -- con el poder de aprobar recargas, pagar retiros y
--  liquidar remates.
--
--  LOS DOS CANDADOS
--
--    1. SOLO SI NO HAY NINGUN SUPER ADMIN. La funcion se cierra sola, para
--       siempre, en cuanto se usa una vez. No es una bandera que alguien pueda
--       volver a poner: es el propio estado de la tabla.
--
--    2. EL CORREO TIENE QUE COINCIDIR con `correo_fundador`, que quien instala
--       deja en `ajustes_instalacion`. Sin este segundo candado, el primero en
--       registrarse se queda la casa igual que antes.
--
--  Si, con esto Jercol sigue escribiendo una fila en la base del cliente. Pero
--  lo hace AL INSTALAR, antes de que exista un solo bolivar, y no despues con
--  el dinero dentro. Es una diferencia de naturaleza, no de grado.
--
--  POR QUE EL ERROR DEL CANDADO 2 NO DICE CUAL ES EL CORREO ESPERADO
--
--  Porque cualquiera con una cuenta podria llamarla y averiguar el correo del
--  dueno. El mensaje dice que no eres tu y manda a hablar con quien instalo.
--  Depurar un correo mal escrito es cosa de quien lo escribio, que tiene
--  acceso a la tabla.
--
--  LO QUE NO HACE: registrar el intento fallido. `log_admin_action` en el
--  camino malo no sirve -- al re-lanzar, PostgreSQL se lleva el propio
--  asiento. Es el pendiente 5.2 y esta migracion no lo cambia.
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  PASO 1 - la clave, vacia
--
--  Nace VACIA a proposito. Una instalacion sin fundador designado no se puede
--  fundar, y eso es lo correcto: obliga a que alguien decida de quien es la
--  casa antes de que nadie pueda reclamarla.
-- ---------------------------------------------------------------------------
insert into public.ajustes_instalacion (clave, valor, tipo, descripcion) values
  ('correo_fundador',
   '',
   'texto',
   'Correo de la persona que fundara esta casa, tal como se registrara en la aplicacion. Lo pone quien instala, ANTES de entregar. Vacio = la casa todavia no se puede fundar.')
on conflict (clave) do nothing;


-- ---------------------------------------------------------------------------
--  PASO 2 - saber si la casa ya tiene dueno, sin tener sesion
--
--  La pantalla de /admin/login necesita preguntarlo ANTES de que nadie entre,
--  para decidir si ensena el formulario de fundacion. Por eso la lee `anon`.
--
--  Lo unico que revela es si existe o no un super admin. NO revela el correo
--  designado, que es lo que hay que proteger.
-- ---------------------------------------------------------------------------
create or replace function public.casa_fundada()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select exists (
    select 1 from public.profiles p where coalesce(p.es_super_admin, false)
  );
$fn$;

comment on function public.casa_fundada() is
  'true si esta instalacion ya tiene super admin. La usa /admin/login para decidir si ofrece fundar la casa. No revela quien ni con que correo.';

revoke all on function public.casa_fundada() from public;
grant execute on function public.casa_fundada() to anon, authenticated;


-- ---------------------------------------------------------------------------
--  PASO 3 - fundar
-- ---------------------------------------------------------------------------
create or replace function public.fundar_super_admin(p_codigo text, p_nombre text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_yo      uuid := auth.uid();
  v_codigo  text := upper(trim(coalesce(p_codigo, '')));
  v_nombre  text := trim(coalesce(p_nombre, ''));
  v_esperado text;
  v_mio     text;
  v_ya      boolean;
begin
  if v_yo is null then
    raise exception 'No autenticado';
  end if;

  -- Dos personas pulsando a la vez en una instalacion recien abierta es poco
  -- probable y catastrofico: las dos verian "no hay super admin" y las dos
  -- fundarian. El candado lo serializa.
  perform pg_advisory_xact_lock(9, 0);

  -- ---------------------------------------------------------------- candado 1
  select exists (
    select 1 from public.profiles p where coalesce(p.es_super_admin, false)
  ) into v_ya;

  if v_ya then
    raise exception 'Esta casa ya tiene dueno. Fundar solo se puede una vez, en una instalacion recien creada. Si necesitas otro administrador, el super admin lo nombra desde el panel.';
  end if;

  -- ---------------------------------------------------------------- candado 2
  select nullif(trim(a.valor), '') into v_esperado
  from public.ajustes_instalacion a
  where a.clave = 'correo_fundador';

  if v_esperado is null then
    raise exception 'Esta instalacion no tiene fundador designado todavia. Quien la instalo tiene que poner el correo en ajustes_instalacion (clave correo_fundador) antes de que la casa se pueda fundar.';
  end if;

  select u.email into v_mio from auth.users u where u.id = v_yo;

  -- Se comparan en minusculas y sin espacios: un correo con una mayuscula de
  -- mas no es otro correo, y hacer fallar a alguien por eso solo garantiza
  -- que acabe pidiendo que alguien entre a la base a arreglarlo -- que es lo
  -- que esta migracion viene a evitar.
  if lower(trim(coalesce(v_mio, ''))) <> lower(v_esperado) then
    raise exception 'Tu cuenta no es la designada para fundar esta casa. Habla con quien hizo la instalacion.';
  end if;

  -- ---------------------------------------------------------------- identidad
  -- Mismas reglas que `nombrar_admin` (ADR-027). Un super admin sin codigo es
  -- justo lo que el aviso ambar de /admin/super/admins viene a senalar: no se
  -- funda una casa estrenando ya ese defecto.
  if v_codigo !~ '^[A-Z0-9]{2,6}$' then
    raise exception 'El codigo tiene entre 2 y 6 caracteres, solo letras y numeros. Recibido: "%"', v_codigo;
  end if;

  if length(v_nombre) < 3 then
    raise exception 'El nombre visible tiene que tener al menos 3 caracteres';
  end if;

  update public.profiles
     set es_admin       = true,
         es_super_admin = true,
         admin_codigo   = v_codigo,
         admin_nombre   = v_nombre
   where id = v_yo;

  if not found then
    raise exception 'Tu perfil no existe. Cierra sesion, vuelve a entrar y reintenta.';
  end if;

  -- El primer asiento de la casa dice quien la fundo y cuando. Es el unico
  -- nombramiento que no tiene a otro administrador detras, asi que conviene
  -- que quede escrito con mas detalle que los demas.
  perform public.log_admin_action(
    v_yo,
    'fundar_super_admin',
    'profiles',
    v_yo::text,
    jsonb_build_object(
      'codigo', v_codigo,
      'nombre', v_nombre,
      'correo_designado', v_esperado,
      'nota', 'Primer super admin de esta instalacion. Creado por la propia persona, no por el proveedor.'));

  return 'Casa fundada. ' || v_nombre || ' (' || v_codigo || ') es el super administrador.';
end
$fn$;

comment on function public.fundar_super_admin(text, text) is
  'Convierte en super admin a quien la llama, SOLO si esta instalacion no tiene ninguno todavia Y su correo coincide con ajustes_instalacion.correo_fundador. Se cierra sola tras el primer uso. Quita el unico paso manual del alta de un licenciatario (pendiente 5.3, 10/10/2026).';

-- Permisos explicitos: lo que no se nombra, queda fuera (regla del 29/09).
-- `anon` NO: hay que tener sesion, porque la funcion actua sobre quien llama.
revoke all on function public.fundar_super_admin(text, text) from public, anon, authenticated;
grant execute on function public.fundar_super_admin(text, text) to authenticated;
