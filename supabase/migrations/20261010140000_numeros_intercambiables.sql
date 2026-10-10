-- ===========================================================================
--  20261010140000_numeros_intercambiables.sql
--
--  QUE ARREGLA  (pendiente 1.1, medido el 07/10 y arrastrado desde entonces)
--
--  No se podian INTERCAMBIAR los numeros de dos caballos. Pasar el 3 a 5
--  cuando la carrera ya tenia un 5 rebotaba con:
--
--      23505  duplicate key value violates unique constraint
--             "horses_race_id_numero_key"
--
--  ...en el PRIMER update, antes de que el 5 llegara a ser 3. Y el admin lo
--  veia en crudo.
--
--  POR QUE LA TRANSACCION NO LO ARREGLO, que es la parte que importa entender.
--  `guardar_remate_completo` ya era atomica desde el 08/10 (ADR-039): si eso
--  reventaba, no quedaba NADA a medias, y P70 lo demuestra con una foto
--  identica de los caballos antes y despues. El fallo no era de atomicidad.
--  Era que el INDICE comprueba fila a fila un estado -- "no hay dos caballos
--  con el mismo numero" -- que durante un intercambio es FALSO a mitad de
--  camino y solo vuelve a ser cierto cuando el bucle termina.
--
--  Una transaccion decide que se guarda TODO o NADA. No decide CUANDO se
--  comprueban las reglas. Eso es lo que se cambia aqui.
--
--  LAS DOS SALIDAS, Y POR QUE ESTA
--
--    (a) Renumerar en dos pasadas: primero a numeros temporales que no choquen
--        (negativos, por ejemplo) y luego a los definitivos. Funciona, duplica
--        los updates, y mete en la funcion una regla sobre que numeros son
--        "seguros" que habria que mantener para siempre.
--
--    (b) Declarar la restriccion DIFERIBLE y comprobarla al final. Es para lo
--        que existe el diferimiento. Menos codigo, y la regla sigue siendo del
--        indice y no de la funcion.
--
--  Se toma (b).
--
--  `INITIALLY IMMEDIATE`, NO `INITIALLY DEFERRED`. Diferir por defecto en toda
--  la base significa que CUALQUIER escritura con numeros repetidos no se
--  entera hasta el commit, incluida una que no tiene nada que ver con un
--  intercambio. Asi, un insert suelto sigue rebotando al momento, y el
--  diferimiento se pide a mano donde hace falta -- una sola linea, dentro de
--  `guardar_remate_completo`.
--
--  HAY DROP PORQUE NO HAY OTRA FORMA. `ALTER TABLE ... ALTER CONSTRAINT` solo
--  sirve para claves foraneas: la documentacion de PostgreSQL dice "Currently
--  only foreign key constraints may be altered". Para cambiar la
--  diferibilidad de una UNIQUE hay que tirarla y rehacerla. Comprobado antes
--  de escribir esto.
--
--  QUE NO SE ROMPE AL TIRARLA:
--    * Ninguna clave foranea apunta a (race_id, numero) -- las tres que hay
--      sobre `horses` apuntan a `horses(id)`.
--    * No hay ni un `on conflict` sobre `horses` en todo el repositorio, que
--      es el uso que un indice diferible NO admite.
--    * El indice se reconstruye al rehacer la restriccion. La tabla es de
--      doce filas por carrera.
--
--  LO QUE SIGUE IGUAL. Crear un remate con dos caballos repetidos en el mismo
--  envio sigue rebotando AL MOMENTO con el mensaje de ADR-036, y debe seguir
--  asi: ahi no hay ningun intercambio, hay un error del que rellena el
--  formulario. Esta migracion no toca `crear_remate_completo`.
--
--  `guardar_remate_completo` se REGENERA entera, extraida de 20261008150000
--  con un script y parcheada en dos sitios. No se reteclea un cuerpo PL/pgSQL:
--  el 02/10 hacerlo perdio un `pg_advisory_xact_lock` e invento un estado que
--  no existia (ADR-021).
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  PASO 1 - la restriccion, ahora diferible
-- ---------------------------------------------------------------------------
alter table public.horses
  drop constraint if exists horses_race_id_numero_key;

