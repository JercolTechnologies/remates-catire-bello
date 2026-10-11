-- ===========================================================================
--  20261011011500_datos_de_cobro_por_instalacion.sql
--
--  EL DEFECTO: UNA SOLA CUENTA BANCARIA PARA TODAS LAS CASAS
--
--  `app/dashboard/recargar/page.tsx` lleva clavados en el HTML el banco, el
--  telefono de Pago Movil, la cedula y el numero de cuenta. Una pagina, un
--  repositorio, y DOS proyectos de Vercel compilando la misma rama: produccion
--  y la primera licencia le estaban diciendo a sus jugadores que depositaran
--  en la MISMA cuenta.
--
--  No es un defecto cosmetico. Es la pantalla que le dice a una persona donde
--  poner su dinero. Mientras siguiera en el codigo, cada licencia nueva exigia
--  editar el repositorio y volver a desplegar -- es decir, Jercol decidiendo
--  donde cobra la casa del cliente. Eso es lo contrario del ADR-045.
--
--  DECISION: los datos de cobro son de la INSTALACION, y los pone su dueno.
--
--  `ajustes_instalacion` ya existia para esto. La migracion 20261005140000 lo
--  dejo escrito: "va a ir creciendo: en el bloque de licencias le entran datos
--  bancarios, SMTP y la marca". Esto es ese bloque.
--
--  TRES VENTANILLAS, NO UNA PUERTA
--
--  La tabla sigue cerrada. Lo que cambia es que ahora hay tres funciones con
--  lista blanca, cada una con su publico, y lo que no este nombrado dentro no
--  sale aunque alguien anada la clave manana:
--
--    ajustes_publicos()  -> anon + authenticated. Las reglas y la MARCA de la
--                           casa, que se ven antes de registrarse.
--    datos_de_cobro()    -> SOLO authenticated. Donde se deposita. Un visitante
--                           sin cuenta no tiene nada que hacer con eso, y no
--                           hace falta regalarselo a un raspador.
--    guardar_ajustes()   -> SOLO super admin, y DEJA ASIENTO.
--
--  POR QUE SE CIERRA EL UPDATE DIRECTO
--
--  La politica `ajustes_cambia_superadmin` permitia que el super admin
--  escribiera la tabla desde el navegador. Cambiar la cuenta donde cobra la
--  casa es la operacion mas sensible de toda la aplicacion -- mas que pagar un
--  retiro, porque redirige TODOS los depositos futuros -- y pasaba sin dejar
--  rastro en la bitacora.
--
--  Comprobado antes de cerrarla: el frontend solo hace SELECT sobre esta tabla
--  (`crear-remate` y `remates/[id]`, para los minimos). Nadie hace UPDATE. Se
--  revoca el privilegio y se borra la politica, y todo escribe por la funcion,
--  que registra que cambio, de que a que, y quien lo hizo (ADR-027).
--
--  LOS VALORES NACEN VACIOS, A PROPOSITO. Una instalacion recien entregada no
--  tiene datos de cobro, y la pantalla tiene que decir eso en vez de inventar
--  unos. Sembrarlos con los de otro es exactamente el defecto que arregla esta
--  migracion.
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  1. Las claves. Las crean las migraciones; el dueno solo cambia valores.
-- ---------------------------------------------------------------------------
insert into public.ajustes_instalacion (clave, valor, tipo, descripcion) values
  ('casa_nombre',
   '',
   'texto',
   'Nombre comercial de esta casa. Se ensena junto al de la plataforma, nunca en su lugar.'),

  ('casa_logo_url',
   '',
   'texto',
   'URL del logo de esta casa. Opcional: sin el se ensena solo el nombre.'),

  ('pago_titular',
   '',
   'texto',
   'A nombre de quien estan la cuenta y el Pago Movil. Lo ve el jugador antes de depositar.'),

  ('pago_documento',
   '',
   'texto',
   'Cedula o RIF del titular. Vale para el Pago Movil y para la transferencia.'),

  ('pago_movil_banco',
   '',
   'texto',
   'Banco del Pago Movil.'),

  ('pago_movil_telefono',
   '',
   'texto',
   'Telefono del Pago Movil.'),

  ('pago_transf_banco',
   '',
   'texto',
   'Banco de la transferencia.'),

  ('pago_transf_tipo',
   '',
   'texto',
   'Tipo de cuenta de la transferencia: corriente, ahorro, etc.'),

  ('pago_transf_numero',
   '',
   'texto',
   'Numero de cuenta de la transferencia.')
on conflict (clave) do nothing;


-- ---------------------------------------------------------------------------
--  2. `ajustes_publicos()` crece con la marca -- y SOLO con la marca.
--
--  El nombre y el logo de la casa se ensenan en la portada, que la ve quien
--  todavia no tiene cuenta. Los datos de cobro NO entran aqui: esta funcion la
--  puede llamar `anon`.
-- ---------------------------------------------------------------------------
create or replace function public.ajustes_publicos()
returns table (clave text, valor text)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select a.clave, a.valor
  from public.ajustes_instalacion a
  where a.clave in (
    -- Lo que el JUGADOR necesita saber para decidir si juega.
    'pct_apostado_para_retirar',
    'minimo_incremento',
    'minimo_precio_salida',
    -- Y de quien es la casa en la que esta entrando.
    'casa_nombre',
    'casa_logo_url'
  );
$fn$;

comment on function public.ajustes_publicos() is
  'Los ajustes que puede ver cualquiera, con o sin sesion: las reglas del dinero y la marca de la casa. Lista blanca: lo que no este nombrado dentro no sale. Los datos de cobro NO estan aqui, estan en datos_de_cobro(). Ver 20261005140000 y 20261011011500.';

