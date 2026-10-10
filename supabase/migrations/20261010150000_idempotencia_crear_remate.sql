-- ===========================================================================
--  20261010150000_idempotencia_crear_remate.sql
--
--  QUE ARREGLA  (pendiente 1.2, abierto desde el 07/10)
--
--  Un doble clic creaba dos remates. Y hay que decir con precision por que,
--  porque es facil creer que la transaccion del 07/10 ya lo cubria:
--
--      Dos clics son dos llamadas COMPLETAS Y CORRECTAS.
--
--  No hay nada a medias que deshacer. `crear_remate_completo` hace su trabajo
--  bien las dos veces. La base creaba dos remates porque NO TENIA FORMA DE
--  SABER que era el mismo. Una transaccion decide que se guarda todo o nada;
--  no decide si dos peticiones son la misma peticion.
--
--  Las dos guardas que habia (`if (saving) return` y `if (createdRemateId)`)
--  son del NAVEGADOR. Protegen del doble clic rapido en la misma pestana, y de
--  nada mas: recargar y reenviar las salta, dos pestanas las saltan, y una
--  respuesta que tarda y el admin que insiste las salta.
--
--  LA SOLUCION: UNA CLAVE QUE PONE QUIEN PIDE
--
--  El formulario genera una clave al abrirse y la repite en CADA reintento.
--  Dos envios con la misma clave son, por definicion, el mismo remate -- y eso
--  la base si lo puede afirmar, porque es un dato, no una suposicion.
--
--  El segundo envio NO crea nada y NO falla: devuelve el remate del primero,
--  con la misma forma de respuesta. Para el formulario es indistinguible de
--  haber acertado a la primera, que es justo lo que se quiere -- un admin que
--  hizo doble clic no tiene por que ver un error.
--
--  POR QUE UNA COLUMNA Y NO UNA TABLA APARTE. La clave es un atributo del
--  remate: con quien lo creo y cuando. Una tabla de claves seria un sitio mas
--  que limpiar y una union mas que hacer, y dejaria la puerta a que exista una
--  clave sin remate.
--
--  EL INDICE ES PARCIAL (`where clave_creacion is not null`). Los remates
--  anteriores a hoy -- y los que se creen sin clave -- quedan fuera del
--  indice en vez de ocupar una entrada nula cada uno.
--
--  POR QUE `p_clave` TIENE VALOR POR OMISION, y esto importa para el despliegue.
--  El orden es BASE PRIMERO y codigo despues. Entre los dos pasos, el frontend
--  desplegado llama con TRES argumentos: con el valor por omision, esa llamada
--  sigue siendo valida y se comporta igual que hoy. Sin el, cada creacion de
--  remate entre un paso y el otro habria fallado.
--
--  HAY DROP DE LA FIRMA VIEJA. `create or replace` NO puede anadir un
--  parametro: crearia una funcion NUEVA y dejaria la de tres argumentos viva.
--  Dos sobrecargas con el mismo nombre dejan a PostgREST eligiendo, que es
--  justo lo que no se quiere para la funcion que crea remates.
--
--  LO QUE NO HACE: cerrar `remates.insert` para `authenticated` (pendiente
--  1.4). Es una linea y no hay ya ninguna pantalla que inserte directo, pero
--  es otra cosa y va en su propia migracion.
--
--  La funcion se REGENERA entera, extraida de 20261007130000 con un script y
--  parcheada en cuatro sitios. No se reteclea un cuerpo PL/pgSQL (ADR-021).
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  PASO 1 - la columna y su indice
-- ---------------------------------------------------------------------------
alter table public.remates
  add column if not exists clave_creacion text;

comment on column public.remates.clave_creacion is
  'Clave de idempotencia que pone el formulario al crear. Dos envios con la misma clave son el mismo remate. Nula en los remates creados antes del 10/10/2026.';

create unique index if not exists remates_clave_creacion_key
  on public.remates (clave_creacion)
  where clave_creacion is not null;


-- ---------------------------------------------------------------------------
--  PASO 2 - la funcion, con la clave
-- ---------------------------------------------------------------------------
drop function if exists public.crear_remate_completo(jsonb, jsonb, jsonb);

