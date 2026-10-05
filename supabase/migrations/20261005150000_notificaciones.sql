-- ===========================================================================
--  20261005150000_notificaciones.sql
--
--  QUE AL GANADOR LE LLEGUE, ESTE DONDE ESTE
--
--  Lo pidio Jota el 02/10 liquidando un remate: "aqui tiene que salir un popup
--  avisando al ganador, tanto si esta en linea como si no estaba e inicio
--  sesion". Esas dos mitades son las que mandan el diseno:
--
--   - "si esta en linea"  -> hace falta una senal en tiempo real
--   - "si inicio sesion"  -> hace falta que el aviso PERSISTA y sepa si ya se
--                            leyo
--
--  La segunda mitad es la que decide. Un toast que se emite y se pierde no
--  sirve: el ganador puede estar durmiendo cuando se liquida el remate. Hace
--  falta una tabla con estado de leida.
--
--  POR QUE UNA TABLA GENERAL Y NO UN AVISO DE PREMIO
--  Porque la lista de pendientes ya tiene cuatro avisos mas esperando -- recarga
--  aprobada, recarga rechazada con su motivo, retiro procesado, remate nuevo --
--  y todos tienen exactamente esta forma: un usuario, un texto, una referencia,
--  y si ya lo vio o no. Construir el popup del premio a medida y rehacerlo como
--  notificaciones dentro de dos semanas es trabajo tirado dos veces. Anadir cada
--  uno de los otros es ahora una linea.
--
--  LO QUE NO ES: un canal de mensajes. No hay respuesta, no hay conversacion, y
--  el emisor es siempre el sistema. `_notificar` es `security definer` y no esta
--  expuesta a nadie: ninguna pantalla puede escribirle una notificacion a otro
--  usuario.
--
--  UN AVISO PERDIDO NO PUEDE TUMBAR UNA LIQUIDACION. `_notificar` se traga sus
--  propios errores, igual que `_avisar` (ADR-025). Y se puede permitir: el
--  premio ya esta en el saldo y en `wallet_movements` antes de que esto corra.
--  El registro de verdad es ese; esto es la cortesia de avisar.
-- ===========================================================================

create table if not exists public.notificaciones (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  tipo        text not null check (tipo in ('premio','recarga','retiro','remate','aviso')),
  titulo      text not null,
  mensaje     text not null,
  ref_externa text,
  monto       numeric(12,2),
  leida_at    timestamptz,
  created_at  timestamptz not null default now()
);

comment on table public.notificaciones is
  'Avisos persistentes para un usuario, con estado de leida. Los escribe el sistema via _notificar(); nadie los escribe desde una pantalla.';

-- El indice que importa: "lo que este usuario no ha leido todavia", que es la
-- consulta que hace la aplicacion en cada carga.
create index if not exists idx_notificaciones_sin_leer
  on public.notificaciones (user_id, created_at desc)
  where leida_at is null;

alter table public.notificaciones enable row level security;

-- Cada quien ve lo suyo y nada mas. Ni siquiera un admin ve los avisos de otro:
-- no los necesita para operar, y el registro de dinero ya esta en /admin/log.
drop policy if exists notificaciones_lee_lo_suyo on public.notificaciones;
create policy notificaciones_lee_lo_suyo on public.notificaciones
  for select to authenticated
  using (user_id = auth.uid());

-- SELECT y nada mas. Marcar como leida va por RPC, no por UPDATE directo: asi
-- nadie puede reescribir el texto de un aviso que recibio.
revoke all on table public.notificaciones from public, anon, authenticated;
grant select on table public.notificaciones to authenticated;

