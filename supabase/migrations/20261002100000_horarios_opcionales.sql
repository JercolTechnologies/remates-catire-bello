-- ===========================================================================
--  20261002100000_horarios_opcionales.sql
--
--  LO QUE PIDIO JOTA
--  "lo de hora de apertura del remate hay que dejarlo tambien opcional, que lo
--   programen si quieren y si lo dejan vacio el remate queda activo apenas se
--   cree, listo."
--
--  LO QUE YA ESTABA BIEN Y NO SE TOCA
--  La base nunca exigio la apertura. `hacer_puja` la compara con guarda de nulo
--  (`if v_remate.opens_at is not null and now() < v_remate.opens_at`), la
--  pantalla publica hace lo mismo (`opensOk`), y el cierre automatico solo mira
--  los remates que tienen closes_at. Un remate con opens_at nulo ya estaba
--  activo desde su creacion. Dejar la apertura vacia en el formulario de CREAR
--  es por eso cambio de FRONTEND unicamente y no necesita esta migracion.
--
--  EL DEFECTO QUE SI ES DE LA BASE, Y QUE SALIO BUSCANDO LO ANTERIOR
--  `editar_remate` decide si toca el campo con `p_opens_at is not null`. Con ese
--  contrato NULL significa "no lo cambies", asi que una vez que un remate tiene
--  horario NO HAY MANERA DE QUITARSELO desde la aplicacion:
--
--    - El admin borra la hora de cierre, guarda, no sale ningun error, y el
--      cierre sigue ahi. En silencio, que es el peor resultado posible.
--    - Un remate creado sin apertura (ya posible) no se podia editar sin que la
--      pantalla le exigiera inventarle una.
--
--  No fue un descuido del 28/09: con parametros opcionales y un solo centinela,
--  "sin valor" y "quitar el valor" son la misma cosa. La unica salida es
--  decirlo con otro parametro.
--
--  LA FORMA: una bandera explicita por campo.
--    p_opens_at = null  y  p_limpiar_opens_at = false   ->  no se toca
--    p_opens_at = valor                                 ->  se pone ese valor
--    p_limpiar_opens_at = true                          ->  queda en NULL
--  Si llegan las dos a la vez es un error del cliente y se rechaza, en vez de
--  adivinar cual gana.
--
--  POR QUE HAY QUE HACER DROP ANTES DEL CREATE
--  PostgREST resuelve las RPC por NOMBRE DE ARGUMENTO. Si se anaden dos
--  parametros con default sin borrar la firma vieja quedan dos funciones
--  `editar_remate` y la llamada de seis argumentos se vuelve ambigua
--  (PGRST203). Es la misma piedra de rechazar_recarga y procesar_retiro el
--  01/10, y `create or replace` no la evita porque no borra la firma anterior.
--
--  EL CUERPO DE LA FUNCION NO SE RETECLEO: se genero a partir del archivo
--  20260928110000 cambiando solo la firma, la guarda nueva y el bloque de
--  horarios. El candado pg_advisory_xact_lock(2, ...), la guarda de estado y
--  los dos avisos quedan exactamente como estaban.
-- ===========================================================================

drop function if exists public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz);

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

  perform public.log_admin_action(
    v_admin_id, 'editar_remate', 'remates', p_remate_id::text,
    v_cambios, true, null);

  return v_rem;
end;
$fn$;

comment on function public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz, boolean, boolean) is
  'Edita un remate abierto. Los horarios tienen tres caminos: null = no tocar, valor = poner ese valor, bandera p_limpiar_* = dejar en NULL. Sin apertura el remate esta activo desde que se crea; sin cierre se cierra a mano.';

-- Mismo inventario de permisos que tenia la firma vieja (ver 20260929110000:
-- una funcion security definer sin revoke a anon es una puerta abierta). La
-- firma vieja desaparecio con el drop, asi que estos dos van obligatoriamente.
revoke all on function public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz, boolean, boolean) from public, anon;
grant execute on function public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz, boolean, boolean) to authenticated;
