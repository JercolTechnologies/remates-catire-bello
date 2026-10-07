-- ===========================================================================
--  20261007130000_crear_remate_completo.sql
--
--  CREAR UN REMATE PASA A SER UNA SOLA TRANSACCION
--
--  EL PROBLEMA, MEDIDO (07/10/2026)
--
--  Hasta hoy, crear un remate eran CINCO llamadas desde el navegador, y cada
--  una su propia transaccion ya confirmada:
--
--    1. insert en races                 -> confirmado
--    2. insert en remates ('abierto')   -> confirmado
--    3. insert en horses
--    4. select en horses (recuperar ids)
--    5. insert en remate_price_rules    -> confirmado
--
--  Si falla la 3, las dos primeras estan en disco y no hay nada que deshacer.
--  Y el `catch` del formulario hacia exactamente una cosa: `setError(...)`.
--  Ni un delete, ni un intento de limpieza.
--
--  Reproducido en el arnes, con el admin repitiendo el numero 5:
--
--    carrera_huerfana | remate_huerfano | estado  | caballos | senales
--    -----------------+-----------------+---------+----------+--------
--                   1 |               1 | abierto |        0 |       1
--
--  Un remate ABIERTO, visible al publico, con cero caballos. Y la senal del
--  ADR-031 ya emitida: el remate roto no se queda esperando a que alguien lo
--  encuentre, se le empuja a la pantalla de todos los jugadores conectados.
--
--  LA SEGUNDA VICTIMA, QUE NO SE VE: entre el paso 3 y el 5 el remate ya esta
--  abierto y los caballos ya existen, pero las ESCALERAS todavia no. Un
--  jugador que puje en esos milisegundos recibe `remates.incremento_minimo` en
--  vez de la escalera que el admin configuro. Dentro de una transaccion eso es
--  imposible: en READ COMMITTED nadie ve filas sin confirmar.
--
--  LO QUE ESTA MIGRACION **NO** HACE, Y ES A PROPOSITO
--
--  No añade ni una regla de negocio nueva. Las reglas ya estaban todas en la
--  base y lo unico que cambia es CUANDO se aplican:
--
--    * `horses_race_id_numero_key UNIQUE (race_id, numero)` viene en el
--      baseline, linea 2050. La base SIEMPRE rechazo dos caballos con el mismo
--      numero, con 23505. Esa restriccion no es la victima del fallo: es el
--      gatillo. Lo que faltaba era que disparara dentro de una transaccion.
--    * los NOT NULL de las cuatro tablas.
--    * `trg_minimo_precio_salida`, `trg_minimo_incremento_remate` y
--      `trg_minimo_incremento_regla`, que leen ajustes_instalacion.
--
--  Todos siguen siendo los mismos, y ahora un rechazo de cualquiera de ellos
--  no deja nada escrito.
--
--  LAS DOS COSAS QUE SI PONE AQUI, dichas en voz alta para que nadie las
--  descubra leyendo el cuerpo:
--
--    1. UN REMATE SIN CABALLOS NO EXISTE. El esquema lo permite y es
--       exactamente el estado de basura que esta migracion viene a impedir, asi
--       que se rechaza. El formulario ya lo exigia; ahora tambien la base.
--    2. El 23505 se traduce a una frase que un admin entienda. Es presentacion
--       de un error, no una regla: quien rechaza sigue siendo el indice.
--
--  Y lo que queda FUERA a proposito, para que esta migracion sea una sola cosa:
--
--    * el estado del remate cuando `opens_at` es futuro (pendiente 2). Se
--      sigue guardando 'abierto' porque el enum `remate_status` tiene cuatro
--      valores y ninguno es 'programado'. Decision aparte.
--    * la clave de idempotencia. Hoy un doble clic crea dos remates, y con
--      esta migracion sigue creando dos: no empeora ni mejora. La guarda del
--      formulario sigue siendo la unica, y sigue siendo del cliente.
--    * el `closes_at > opens_at`, que hoy solo comprueba el formulario.
--
--  LA AUDITORIA DEL FALLO SIGUE SIN PODER EXISTIR. `log_admin_action` se llama
--  en el camino bueno. En el malo no se llama, y si se llamara tampoco
--  serviria: al re-lanzar, PostgreSQL se lleva el propio asiento. Es el
--  pendiente 5.2, y esta migracion no lo cambia.
--
--  FORMA DEL PAYLOAD
--
--  Tres jsonb en vez de treinta parametros, porque los caballos llevan sus
--  escaleras colgando y eso no se aplana sin mentir.
--
--    p_carrera  = { nombre, hipodromo, numero_carrera, numero_carrera_text,
--                   fecha, hora_programada, dia, distancia_m }
--    p_remate   = { nombre, incremento_minimo, porcentaje_casa, tipo,
--                   opens_at, closes_at }
--    p_caballos = [ { numero, nombre, jinete, entrenador, comentarios,
--                     precio_salida,
--                     reglas: [ { min_precio, max_precio, incremento } ] } ]
--
--  Los nombres de las columnas de salida llevan prefijo (`id_carrera`,
--  `id_remate`, `n_caballos`, `n_reglas`) y NO son `race_id` ni `remate_id` a
--  proposito: en `returns table` los nombres de salida se vuelven variables, y
--  `race_id` existe como columna en horses y en remates. Eso es el 42702 que
--  tumbo a `listar_admins` el 05/10. Aqui ademas todas las tablas van con
--  alias.
-- ===========================================================================

create or replace function public.crear_remate_completo(
  p_carrera  jsonb,
  p_remate   jsonb,
  p_caballos jsonb
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
    opens_at, closes_at
  )
  values (
    v_race,
    p_remate->>'nombre',
    (p_remate->>'incremento_minimo')::numeric,
    (p_remate->>'porcentaje_casa')::numeric,
    coalesce(nullif(p_remate->>'tipo', ''), 'vivo'),
    (nullif(p_remate->>'opens_at', ''))::timestamptz,
    (nullif(p_remate->>'closes_at', ''))::timestamptz
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

comment on function public.crear_remate_completo(jsonb, jsonb, jsonb) is
  'Crea carrera + remate + caballos + escaleras en UNA transaccion. Un fallo a mitad no deja nada escrito (pendiente 1.1, 07/10/2026).';

-- Permisos explicitos: lo que no se nombra, queda fuera (regla del 29/09).
-- Si esto quedara mal, P47 se pone rojo.
revoke all on function public.crear_remate_completo(jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.crear_remate_completo(jsonb, jsonb, jsonb)
  to authenticated;