-- ---------------------------------------------------------------------------
--  El canal privado de cada usuario
--
--  `usuario:<su uuid>`. La politica compara el topico contra auth.uid(), asi
--  que no hace falta confiar en el cliente: puede pedir suscribirse al canal de
--  otro, y la base no le entrega nada.
-- ---------------------------------------------------------------------------
do $$
begin
  drop policy if exists usuario_recibe_lo_suyo on realtime.messages;

  create policy usuario_recibe_lo_suyo on realtime.messages
    for select to authenticated
    using (
      realtime.messages.extension = 'broadcast'
      and realtime.topic() = 'usuario:' || auth.uid()::text
    );
exception when insufficient_privilege then
  raise exception
    'No se pueden crear politicas sobre realtime.messages con el rol %. Sin ella los avisos se guardan pero no llegan en vivo. Crea la politica a mano desde el SQL Editor con el contenido de este archivo.', current_user;
end $$;

-- ---------------------------------------------------------------------------
--  El emisor unico
-- ---------------------------------------------------------------------------
create or replace function public._notificar(
  p_user_id uuid, p_tipo text, p_titulo text, p_mensaje text,
  p_ref text default null, p_monto numeric default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_id uuid;
begin
  if p_user_id is null then
    return;
  end if;

  insert into public.notificaciones (user_id, tipo, titulo, mensaje, ref_externa, monto)
  values (p_user_id, p_tipo, p_titulo, p_mensaje, p_ref, p_monto)
  returning id into v_id;

  -- La senal NO lleva el texto: dice "tienes algo nuevo" y la pantalla vuelve a
  -- preguntar. Es el ADR-015 otra vez -- si el evento trajera el mensaje, habria
  -- dos sitios donde vive el mismo texto.
  perform public._avisar(
    'usuario:' || p_user_id::text,
    'aviso',
    jsonb_build_object('id', v_id, 'tipo', p_tipo));
exception when others then
  raise warning 'no se pudo notificar a % (%): %', p_user_id, p_tipo, sqlerrm;
end;
$fn$;

comment on function public._notificar(uuid, text, text, text, text, numeric) is
  'Emisor unico de avisos a un usuario: guarda la fila y emite la senal. Nunca propaga errores -- un aviso perdido no puede tumbar una operacion de dinero.';

revoke all on function public._notificar(uuid, text, text, text, text, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
--  Marcar como leida
--
--  Solo las propias, y solo las que siguen sin leer: volver a marcar una ya
--  leida moveria su fecha y perderiamos cuando se vio de verdad.
-- ---------------------------------------------------------------------------
create or replace function public.marcar_aviso_leido(p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_yo uuid := auth.uid();
begin
  if v_yo is null then
    raise exception 'No autenticado';
  end if;

  update public.notificaciones
     set leida_at = now()
   where id = p_id
     and user_id = v_yo
     and leida_at is null;
end;
$fn$;

revoke all on function public.marcar_aviso_leido(uuid) from public, anon;
grant execute on function public.marcar_aviso_leido(uuid) to authenticated;


-- ---------------------------------------------------------------------------
--  liquidar_remate, con el aviso al ganador
--
--  EL CUERPO NO SE RETECLEO: se extrajo de 20260929100000 y se le inserto una
--  sola llamada, pegada a la acreditacion del premio. Es la leccion del
--  ADR-021 -- reescribir a mano un cuerpo que ya funciona es como se meten
--  defectos que nadie va a buscar ahi.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.liquidar_remate(p_remate_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_is_super boolean;
  v_remate public.remates%rowtype;
  v_ganador_horse_id uuid;
  v_ganador_retirado boolean;
  v_ganador_user_id uuid;
  v_pozo_total numeric := 0;
  v_premio numeric := 0;
  v_caja numeric;
  v_wallet public.wallets%rowtype;
  v_resultado numeric;
begin
  -- CANDADO DE CAJA (espacio 3), anadido el 29/09 por el hallazgo A4.
  --
  -- Esta funcion no tomaba NINGUN advisory lock. Su unico candado era el
  -- `for update` sobre su propia fila de remates. Pero la guarda de solvencia
  -- compara el premio contra dinero_casa_disponible(), que es una agregacion
  -- GLOBAL: no hay ninguna fila que represente "la caja", asi que dos
  -- liquidaciones de remates distintos no se excluian.
  --
  --   Caja 1.000. R1 (premio 800) y R2 (premio 800) liquidados a la vez, o
  --   con un doble clic. Las dos leen 1.000, las dos pasan la guarda, las dos
  --   acreditan. 1.600 contra 1.000.
  --
  -- El dano se materializa cuando los dos ganadores piden el retiro:
  -- solicitar_retiro no mira la caja.
  --
  -- Espacio 3 = la caja. Global y sin objeto, porque la caja es global. Lo
  -- toman las dos unicas funciones que la consumen: esta y
  -- registrar_movimiento_casa.
  perform pg_advisory_xact_lock(3, 0);

  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select es_admin, es_super_admin
    into v_is_admin, v_is_super
  from public.profiles
  where id = v_admin_id;

  if coalesce(v_is_admin, false) = false and coalesce(v_is_super, false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  select * into v_remate
  from public.remates
  where id = p_remate_id
  for update;

  if not found then
    raise exception 'Remate no existe';
  end if;

  if v_remate.estado <> 'cerrado' then
    raise exception 'Para liquidar, el remate debe estar "cerrado" (estado actual: %)', v_remate.estado;
  end if;

  select rr.ganador_horse_id, coalesce(h.retirado, false)
    into v_ganador_horse_id, v_ganador_retirado
  from public.race_results rr
  left join public.horses h on h.id = rr.ganador_horse_id
  where rr.race_id = v_remate.race_id
  -- `limit 1` anadido el 29/09: segunda red del hallazgo D1. Con el unique
  -- sobre race_id no puede haber dos filas, pero un `select ... into` sin
  -- limit toma la primera que devuelva el plan SIN error ni aviso, y de eso
  -- depende a quien se le paga el premio.
  limit 1;

  if v_ganador_horse_id is null then
    raise exception 'Debes indicar el caballo ganador antes de liquidar';
  end if;

  -- Un caballo retirado no corre, asi que no puede ganar. Sin esta guarda, a su
  -- lider se le pagaria el premio sin haberle cobrado nada al cerrar (los
  -- retirados quedan fuera del cobro y fuera del pozo): dinero de la nada.
  if v_ganador_retirado then
    raise exception 'El caballo marcado como ganador esta retirado. Corrige el resultado de la carrera antes de liquidar.';
  end if;

  -- POZO. Cada caballo aporta su puja mas alta, y si nadie lo pujo aporta su
  -- precio_salida, porque queda con la casa por ese monto.
  -- TAREA 1.1: los retirados quedan fuera de los dos terminos.
  select coalesce(sum(coalesce(t.max_monto, h.precio_salida)), 0)
    into v_pozo_total
  from public.horses h
  left join (
    select horse_id, max(monto)::numeric as max_monto
    from public.bids
    where remate_id = p_remate_id
    group by horse_id
  ) t on t.horse_id = h.id
  where h.race_id = v_remate.race_id
    and coalesce(h.retirado, false) = false;

  select b.user_id
    into v_ganador_user_id
  from public.bids b
  where b.remate_id = p_remate_id
    and b.horse_id = v_ganador_horse_id
  order by b.monto desc, b.created_at asc
  limit 1;

  -- PREMIO. TAREA 1.2: sale de porcentaje_casa, no de un 0.75 clavado.
  if v_ganador_user_id is null then
    -- Gano un caballo de la casa: no hay premio que pagar, la casa se queda el
    -- pozo completo.
    v_premio := 0;
  else
    v_premio := round(v_pozo_total * (1 - coalesce(v_remate.porcentaje_casa, 25) / 100.0), 2);
  end if;

  -- GUARDA DE SOLVENCIA. TAREA 1.3.
  -- La casa banca los caballos que nadie pujo, y esos entran al pozo sin que
  -- nadie haya puesto ese dinero. Un remate de 10 caballos donde solo se puja
  -- uno genera un premio muy superior a lo que entro por caja. Acreditar eso
  -- es prometer un saldo que no se puede pagar cuando el usuario lo retire.
  if v_premio > 0 then
    v_caja := public.dinero_casa_disponible();
    if v_premio > v_caja then
      raise exception 'La casa no puede pagar este premio: son % Bs y la caja disponible es % Bs. Revisa la contabilidad antes de liquidar.',
        v_premio, v_caja;
    end if;
  end if;

  if v_ganador_user_id is not null and v_premio > 0 then
    select * into v_wallet
    from public.wallets
    where user_id = v_ganador_user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para el ganador';
    end if;

    update public.wallets
       set saldo_disponible = saldo_disponible + v_premio
     where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (v_wallet.id, 'premio', v_premio,
            'Premio del remate ' || v_remate.nombre,
            p_remate_id::text);

    -- EL AVISO AL GANADOR (migracion 20261005150000).
    --
    -- Va aqui dentro, pegado a la acreditacion, y no fuera: si no hubo premio
    -- -- gano un caballo de la casa, o nadie lo habia pujado -- no hay a quien
    -- avisar, y un aviso de premio sin premio seria peor que no avisar.
    --
    -- `_notificar` nunca propaga errores. Mismo criterio que `_avisar`: un
    -- aviso perdido no puede tumbar una liquidacion a medias. Y el premio NO
    -- depende de esto: ya esta en el saldo y en el movimiento de arriba, que
    -- son el registro de verdad.
    perform public._notificar(
      v_ganador_user_id,
      'premio',
      'Ganaste el remate',
      'Tu caballo gano en ' || v_remate.nombre || '. Se acreditaron ' ||
        trim(to_char(v_premio, 'FM999999990.00')) || ' Bs a tu saldo.',
      p_remate_id::text,
      v_premio);
  end if;

  -- ASIENTO EN EL LIBRO DE LA CASA (tarea 2.18).
  --
  -- Lo crea el sistema, no el admin. El resultado se LEE de los movimientos
  -- reales de este remate en vez de recalcularse:
  --
  --   apuesta_cobro      negativo (sale de los usuarios)  -> entra a la casa
  --   apuesta_devolucion positivo (vuelve a los usuarios)  -> sale de la casa
  --   premio             positivo (va al ganador)          -> sale de la casa
  --
  -- Por eso el signo va invertido. Al salir de los movimientos y no de una
  -- cuenta aparte, no se puede despegar de la realidad: si se retiro un caballo
  -- despues del cierre y se devolvio dinero, eso ya esta contado.
  --
  -- Cubre los dos casos sin distinguirlos: si gana un caballo de la casa el
  -- premio es 0 y el resultado es todo lo cobrado; si gana un usuario, el
  -- resultado es la comision.
  select -coalesce(sum(m.monto), 0)
    into v_resultado
  from public.wallet_movements m
  where m.ref_externa = p_remate_id::text
    and m.tipo in ('apuesta_cobro', 'apuesta_devolucion', 'premio');

  insert into public.house_ledger (tipo, monto, motivo, ref_externa, created_by, detalles)
  values ('resultado_remate', v_resultado,
          'Resultado del remate ' || v_remate.nombre,
          p_remate_id::text, null,
          jsonb_build_object(
            'pozo_total', v_pozo_total,
            'premio_pagado', v_premio,
            'porcentaje_casa', coalesce(v_remate.porcentaje_casa, 25),
            'gano_la_casa', (v_ganador_user_id is null)));

  update public.remates
  set estado = 'liquidado'
  where id = p_remate_id;

  return 'Remate liquidado. Pozo ' || v_pozo_total::text || ' Bs, premio ' || v_premio::text || ' Bs.';
end;
$function$;
revoke all on function public.liquidar_remate(uuid) from public, anon;
grant execute on function public.liquidar_remate(uuid) to authenticated;