revoke all on function public.ajustes_publicos() from public;
grant execute on function public.ajustes_publicos() to anon, authenticated;


-- ---------------------------------------------------------------------------
--  3. `datos_de_cobro()` -- la ventanilla de quien ya tiene cuenta.
-- ---------------------------------------------------------------------------
create or replace function public.datos_de_cobro()
returns table (clave text, valor text)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select a.clave, a.valor
  from public.ajustes_instalacion a
  where a.clave in (
    'pago_titular',
    'pago_documento',
    'pago_movil_banco',
    'pago_movil_telefono',
    'pago_transf_banco',
    'pago_transf_tipo',
    'pago_transf_numero'
  );
$fn$;

comment on function public.datos_de_cobro() is
  'Donde deposita el jugador de ESTA casa. Lista blanca sobre ajustes_instalacion. Solo para quien tiene sesion: un visitante sin cuenta no deposita. Ver 20261011011500.';

revoke all on function public.datos_de_cobro() from public, anon;
grant execute on function public.datos_de_cobro() to authenticated;


-- ---------------------------------------------------------------------------
--  4. `guardar_ajustes()` -- la unica forma de escribir, y deja asiento.
--
--  Recibe un objeto {clave: valor}. Guarda SOLO lo que cambia, para que la
--  bitacora no se llene de asientos que no dicen nada, y para que el asiento
--  que si queda sea legible: "esto estaba, esto quedo".
-- ---------------------------------------------------------------------------
create or replace function public.guardar_ajustes(p_valores jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_uid       uuid := auth.uid();
  v_editables text[] := array[
    'casa_nombre',
    'casa_logo_url',
    'pago_titular',
    'pago_documento',
    'pago_movil_banco',
    'pago_movil_telefono',
    'pago_transf_banco',
    'pago_transf_tipo',
    'pago_transf_numero'
  ];
  v_clave   text;
  v_valor   text;
  v_actual  text;
  v_antes   jsonb := '{}'::jsonb;
  v_despues jsonb := '{}'::jsonb;
  v_n       integer := 0;
begin
  if v_uid is null then
    raise exception 'Hay que iniciar sesion.';
  end if;

  -- El candado real. La funcion es security definer y se salta la RLS, asi que
  -- esta comprobacion NO es decorativa: es la unica que queda.
  if not public.is_super_admin() then
    raise exception 'Solo el super administrador puede cambiar los datos de la casa.';
  end if;

  if p_valores is null or jsonb_typeof(p_valores) <> 'object' then
    raise exception 'No llego nada que guardar.';
  end if;

  -- Dos pestanas abiertas guardando a la vez dejarian una bitacora que miente
  -- sobre el valor anterior. El candado las pone en fila.
  perform pg_advisory_xact_lock(11, 0);

  for v_clave, v_valor in
    select e.key, e.value #>> '{}' from jsonb_each(p_valores) e
  loop
    -- Lista blanca de ESCRITURA. `minimo_incremento` y companeras se cambian
    -- por migracion, no desde el navegador: la base valida contra ellas.
    if not (v_clave = any (v_editables)) then
      raise exception 'El ajuste "%" no se cambia desde la aplicacion.', v_clave;
    end if;

    select a.valor into v_actual
    from public.ajustes_instalacion a
    where a.clave = v_clave;

    if v_actual is null then
      raise exception 'El ajuste "%" no existe en esta instalacion. Falta aplicar una migracion.', v_clave;
    end if;

    v_valor := coalesce(btrim(v_valor), '');

    if v_valor is distinct from v_actual then
      update public.ajustes_instalacion
         set valor = v_valor
       where clave = v_clave;

      v_antes   := v_antes   || jsonb_build_object(v_clave, v_actual);
      v_despues := v_despues || jsonb_build_object(v_clave, v_valor);
      v_n := v_n + 1;
    end if;
  end loop;

  -- Sin cambios no hay asiento. Guardar el mismo formulario dos veces no es un
  -- hecho que valga la pena registrar.
  if v_n > 0 then
    perform public.log_admin_action(
      v_uid,
      'ajustes_casa',
      'ajustes_instalacion',
      'instalacion',
      jsonb_build_object('cambios', v_n, 'antes', v_antes, 'despues', v_despues),
      true,
      null
    );
  end if;

  return v_n;
end $fn$;

comment on function public.guardar_ajustes(jsonb) is
  'Cambia los datos de cobro y la marca de esta casa. Solo super admin, solo las claves de su lista blanca, y deja asiento en la bitacora con el valor anterior y el nuevo. Ver 20261011011500.';

revoke all on function public.guardar_ajustes(jsonb) from public, anon;
grant execute on function public.guardar_ajustes(jsonb) to authenticated;


-- ---------------------------------------------------------------------------
--  5. Se cierra el UPDATE directo sobre la tabla.
--
--  Comprobado el 11/10: el frontend solo hace SELECT sobre `ajustes_instalacion`
--  (`app/admin/crear-remate/page.tsx` y `app/admin/remates/[id]/page.tsx`, los
--  minimos). Ningun UPDATE. Cerrarlo no rompe ninguna pantalla y cierra el
--  unico camino que escribia sin dejar rastro.
--
--  El SELECT se queda: lo necesitan esas dos pantallas, y la politica de
--  lectura sigue exigiendo `is_admin()`.
-- ---------------------------------------------------------------------------
revoke update on table public.ajustes_instalacion from authenticated;

drop policy if exists ajustes_cambia_superadmin on public.ajustes_instalacion;

comment on table public.ajustes_instalacion is
  'Ajustes de ESTA instalacion, no del codigo. Cada licenciatario pone los suyos. Las claves las crean las migraciones; los valores se cambian por guardar_ajustes(), que deja asiento. Desde el 11/10/2026 la aplicacion NO puede escribir esta tabla directamente.';