create or replace function public.crear_remate_completo(
  p_carrera  jsonb,
  p_remate   jsonb,
  p_caballos jsonb,
  p_clave    text default null
)
returns table (
  id_carrera uuid,
  id_remate  uuid,
  n_caballos integer,
  n_reglas   integer
)
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;

  v_race   uuid;
  v_remate uuid;
  v_horse  uuid;

  v_caballo jsonb;
  v_regla   jsonb;
  v_numero  integer;

  v_caballos integer := 0;
  v_reglas   integer := 0;

  -- Para la respuesta cuando la clave ya se uso.
  v_ya public.remates%rowtype;
begin
  -- ------------------------------------------------------------------ quien
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select (coalesce(pr.es_admin, false) or coalesce(pr.es_super_admin, false))
    into v_is_admin
  from public.profiles pr
  where pr.id = v_admin_id;

  if coalesce(v_is_admin, false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  -- ------------------------------------------------------ clave de creacion
  -- EL DOBLE CLIC, CERRADO EN LA BASE (pendiente 1.2).
  --
  -- Jota lo encontro asi: "al crearse un remate, el boton de crear remate
  -- queda activo y si le doy 20 veces mas, crea 20 remates con el mismo
  -- nombre y los mismos datos".
  --
  -- La transaccion del 07/10 NO arreglo esto, y conviene tenerlo claro: dos
  -- clics son dos llamadas COMPLETAS Y CORRECTAS. No hay nada a medias que
  -- deshacer. La base creaba dos remates porque no tenia forma de saber que
  -- era el mismo. Las dos guardas del formulario eran la unica defensa, y
  -- eran del navegador: recargar y reenviar las saltaba.
  --
  -- La clave la pone QUIEN PIDE, no quien recibe. El formulario la genera una
  -- vez y la repite en cada reintento; dos envios con la misma clave son el
  -- mismo remate por definicion, y la base lo puede afirmar.
  --
  -- EL CANDADO VA ANTES DE MIRAR, no despues. Sin el, dos clics casi a la vez
  -- entran los dos en el `select`, los dos no encuentran nada, y los dos
  -- intentan insertar: uno gana y el otro recibe un 23505 del indice unico --
  -- correcto en cuanto a datos, feo en cuanto a mensaje. Con el candado, el
  -- segundo espera, y cuando mira ya encuentra el remate del primero.
  --
  -- NO SE REPITE LA BITACORA. El segundo envio no creo nada, asi que no hay
  -- nada que registrar: anotarlo seria el defecto que cerro ADR-038, una
  -- bitacora anunciando lo que no paso.
  if p_clave is not null and length(trim(p_clave)) > 0 then
    perform pg_advisory_xact_lock(7, hashtext(trim(p_clave)));

    select * into v_ya
    from public.remates r
    where r.clave_creacion = trim(p_clave);

    if found then
      return query
      select v_ya.race_id,
             v_ya.id,
             (select count(*)::integer from public.horses h where h.race_id = v_ya.race_id),
             (select count(*)::integer from public.remate_price_rules pr where pr.remate_id = v_ya.id);
      return;
    end if;
  end if;

  -- UN REMATE SIN CABALLOS NO EXISTE.
  -- El esquema lo permite y es justo el estado que esta migracion viene a
  -- impedir. Se comprueba ANTES de escribir, para que el caso normal no
  -- dependa de que el rollback funcione.
  if p_caballos is null
     or jsonb_typeof(p_caballos) <> 'array'
     or jsonb_array_length(p_caballos) = 0 then
    raise exception 'Un remate necesita al menos un caballo';
  end if;

  -- ---------------------------------------------------------------- carrera
  -- `estado` se deja en su valor por omision ('programada'). Lo que el
  -- formulario escribia a mano era ese mismo valor.
  insert into public.races (
    nombre, hipodromo, numero_carrera, numero_carrera_text,
    fecha, hora_programada, dia, distancia_m
  )
  values (
    p_carrera->>'nombre',
    nullif(p_carrera->>'hipodromo', ''),
    (nullif(p_carrera->>'numero_carrera', ''))::integer,
    nullif(p_carrera->>'numero_carrera_text', ''),
    (p_carrera->>'fecha')::date,
    (nullif(p_carrera->>'hora_programada', ''))::time,
    nullif(p_carrera->>'dia', ''),
    (nullif(p_carrera->>'distancia_m', ''))::numeric
  )
  returning races.id into v_race;

  -- ----------------------------------------------------------------- remate
  insert into public.remates (
    race_id, nombre, incremento_minimo, porcentaje_casa, tipo,
    opens_at, closes_at, clave_creacion
  )
  values (
    v_race,
    p_remate->>'nombre',
    (p_remate->>'incremento_minimo')::numeric,
    (p_remate->>'porcentaje_casa')::numeric,
    coalesce(nullif(p_remate->>'tipo', ''), 'vivo'),
    (nullif(p_remate->>'opens_at', ''))::timestamptz,
    (nullif(p_remate->>'closes_at', ''))::timestamptz,
    nullif(trim(coalesce(p_clave, '')), '')
  )
  returning remates.id into v_remate;

  -- --------------------------------------------------------------- caballos
  -- `insert ... returning` da el id al momento: el `select` que hacia el
  -- formulario para recuperarlos (paso 4 de los cinco) desaparece.
  for v_caballo in select value from jsonb_array_elements(p_caballos)
  loop
    v_numero := (v_caballo->>'numero')::integer;

    begin
      insert into public.horses (
        race_id, numero, nombre, jinete, entrenador, comentarios, precio_salida
      )
      values (
        v_race,
        v_numero,
        v_caballo->>'nombre',
        nullif(v_caballo->>'jinete', ''),
        nullif(v_caballo->>'entrenador', ''),
        nullif(v_caballo->>'comentarios', ''),
        (v_caballo->>'precio_salida')::numeric
      )
      returning horses.id into v_horse;
    exception
      -- TRADUCCION, NO REGLA. Quien rechaza sigue siendo
      -- horses_race_id_numero_key. Lo unico que cambia es que el admin lee una
      -- frase en vez de "duplicate key value violates unique constraint".
      when unique_violation then
        raise exception 'El numero % esta repetido: cada caballo de la carrera necesita un numero distinto', v_numero;
    end;

    v_caballos := v_caballos + 1;

    -- Escalera propia del caballo, si la trae. Un caballo sin reglas no recibe
    -- ninguna fila, y por eso la base le aplica `remates.incremento_minimo`.
    -- Esa es toda la regla general (ADR del 30/09).
    if jsonb_typeof(v_caballo->'reglas') = 'array' then
      for v_regla in select value from jsonb_array_elements(v_caballo->'reglas')
      loop
        insert into public.remate_price_rules (
          remate_id, horse_id, min_precio, max_precio, incremento
        )
        values (
          v_remate,
          v_horse,
          (v_regla->>'min_precio')::numeric,
          (nullif(v_regla->>'max_precio', ''))::numeric,
          (v_regla->>'incremento')::numeric
        );
        v_reglas := v_reglas + 1;
      end loop;
    end if;
  end loop;

  -- --------------------------------------------------------------- bitacora
  -- Solo el camino bueno. El malo no puede registrarse: ver la cabecera.
  perform public.log_admin_action(
    v_admin_id,
    'crear_remate_completo',
    'remates',
    v_remate::text,
    jsonb_build_object(
      'race_id',   v_race,
      'remate_id', v_remate,
      'caballos',  v_caballos,
      'reglas',    v_reglas,
      'carrera',   p_carrera->>'nombre',
      'remate',    p_remate->>'nombre'
    )
  );

  return query select v_race, v_remate, v_caballos, v_reglas;
end
$fn$;

comment on function public.crear_remate_completo(jsonb, jsonb, jsonb, text) is
  'Crea carrera + remate + caballos + escaleras en UNA transaccion. Un fallo a mitad no deja nada escrito (07/10/2026). Desde el 10/10 acepta una clave de idempotencia: dos envios con la misma clave devuelven el mismo remate en vez de crear dos.';

-- Permisos explicitos: lo que no se nombra, queda fuera (regla del 29/09).
-- La firma cambio, asi que estos son permisos NUEVOS, no una repeticion: sin
-- esta declaracion la funcion se queda sin `execute` y P47 se pone rojo.
revoke all on function public.crear_remate_completo(jsonb, jsonb, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.crear_remate_completo(jsonb, jsonb, jsonb, text)
  to authenticated;
