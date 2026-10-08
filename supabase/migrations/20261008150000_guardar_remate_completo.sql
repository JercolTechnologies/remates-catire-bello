-- ===========================================================================
--  20261008150000_guardar_remate_completo.sql
--
--  GUARDAR UN REMATE EDITADO ES UNA TRANSACCION, Y CADA CAMBIO DEJA ASIENTO
--
--  EL PROBLEMA, MEDIDO (07/10/2026)
--
--  El guardado de `app/admin/remates/[id]/page.tsx` eran 16 o 17 llamadas
--  sueltas para una carrera de 12 caballos: `races` (1) + `editar_remate` (1) +
--  borrado de caballos (1) + UN UPDATE O INSERT POR CABALLO (12) +
--  `guardar_escaleras` (1). Cada una su propia transaccion ya confirmada.
--
--  Dos consecuencias, y la segunda es la que pidio Jota:
--
--    1. Un fallo a mitad del bucle deja la carrera medio aplicada: unos
--       caballos con los datos nuevos y otros con los viejos, y la pantalla
--       diciendo "Error guardando cambios" como si no hubiera pasado nada.
--
--    2. LOS CAMBIOS DE UN CABALLO NO DEJABAN NINGUN RASTRO. Nombre, jinete,
--       precio de salida, retirado, altas y bajas eran UPDATE directos desde
--       el navegador: no hay trigger ni linea que escriba `admin_actions` por
--       `horses`. Cambiar el precio de salida de un caballo era invisible, y
--       eso roza el dinero: es lo que se lleva la casa si nadie puja por el.
--
--  Jota, el 07/10 mirando /admin/log: "deberia decir que editaron el
--  incremento de tanto a tanto y asi con cada accion que se edite, el cambio
--  de nombre de un caballo y cualquier otra cosa que se pueda editar en un
--  remate ya creado."
--
--  LA FORMA: ESTA FUNCION DELEGA, NO REIMPLEMENTA
--
--  `editar_remate` y `guardar_escaleras` ya existen, ya estan probadas y ya
--  dejan su propio asiento solo cuando hay cambio (ADR-038). Esta funcion NO
--  copia su logica: las llama. Una funcion PL/pgSQL que llama a otra sigue en
--  la MISMA transaccion, asi que el todo es atomico igual, y no hay una
--  segunda implementacion de la regla del incremento ni de la de las
--  escaleras. Copiarlas habria sido el ADR-015 dentro de la propia base.
--
--  Lo que esta funcion hace por su cuenta es lo que nadie hacia: `races` y
--  `horses`, con su auditoria.
--
--  EL CANDADO SE TOMA TRES VECES Y NO PASA NADA. `pg_advisory_xact_lock`
--  cuenta re-entradas dentro de la misma transaccion, asi que tomarlo aqui y
--  otra vez dentro de `editar_remate` y de `guardar_escaleras` no se traba.
--
--  LAS BAJAS SE PIDEN, NO SE DEDUCEN. Seria mas comodo borrar todo caballo que
--  no venga en la lista, y seria una bomba: un fallo del frontend que mandara
--  la lista a medias borraria caballos con pujas. Se borra EXACTAMENTE lo que
--  venga en `p_eliminados`, y solo si es de esta carrera.
--
--  QUE DICE EL ASIENTO. Una clave por cosa que cambio, con la forma
--  {antes, despues} que /admin/log ya sabe pintar:
--
--    Carrera hipodromo: La Rinconada -> Valencia
--    Caballo 3 nombre: Relampago -> Trueno
--    Caballo 3 precio salida: 100,00 -> 150,00
--    Caballo 7 alta: (no existia) -> Centella, salida 120,00
--    Caballo 5 baja: Trueno -> (eliminado)
--
--  Si no cambio nada, no hay asiento. ADR-038.
--
--  LO QUE NO ARREGLA, y conviene saberlo: siguen sin poder intercambiarse los
--  numeros de dos caballos. `horses_race_id_numero_key` no es diferible, asi
--  que pasar el 3 a 5 cuando ya hay un 5 rebota con 23505. La diferencia es
--  que ahora rebota SIN dejar nada a medias. Arreglarlo de verdad es
--  renumerar en dos fases o declarar la restriccion diferible: decision
--  aparte (pendiente 1.2).
--
--  FORMA DEL PAYLOAD
--
--    p_carrera    = { nombre, hipodromo, numero_carrera, numero_carrera_text,
--                     fecha, hora_programada, dia, distancia_m, estado }
--    p_remate     = { porcentaje_casa, incremento_minimo, tipo, opens_at,
--                     closes_at, limpiar_opens_at, limpiar_closes_at }
--    p_caballos   = [ { id|null, numero, nombre, jinete, comentarios,
--                       precio_salida, retirado,
--                       reglas: [ { min_precio, max_precio, incremento } ] } ]
--    p_eliminados = [ "uuid", ... ]
--
--  Las escaleras viajan COLGANDO de su caballo, igual que en
--  `crear_remate_completo`: asi un caballo que se acaba de crear puede traer
--  la suya sin que el frontend tenga que recuperar su id primero.
-- ===========================================================================

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
  'Guarda la edicion entera de un remate -- carrera, caballos, escaleras y campos del remate -- en UNA transaccion, y deja asiento de cada cosa que cambio (08/10/2026).';

revoke all on function public.guardar_remate_completo(uuid, jsonb, jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.guardar_remate_completo(uuid, jsonb, jsonb, jsonb, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------------
--  Y SE CIERRAN LAS DOS PUERTAS QUE QUEDABAN DEL CATALOGO DEL REMATE.
--
--  `races` y `horses` tenian insert, update y delete para `authenticated`
--  porque la pantalla de admin los usaba. Ya no: crear pasa por
--  `crear_remate_completo` y editar por `guardar_remate_completo`, las dos
--  SECURITY DEFINER. Comprobado recorriendo `app/` y `lib/` el 08/10.
--
--  `support_settings` NO entra aqui, aunque P48 la agrupaba con estas. La
--  escribe `/admin/super/soporte`, que es otra pantalla y otro problema.
--
--  `select` se conserva para los dos roles: las pantallas publicas leen la
--  carrera y los caballos.
-- ---------------------------------------------------------------------------
revoke insert, update, delete, truncate on public.races  from authenticated, anon;
revoke insert, update, delete, truncate on public.horses from authenticated, anon;
grant select on public.races  to authenticated, anon;
grant select on public.horses to authenticated, anon;
