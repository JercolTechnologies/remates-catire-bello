-- ===========================================================================
--  20261007170000_registro_honesto.sql
--
--  LA BITACORA DEJA DE ANUNCIAR LO QUE NO PASO, Y DICE QUE PASO CUANDO PASA
--
--  LO QUE JOTA VIO EN /admin/log, Y TENIA RAZON
--
--    1:11:31  Guardar escaleras   Tramos ahora: 0 | Tramos antes: 0
--    1:11:31  Remate editado      Incremento: 50 -> 150
--    1:09:23  Guardar escaleras   Tramos ahora: 0 | Tramos antes: 5
--    1:09:22  Remate editado      (sin una sola etiqueta)
--
--  A las 1:11 cambio el incremento del remate y NO toco las escaleras, pero el
--  log dice que guardo escaleras. A las 1:09 cambio las escaleras y NO toco el
--  remate, pero el log dice que edito el remate. Las dos entradas sobran y las
--  dos mienten por omision.
--
--  LA CAUSA, QUE ES LA MISMA EN LAS DOS. La pantalla de editar llama a
--  `editar_remate` Y a `guardar_escaleras` en TODOS los guardados, toque el
--  admin lo que toque. Antes del 07/10 eso no se notaba porque las escaleras
--  se escribian directo y no dejaban asiento. Al darles auditoria, una llamada
--  inutil se convirtio en una entrada falsa.
--
--  Un registro lleno de acciones que no ocurrieron es PEOR que no tener
--  registro: el que lo lee aprende a no leerlo, y el dia que importe una
--  entrada la va a pasar por encima. Es el ADR-022 -- la alarma que saltaba
--  cuando no pasaba nada -- y el ADR-034 -- el aviso que se dispara de mas
--  devalua a los demas -- aplicados a la bitacora.
--
--  LA DECISION: el que decide si hubo cambio es la BASE, no la pantalla.
--  Podria arreglarse en el frontend, no llamando a la RPC si nada cambio. Seria
--  mas facil y seria el ADR-015 otra vez: la regla de "que cuenta como un
--  cambio" viviria en la pantalla, y la segunda pantalla que llame a esta RPC
--  tendria que acordarse de repetirla. La base compara y decide.
--
--  QUE DICE AHORA EL ASIENTO DE LAS ESCALERAS
--
--  Antes: "Tramos ahora: 0 | Tramos antes: 5". Dos numeros que no dicen a que
--  caballo le paso que.
--
--  Ahora, una linea por caballo que haya cambiado, y SOLO por los que hayan
--  cambiado:
--
--    Caballo 3: 2 tramos (sube 50,00, 100,00) -> 3 tramos (sube 25,00, 50,00, 100,00)
--    Caballo 5: sin escalera -> 2 tramos (sube 50,00, 150,00)
--    Caballo 7: 4 tramos (sube 10,00, 20,00, 50,00, 100,00) -> sin escalera
--
--  La forma {antes, despues} no es casual: es la que `resumirDetalles` de
--  /admin/log ya sabe pintar como "X -> Y". No hace falta tocar el frontend.
--
--  POR QUE NO DICE "CAMBIO DE SUAVE A AGRESIVA", que era lo que Jota pidio
--
--  Porque la base no sabe que existe "suave". El ritmo vive en
--  `lib/escalera.ts` y es un GENERADOR: produce los tramos y desaparece.
--  Comprobado -- la palabra `ritmo` no aparece en ninguna migracion. Guardar
--  la etiqueta ademas de los tramos seria tener dos fuentes para el mismo
--  hecho, y la etiqueta empezaria a mentir en cuanto alguien editara un tramo
--  a mano (ADR-015). Asi que el asiento describe los tramos de verdad, que es
--  lo que si se puede afirmar siempre.
--
--  LO QUE SIGUE SIN REGISTRARSE, y no se arregla aqui: los cambios de un
--  CABALLO -- nombre, jinete, precio de salida, retirado, altas y bajas -- son
--  UPDATE directos desde el navegador. No hay trigger ni linea que escriba
--  `admin_actions` por `horses`: cambiar el precio de salida de un caballo no
--  deja ningun rastro, y eso roza el dinero porque es lo que se lleva la casa
--  si nadie puja por el. Para registrarlo hace falta que esas escrituras pasen
--  por la base: `guardar_remate_completo`, decidido como la pieza siguiente.
--
--  `editar_remate` SE REGENERA ENTERA, extraida de 20261002100000 con un
--  script y parcheada en un solo sitio. No se retipea un cuerpo PL/pgSQL a
--  mano: el 02/10 hacerlo perdio un `pg_advisory_xact_lock` y se invento un
--  estado que no existe (ADR-021). Respecto al original cambia exactamente una
--  cosa: el `log_admin_action` del final queda dentro de un `if`.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  1) guardar_escaleras: no escribe ni anuncia si nada cambio
-- ---------------------------------------------------------------------------
create or replace function public.guardar_escaleras(
  p_remate_id uuid,
  p_reglas    jsonb
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_race_id  uuid;
  v_ajeno    uuid;
  v_regla    jsonb;

  v_firma_vieja text;
  v_firma_nueva text;
  v_cambios     jsonb;
  v_escritas    integer := 0;
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

  if p_reglas is null or jsonb_typeof(p_reglas) <> 'array' then
    raise exception 'Las escaleras tienen que venir en una lista';
  end if;

  -- Candado por remate: sin el, dos admins guardando a la vez mezclan las dos
  -- escaleras. Espacio 2 con la clave del remate, igual que editar_remate.
  perform pg_advisory_xact_lock(2, hashtext(p_remate_id::text));

  select r.race_id into v_race_id
  from public.remates r
  where r.id = p_remate_id;

  if v_race_id is null then
    raise exception 'Remate no existe';
  end if;

  -- UNA ESCALERA SOLO PUEDE SER DE UN CABALLO DE ESTA CARRERA.
  -- `horse_id` tiene clave foranea contra `horses`, pero nada la ataba al
  -- remate. Como esta funcion es LA puerta -- `authenticated` ya no puede
  -- escribir la tabla -- sin esto el agujero lo abriria yo.
  select (e.value->>'horse_id')::uuid into v_ajeno
  from jsonb_array_elements(p_reglas) e
  where not exists (
    select 1 from public.horses h
    where h.id = (e.value->>'horse_id')::uuid and h.race_id = v_race_id
  )
  limit 1;

  if v_ajeno is not null then
    raise exception 'Esa escalera no es de un caballo de esta carrera';
  end if;

  -- LA COMPARACION Y LA DESCRIPCION, EN UNA SOLA CONSULTA.
  --
  -- `firma` es la huella del conjunto de tramos de un caballo. Los montos van
  -- con dos decimales fijos a proposito: las columnas son numeric(12,2) pero
  -- el navegador manda 50, no 50.00, y comparar los textos en crudo diria que
  -- cambio algo que no cambio.
  with viejo as (
    select h.numero,
           count(*)::int as tramos,
           string_agg(replace(trim(to_char(r.incremento,'FM999999990.00')), '.', ','), ', '
                      order by r.min_precio, r.incremento) as subidas,
           string_agg(trim(to_char(r.min_precio,'FM999999990.00')) || '/' ||
                      coalesce(trim(to_char(r.max_precio,'FM999999990.00')), '*') || '/' ||
                      trim(to_char(r.incremento,'FM999999990.00')), ';'
                      order by r.min_precio, r.incremento) as firma
    from public.remate_price_rules r
    join public.horses h on h.id = r.horse_id
    where r.remate_id = p_remate_id
    group by h.numero
  ),
  entrada as (
    select h.numero,
           (e.value->>'min_precio')::numeric as min_precio,
           (nullif(e.value->>'max_precio',''))::numeric as max_precio,
           (e.value->>'incremento')::numeric as incremento
    from jsonb_array_elements(p_reglas) e
    join public.horses h on h.id = (e.value->>'horse_id')::uuid
  ),
  nuevo as (
    select en.numero,
           count(*)::int as tramos,
           string_agg(replace(trim(to_char(en.incremento,'FM999999990.00')), '.', ','), ', '
                      order by en.min_precio, en.incremento) as subidas,
           string_agg(trim(to_char(en.min_precio,'FM999999990.00')) || '/' ||
                      coalesce(trim(to_char(en.max_precio,'FM999999990.00')), '*') || '/' ||
                      trim(to_char(en.incremento,'FM999999990.00')), ';'
                      order by en.min_precio, en.incremento) as firma
    from entrada en
    group by en.numero
  ),
  cruce as (
    select coalesce(v.numero, n.numero) as numero,
           case when v.tramos is null then 'sin escalera'
                else v.tramos || case when v.tramos = 1 then ' tramo' else ' tramos' end
                     || ' (sube ' || v.subidas || ')' end as antes,
           case when n.tramos is null then 'sin escalera'
                else n.tramos || case when n.tramos = 1 then ' tramo' else ' tramos' end
                     || ' (sube ' || n.subidas || ')' end as despues,
           coalesce(v.firma, '') as f_v,
           coalesce(n.firma, '') as f_n
    from viejo v
    full outer join nuevo n on n.numero = v.numero
  )
  select
    coalesce(string_agg(c.numero || '=' || c.f_v, '|' order by c.numero), ''),
    coalesce(string_agg(c.numero || '=' || c.f_n, '|' order by c.numero), ''),
    coalesce(
      jsonb_object_agg('caballo_' || c.numero,
        jsonb_build_object('antes', c.antes, 'despues', c.despues))
        filter (where c.f_v is distinct from c.f_n),
      '{}'::jsonb)
    into v_firma_vieja, v_firma_nueva, v_cambios
  from cruce c;

  -- SI NADA CAMBIO, NADA SE ESCRIBE Y NADA SE ANUNCIA.
  -- Es el caso de las 1:11 de Jota: guardo el remate tocando solo el
  -- incremento, y esta funcion se llamo igual porque la pantalla la llama
  -- siempre. Antes dejaba "Tramos ahora: 0 | Tramos antes: 0".
  if v_firma_vieja = v_firma_nueva then
    select count(*)::int into v_escritas
    from public.remate_price_rules r
    where r.remate_id = p_remate_id;
    return v_escritas;
  end if;

  delete from public.remate_price_rules r
  where r.remate_id = p_remate_id;

  for v_regla in select value from jsonb_array_elements(p_reglas)
  loop
    insert into public.remate_price_rules (
      remate_id, horse_id, min_precio, max_precio, incremento
    )
    values (
      p_remate_id,
      (v_regla->>'horse_id')::uuid,
      (v_regla->>'min_precio')::numeric,
      (nullif(v_regla->>'max_precio', ''))::numeric,
      (v_regla->>'incremento')::numeric
    );
    v_escritas := v_escritas + 1;
  end loop;

  perform public.log_admin_action(
    v_admin_id,
    'guardar_escaleras',
    'remate_price_rules',
    p_remate_id::text,
    v_cambios || jsonb_build_object('remate_id', p_remate_id)
  );

  return v_escritas;
end
$fn$;

comment on function public.guardar_escaleras(uuid, jsonb) is
  'Reemplaza TODAS las escaleras de un remate en UNA transaccion. Si el conjunto no cambio no escribe ni deja asiento; si cambio, el asiento dice que le paso a cada caballo (07/10/2026).';

revoke all on function public.guardar_escaleras(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.guardar_escaleras(uuid, jsonb)
  to authenticated;


-- ---------------------------------------------------------------------------
--  2) editar_remate: no deja asiento si no cambio ningun campo
--
--  Cuerpo extraido de 20261002100000_horarios_opcionales.sql con un script y
--  parcheado en un solo sitio. Ver la cabecera.
-- ---------------------------------------------------------------------------
create or replace function public.editar_remate(
  p_remate_id         uuid,
  p_porcentaje_casa   numeric default null,
  p_incremento_minimo numeric default null,
  p_tipo              text    default null,
  p_opens_at          timestamptz default null,
  p_closes_at         timestamptz default null,
  p_limpiar_opens_at  boolean default false,
  p_limpiar_closes_at boolean default false
)
returns public.remates
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_rem      public.remates%rowtype;
  v_hay_pujas boolean;
  v_cambios  jsonb := '{}'::jsonb;
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select (coalesce(es_admin,false) or coalesce(es_super_admin,false))
    into v_is_admin
  from public.profiles where id = v_admin_id;

  if coalesce(v_is_admin,false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  -- Ordenes contradictorias: no se adivina cual gana, se rechaza.
  if p_opens_at is not null and coalesce(p_limpiar_opens_at,false) then
    raise exception 'No se puede poner y quitar la hora de apertura en la misma llamada';
  end if;
  if p_closes_at is not null and coalesce(p_limpiar_closes_at,false) then
    raise exception 'No se puede poner y quitar la hora de cierre en la misma llamada';
  end if;

  perform pg_advisory_xact_lock(2, hashtext(p_remate_id::text));

  select * into v_rem from public.remates where id = p_remate_id for update;
  if not found then
    raise exception 'El remate no existe';
  end if;

  if v_rem.estado <> 'abierto' then
    raise exception 'El remate esta %. Solo se puede editar un remate abierto.', v_rem.estado;
  end if;

  select exists (select 1 from public.bids where remate_id = p_remate_id) into v_hay_pujas;

  -- ---------------- porcentaje de la casa ----------------
  if p_porcentaje_casa is not null and p_porcentaje_casa <> v_rem.porcentaje_casa then
    if v_hay_pujas then
      raise exception 'No se puede cambiar el porcentaje de la casa: el remate ya tiene pujas. La gente pujo sabiendo cual era el reparto.';
    end if;
    if p_porcentaje_casa < 0 or p_porcentaje_casa > 100 then
      raise exception 'El porcentaje de la casa va entre 0 y 100';
    end if;

    insert into public.remate_avisos (remate_id, tipo, mensaje, detalles, created_by)
    values (p_remate_id, 'porcentaje_casa',
      'La comision de la casa paso de ' || trim(to_char(v_rem.porcentaje_casa,'FM999990.00')) ||
      '% a ' || trim(to_char(p_porcentaje_casa,'FM999990.00')) || '%.',
      jsonb_build_object('antes', v_rem.porcentaje_casa, 'despues', p_porcentaje_casa,
                         'habia_pujas', v_hay_pujas),
      v_admin_id);

    v_cambios := v_cambios || jsonb_build_object('porcentaje_casa',
      jsonb_build_object('antes', v_rem.porcentaje_casa, 'despues', p_porcentaje_casa));
    v_rem.porcentaje_casa := p_porcentaje_casa;
  end if;

  -- ---------------- incremento de respaldo ----------------
  -- CAMBIO DEL 28/09: el aviso sale SIEMPRE, no solo si hay pujas. Un remate
  -- abierto es un remate que la gente esta mirando.
  if p_incremento_minimo is not null and p_incremento_minimo <> v_rem.incremento_minimo then
    if p_incremento_minimo <= 0 then
      raise exception 'El incremento tiene que ser mayor que cero';
    end if;

    insert into public.remate_avisos (remate_id, tipo, mensaje, detalles, created_by)
    values (p_remate_id, 'incremento',
      'El incremento fijo paso de ' || trim(to_char(v_rem.incremento_minimo,'FM999990.00')) ||
      ' a ' || trim(to_char(p_incremento_minimo,'FM999990.00')) || ' Bs.',
      jsonb_build_object('antes', v_rem.incremento_minimo, 'despues', p_incremento_minimo,
                         'habia_pujas', v_hay_pujas),
      v_admin_id);

    v_cambios := v_cambios || jsonb_build_object('incremento_minimo',
      jsonb_build_object('antes', v_rem.incremento_minimo, 'despues', p_incremento_minimo));
    v_rem.incremento_minimo := p_incremento_minimo;
  end if;

  -- ---------------- tipo ----------------
  if p_tipo is not null and p_tipo <> coalesce(v_rem.tipo,'vivo') then
    if v_hay_pujas then
      raise exception 'No se puede cambiar el tipo de remate: ya tiene pujas.';
    end if;
    if p_tipo not in ('vivo','adelantado') then
      raise exception 'Tipo no valido. Es vivo o adelantado.';
    end if;
    v_cambios := v_cambios || jsonb_build_object('tipo',
      jsonb_build_object('antes', v_rem.tipo, 'despues', p_tipo));
    v_rem.tipo := p_tipo;
  end if;

  -- ---------------- horarios ----------------
  -- Tres caminos por campo. El de limpiar es lo nuevo de esta migracion; el
  -- aviso al jugador no se toca aqui a proposito: este archivo arregla el
  -- contrato de la funcion, no cambia quien se entera de que.
  if coalesce(p_limpiar_opens_at,false) then
    if v_rem.opens_at is not null then
      v_cambios := v_cambios || jsonb_build_object('opens_at',
        jsonb_build_object('antes', v_rem.opens_at, 'despues', null));
    end if;
    v_rem.opens_at := null;
  elsif p_opens_at is not null then
    v_cambios := v_cambios || jsonb_build_object('opens_at',
      jsonb_build_object('antes', v_rem.opens_at, 'despues', p_opens_at));
    v_rem.opens_at := p_opens_at;
  end if;

  if coalesce(p_limpiar_closes_at,false) then
    if v_rem.closes_at is not null then
      v_cambios := v_cambios || jsonb_build_object('closes_at',
        jsonb_build_object('antes', v_rem.closes_at, 'despues', null));
    end if;
    v_rem.closes_at := null;
  elsif p_closes_at is not null then
    v_cambios := v_cambios || jsonb_build_object('closes_at',
      jsonb_build_object('antes', v_rem.closes_at, 'despues', p_closes_at));
    v_rem.closes_at := p_closes_at;
  end if;

  if v_rem.opens_at is not null and v_rem.closes_at is not null
     and v_rem.closes_at <= v_rem.opens_at then
    raise exception 'La hora de cierre tiene que ser posterior a la de apertura';
  end if;

  update public.remates
     set porcentaje_casa   = v_rem.porcentaje_casa,
         incremento_minimo = v_rem.incremento_minimo,
         tipo              = v_rem.tipo,
         opens_at          = v_rem.opens_at,
         closes_at         = v_rem.closes_at
   where id = p_remate_id
  returning * into v_rem;

  -- UN ASIENTO VACIO NO ES UN ASIENTO. (07/10/2026)
  --
  -- Hasta hoy esto se ejecutaba SIEMPRE, aunque `v_cambios` fuera '{}'. La
  -- pantalla de editar llama a esta RPC en cada guardado, toques o no los
  -- campos del remate, asi que cambiar solo una escalera dejaba un "Remate
  -- editado" sin una sola etiqueta. Jota lo vio en /admin/log y tenia razon.
  --
  -- Un registro lleno de acciones que no ocurrieron es peor que no tener
  -- registro: el que lo lee aprende a no leerlo. Es el ADR-022 -- la alarma
  -- que salta cuando no pasa nada -- aplicado a la bitacora.
  --
  -- El UPDATE de arriba se sigue haciendo aunque no cambie nada, y esta bien:
  -- escribir los mismos valores no tiene coste y evita una segunda rama. Lo
  -- que no se hace es ANUNCIARLO.
  if v_cambios <> '{}'::jsonb then
    perform public.log_admin_action(
      v_admin_id, 'editar_remate', 'remates', p_remate_id::text,
      v_cambios, true, null);
  end if;

  return v_rem;
end;
$fn$;
revoke all on function public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz, boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz, boolean, boolean)
  to authenticated;