alter table public.horses
  add constraint horses_race_id_numero_key
  unique (race_id, numero)
  deferrable initially immediate;

comment on constraint horses_race_id_numero_key on public.horses is
  'Dos caballos de la misma carrera no pueden llevar el mismo numero. DIFERIBLE desde el 10/10/2026 para que se puedan intercambiar dos numeros dentro de una transaccion; por defecto se comprueba al momento.';


-- ---------------------------------------------------------------------------
--  PASO 2 - guardar_remate_completo, con el diferimiento pedido a mano
-- ---------------------------------------------------------------------------
create or replace function public.guardar_remate_completo(
  p_remate_id  uuid,
  p_carrera    jsonb,
  p_remate     jsonb,
  p_caballos   jsonb,
  p_eliminados jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_race_id  uuid;

  v_race   public.races%rowtype;
  v_caballo jsonb;
  v_regla   jsonb;
  v_viejo  public.horses%rowtype;
  v_horse  uuid;
  v_id     uuid;

  v_cambios  jsonb := '{}'::jsonb;
  v_escaleras jsonb := '[]'::jsonb;
  v_altas int := 0; v_bajas int := 0; v_tocados int := 0;

  -- Valores nuevos de la carrera, ya normalizados.
  v_nombre text; v_hipodromo text; v_ncarrera integer; v_ncarrera_t text;
  v_fecha date; v_hora time; v_dia text; v_distancia numeric; v_estado text;
begin
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

  if p_caballos is null or jsonb_typeof(p_caballos) <> 'array' then
    raise exception 'Los caballos tienen que venir en una lista';
  end if;

  perform pg_advisory_xact_lock(2, hashtext(p_remate_id::text));

  -- SE DIFIERE LA UNICA DE (race_id, numero) HASTA EL FINAL DE LOS CABALLOS.
  --
  -- Sin esto no se pueden INTERCAMBIAR dos numeros. Pasar el 3 a 5 cuando ya
  -- hay un 5 rebotaba con 23505 en el PRIMER update, antes de que el 5 llegara
  -- a ser 3. No es un fallo de la transaccion: la transaccion ya estaba bien
  -- -- no quedaba nada a medias --, era el INDICE comprobando fila a fila un
  -- estado que solo es valido cuando el bucle termina.
  --
  -- La restriccion se declara `deferrable initially immediate` (ver arriba en
  -- esta misma migracion), asi que un insert suelto sigue rebotando al momento
  -- y solo se difiere aqui, donde hace falta.
  set constraints public.horses_race_id_numero_key deferred;

  select r.race_id into v_race_id from public.remates r where r.id = p_remate_id;
  if v_race_id is null then
    raise exception 'Remate no existe';
  end if;

  select * into v_race from public.races ra where ra.id = v_race_id;

  -- ------------------------------------------------------------------ bajas
  -- Solo lo que se pide, y solo si es de esta carrera. Ver la cabecera.
  for v_id in select (value #>> '{}')::uuid from jsonb_array_elements(coalesce(p_eliminados, '[]'::jsonb))
  loop
    select * into v_viejo from public.horses h where h.id = v_id and h.race_id = v_race_id;
    if found then
      delete from public.horses h where h.id = v_id;
      v_cambios := v_cambios || jsonb_build_object(
        'caballo_' || v_viejo.numero || '_baja',
        jsonb_build_object('antes', v_viejo.nombre, 'despues', '(eliminado)'));
      v_bajas := v_bajas + 1;
    end if;
  end loop;

  -- --------------------------------------------------------------- caballos
  for v_caballo in select value from jsonb_array_elements(p_caballos)
  loop
    v_id := (nullif(v_caballo->>'id', ''))::uuid;

    if v_id is null then
      -- ALTA
      insert into public.horses (
        race_id, numero, nombre, jinete, comentarios, precio_salida, retirado
      )
      values (
        v_race_id,
        (v_caballo->>'numero')::integer,
        v_caballo->>'nombre',
        nullif(v_caballo->>'jinete', ''),
        nullif(v_caballo->>'comentarios', ''),
        (v_caballo->>'precio_salida')::numeric,
        coalesce((v_caballo->>'retirado')::boolean, false)
      )
      returning horses.id into v_horse;

      v_cambios := v_cambios || jsonb_build_object(
        'caballo_' || (v_caballo->>'numero') || '_alta',
        jsonb_build_object(
          'antes', '(no existía)',
          'despues', (v_caballo->>'nombre') || ', salida ' ||
                     replace(trim(to_char((v_caballo->>'precio_salida')::numeric,'FM999999990.00')), '.', ',')));
      v_altas := v_altas + 1;
    else
      -- CAMBIO. Se lee el estado anterior ANTES de escribir, que es lo unico
      -- que permite decir "de X a Y" en vez de "se guardo algo".
      select * into v_viejo from public.horses h where h.id = v_id and h.race_id = v_race_id;
      if not found then
        raise exception 'Ese caballo no es de esta carrera';
      end if;
      v_horse := v_id;

      if v_viejo.numero is distinct from (v_caballo->>'numero')::integer then
        v_cambios := v_cambios || jsonb_build_object('caballo_' || v_viejo.numero || '_numero',
          jsonb_build_object('antes', v_viejo.numero, 'despues', (v_caballo->>'numero')::integer));
      end if;
      if v_viejo.nombre is distinct from (v_caballo->>'nombre') then
        v_cambios := v_cambios || jsonb_build_object('caballo_' || v_viejo.numero || '_nombre',
          jsonb_build_object('antes', v_viejo.nombre, 'despues', v_caballo->>'nombre'));
      end if;
      if v_viejo.jinete is distinct from nullif(v_caballo->>'jinete', '') then
        v_cambios := v_cambios || jsonb_build_object('caballo_' || v_viejo.numero || '_jinete',
          jsonb_build_object('antes', coalesce(v_viejo.jinete,'(vacío)'),
                             'despues', coalesce(nullif(v_caballo->>'jinete',''),'(vacío)')));
      end if;
      if v_viejo.precio_salida is distinct from (v_caballo->>'precio_salida')::numeric then
        v_cambios := v_cambios || jsonb_build_object('caballo_' || v_viejo.numero || '_precio_salida',
          jsonb_build_object(
            'antes', replace(trim(to_char(v_viejo.precio_salida,'FM999999990.00')), '.', ','),
            'despues', replace(trim(to_char((v_caballo->>'precio_salida')::numeric,'FM999999990.00')), '.', ',')));
      end if;
      if coalesce(v_viejo.retirado,false) is distinct from coalesce((v_caballo->>'retirado')::boolean,false) then
        v_cambios := v_cambios || jsonb_build_object('caballo_' || v_viejo.numero || '_retirado',
          jsonb_build_object('antes', coalesce(v_viejo.retirado,false),
                             'despues', coalesce((v_caballo->>'retirado')::boolean,false)));
      end if;
      if v_viejo.comentarios is distinct from nullif(v_caballo->>'comentarios', '') then
        v_cambios := v_cambios || jsonb_build_object('caballo_' || v_viejo.numero || '_comentarios',
          jsonb_build_object('antes', coalesce(v_viejo.comentarios,'(vacío)'),
                             'despues', coalesce(nullif(v_caballo->>'comentarios',''),'(vacío)')));
      end if;

      update public.horses h
         set numero        = (v_caballo->>'numero')::integer,
             nombre        = v_caballo->>'nombre',
             jinete        = nullif(v_caballo->>'jinete', ''),
             comentarios   = nullif(v_caballo->>'comentarios', ''),
             precio_salida = (v_caballo->>'precio_salida')::numeric,
             retirado      = coalesce((v_caballo->>'retirado')::boolean, false)
       where h.id = v_id;

      v_tocados := v_tocados + 1;
    end if;

    -- La escalera del caballo se aplana con su id ya resuelto, para
    -- `guardar_escaleras`. Un caballo recien creado trae la suya sin que el
    -- frontend haya tenido que recuperar su id.
    if jsonb_typeof(v_caballo->'reglas') = 'array' then
      for v_regla in select value from jsonb_array_elements(v_caballo->'reglas')
      loop
        v_escaleras := v_escaleras || jsonb_build_array(
          jsonb_build_object(
            'horse_id',   v_horse,
            'min_precio', v_regla->>'min_precio',
            'max_precio', v_regla->>'max_precio',
            'incremento', v_regla->>'incremento'));
      end loop;
    end if;
  end loop;

  -- SE COMPRUEBA AQUI, Y NO AL CONFIRMAR LA TRANSACCION.
  --
  -- `set constraints ... immediate` obliga a PostgreSQL a comprobar ahora lo
  -- que quedo pendiente. La documentacion lo dice literal: "any outstanding
  -- data modifications that would have been checked at the end of the
  -- transaction are instead checked during the execution of the SET
  -- CONSTRAINTS command. If any such constraint is violated, the SET
  -- CONSTRAINTS fails".
  --
  -- Y hace falta que falle AQUI DENTRO, no al confirmar: si la comprobacion se
  -- quedara para el commit, el 23505 saldria FUERA de esta funcion y el admin
  -- veria un `duplicate key value violates unique constraint` en crudo. Este
  -- bloque lo traduce. Quien rechaza sigue siendo el indice; esto es
  -- presentacion del error, no una regla (mismo criterio que ADR-036).
  begin
    set constraints public.horses_race_id_numero_key immediate;
  exception
    when unique_violation then
      raise exception 'Hay dos caballos con el mismo numero en esta carrera. Cada caballo necesita un numero distinto.'
        using errcode = '23505';
  end;

  -- ---------------------------------------------------------------- carrera
  v_nombre     := p_carrera->>'nombre';
  v_hipodromo  := nullif(p_carrera->>'hipodromo', '');
  v_ncarrera   := (nullif(p_carrera->>'numero_carrera', ''))::integer;
  v_ncarrera_t := nullif(p_carrera->>'numero_carrera_text', '');
  v_fecha      := (p_carrera->>'fecha')::date;
  v_hora       := (nullif(p_carrera->>'hora_programada', ''))::time;
  v_dia        := nullif(p_carrera->>'dia', '');
  v_distancia  := (nullif(p_carrera->>'distancia_m', ''))::numeric;
  v_estado     := coalesce(nullif(p_carrera->>'estado', ''), v_race.estado::text);

  if v_race.nombre is distinct from v_nombre then
    v_cambios := v_cambios || jsonb_build_object('carrera_nombre',
      jsonb_build_object('antes', v_race.nombre, 'despues', v_nombre));
  end if;
  if v_race.hipodromo is distinct from v_hipodromo then
    v_cambios := v_cambios || jsonb_build_object('carrera_hipodromo',
      jsonb_build_object('antes', coalesce(v_race.hipodromo,'(vacío)'), 'despues', coalesce(v_hipodromo,'(vacío)')));
  end if;
  if v_race.numero_carrera_text is distinct from v_ncarrera_t then
    v_cambios := v_cambios || jsonb_build_object('carrera_numero',
      jsonb_build_object('antes', coalesce(v_race.numero_carrera_text,'(vacío)'), 'despues', coalesce(v_ncarrera_t,'(vacío)')));
  end if;
  if v_race.fecha is distinct from v_fecha then
    v_cambios := v_cambios || jsonb_build_object('carrera_fecha',
      jsonb_build_object('antes', v_race.fecha::text, 'despues', v_fecha::text));
  end if;
  if v_race.hora_programada is distinct from v_hora then
    v_cambios := v_cambios || jsonb_build_object('carrera_hora',
      jsonb_build_object('antes', coalesce(v_race.hora_programada::text,'(vacío)'), 'despues', coalesce(v_hora::text,'(vacío)')));
  end if;
  if v_race.dia is distinct from v_dia then
    v_cambios := v_cambios || jsonb_build_object('carrera_dia',
      jsonb_build_object('antes', coalesce(v_race.dia,'(vacío)'), 'despues', coalesce(v_dia,'(vacío)')));
  end if;
  if v_race.distancia_m is distinct from v_distancia then
    v_cambios := v_cambios || jsonb_build_object('carrera_distancia_m',
      jsonb_build_object('antes', coalesce(v_race.distancia_m::text,'(vacío)'), 'despues', coalesce(v_distancia::text,'(vacío)')));
  end if;

  update public.races ra
     set nombre              = v_nombre,
         hipodromo           = v_hipodromo,
         numero_carrera      = v_ncarrera,
         numero_carrera_text = v_ncarrera_t,
         fecha               = v_fecha,
         hora_programada     = v_hora,
         dia                 = v_dia,
         distancia_m         = v_distancia,
         estado              = v_estado::public.race_status
   where ra.id = v_race_id;

  -- ------------------------------------------------- lo que ya estaba hecho
  -- Se DELEGA. Las dos dejan su propio asiento, y solo si hubo cambio.
  perform public.editar_remate(
    p_remate_id,
    (nullif(p_remate->>'porcentaje_casa', ''))::numeric,
    (nullif(p_remate->>'incremento_minimo', ''))::numeric,
    nullif(p_remate->>'tipo', ''),
    (nullif(p_remate->>'opens_at', ''))::timestamptz,
    (nullif(p_remate->>'closes_at', ''))::timestamptz,
    coalesce((p_remate->>'limpiar_opens_at')::boolean, false),
    coalesce((p_remate->>'limpiar_closes_at')::boolean, false));

  perform public.guardar_escaleras(p_remate_id, v_escaleras);

  -- --------------------------------------------------------------- bitacora
  -- Solo lo de ESTA funcion -- carrera y caballos --, y solo si cambio algo.
  if v_cambios <> '{}'::jsonb then
    perform public.log_admin_action(
      v_admin_id,
      'guardar_remate_completo',
      'remates',
      p_remate_id::text,
      v_cambios || jsonb_build_object('remate_id', p_remate_id));
  end if;

  return jsonb_build_object(
    'altas', v_altas, 'bajas', v_bajas, 'caballos_tocados', v_tocados,
    'tramos', jsonb_array_length(v_escaleras),
    'hubo_cambios_de_catalogo', v_cambios <> '{}'::jsonb);
end
$fn$;

comment on function public.guardar_remate_completo(uuid, jsonb, jsonb, jsonb, jsonb) is
  'Guarda la edicion entera de un remate -- carrera, caballos, escaleras y campos del remate -- en UNA transaccion, y deja asiento de cada cosa que cambio (08/10/2026). Desde el 10/10 difiere la unica de (race_id, numero) para que se puedan intercambiar dos numeros.';

-- Los permisos NO cambian: la firma es la misma y `create or replace` los
-- conserva. Se repiten igualmente, porque una funcion que se toca y se deja
-- sin declarar es como P47 se pone en rojo (ADR-016).
revoke all on function public.guardar_remate_completo(uuid, jsonb, jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.guardar_remate_completo(uuid, jsonb, jsonb, jsonb, jsonb)
  to authenticated;
