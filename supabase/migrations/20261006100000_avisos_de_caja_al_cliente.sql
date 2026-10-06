-- ===========================================================================
--  20261006100000_avisos_de_caja_al_cliente.sql
--
--  LOS CUATRO AVISOS QUE FALTABAN
--
--  La maquinaria entera se construyo ayer para el premio (20261005150000):
--  tabla con estado de leida, canal privado por usuario, popup en el layout
--  raiz. Esto es engancharla donde ya tenia que estar:
--
--    aprobar_recarga   -> "Recarga aprobada"
--    rechazar_recarga  -> "Recarga rechazada", CON EL MOTIVO
--    procesar_retiro   -> "Retiro pagado"
--    procesar_retiro   -> "Retiro rechazado y el dinero volvio a tu saldo"
--
--  Son cuatro llamadas. Esa es exactamente la razon por la que ayer se hizo una
--  tabla de notificaciones en vez de un popup de premio: construir el del
--  premio a medida habria significado reescribirlo hoy cuatro veces.
--
--  POR QUE EL MOTIVO VA EN EL TEXTO Y NO SOLO EN LA FILA
--  El motivo ya se guarda en `deposit_requests.motivo_etiqueta` desde el 01/10
--  y el cliente lo ve si entra a la pantalla de recargas. Pero el aviso que le
--  salta encima es el momento en que de verdad lo lee. Un "Recarga rechazada" a
--  secas es un mensaje de soporte garantizado.
--
--  Y EN EL RETIRO RECHAZADO, LO PRIMERO ES QUE EL DINERO VOLVIO. Es lo que
--  cualquiera quiere saber antes que el motivo, y si no se dice, el jugador
--  asume lo peor.
--
--  LOS TRES CUERPOS NO SE RETECLEARON: se extrajeron de 20261005130000 y se les
--  inserto la llamada. ADR-021.
--
--  `_notificar` nunca propaga errores (ADR-030): un aviso perdido no puede
--  tumbar una aprobacion de recarga. El dinero ya se movio cuando esto corre.
-- ===========================================================================

CREATE OR REPLACE FUNCTION "public"."aprobar_recarga"("p_deposit_request_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_request public.deposit_requests%rowtype;
  v_wallet public.wallets%rowtype;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'No autorizado: solo administradores pueden aprobar recargas';
  end if;

  select * into v_request
  from public.deposit_requests
  where id = p_deposit_request_id;

  if not found then
    raise exception 'Solicitud de recarga no existe';
  end if;

  -- NADIE PROCESA SU PROPIA SOLICITUD (migracion 20261005130000).
  if v_request.user_id = v_user_id then
    raise exception 'No puedes procesar tu propia solicitud. Pidele a otro administrador que la revise.';
  end if;

  if v_request.estado <> 'pendiente' then
    raise exception 'La solicitud de recarga no esta pendiente (estado actual: %)', v_request.estado;
  end if;

  select * into v_wallet
  from public.wallets
  where user_id = v_request.user_id
  for update;

  if not found then
    raise exception 'No se encontro wallet para el usuario de la recarga';
  end if;

  v_wallet.saldo_disponible := v_wallet.saldo_disponible + v_request.monto;

  update public.wallets
  set saldo_disponible = v_wallet.saldo_disponible
  where id = v_wallet.id;

  insert into public.wallet_movements (
    wallet_id, tipo, monto, descripcion, ref_externa
  ) values (
    v_wallet.id,
    'recarga'::wallet_movement_type,
    v_request.monto,
    'Recarga aprobada (metodo: ' || v_request.metodo || ', ref: ' || v_request.referencia || ')',
    v_request.id::text
  );

  update public.deposit_requests
  set estado = 'aprobado'::deposit_status,
      approved_at = now(),
      approved_by = v_user_id
  where id = v_request.id;

  -- EL AVISO AL CLIENTE (migracion 20261006100000).
  -- Hasta hoy la recarga se acreditaba y el cliente se enteraba mirando. Con
  -- un jugador esperando al otro lado, eso son minutos de incertidumbre que no
  -- cuestan nada quitar.
  perform public._notificar(
    v_request.user_id, 'recarga', 'Recarga aprobada',
    'Se acreditaron ' || trim(to_char(v_request.monto, 'FM999999990.00')) ||
      ' Bs a tu saldo.',
    v_request.id::text, v_request.monto);

  perform public.log_admin_action(
    v_user_id,
    'aprobar_recarga',
    'deposit_requests',
    v_request.id::text,
    jsonb_build_object(
      'prev', jsonb_build_object('estado', v_request.estado),
      'next', jsonb_build_object('estado', 'aprobado'),
      'monto', v_request.monto,
      'user_id', v_request.user_id,
      'metodo', v_request.metodo,
      'referencia', v_request.referencia
    ),
    true,
    null
  );

  return 'Recarga aprobada y saldo acreditado';

exception
  when others then
    perform public.log_admin_action(
      v_user_id,
      'aprobar_recarga',
      'deposit_requests',
      coalesce(p_deposit_request_id::text, ''),
      jsonb_build_object(
        'next', jsonb_build_object('estado', 'aprobado')
      ),
      false,
      sqlerrm
    );
    raise;
end;
$$;create or replace function public.rechazar_recarga(
  p_deposit_request_id uuid,
  p_motivo_codigo text,
  p_nota text default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_request public.deposit_requests%rowtype;
  v_etiqueta text;
  v_nota text := nullif(trim(coalesce(p_nota, '')), '');
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  if p_deposit_request_id is null then
    raise exception 'Parametro invalido';
  end if;

  if not public.is_admin() then
    raise exception 'No autorizado: solo administradores pueden rechazar recargas';
  end if;

  v_etiqueta := public._motivo_etiqueta(p_motivo_codigo, 'recarga');

  select * into v_request
  from public.deposit_requests
  where id = p_deposit_request_id;

  if not found then
    raise exception 'Solicitud de recarga no existe';
  end if;

  -- NADIE PROCESA SU PROPIA SOLICITUD (migracion 20261005130000).
  if v_request.user_id = v_admin_id then
    raise exception 'No puedes procesar tu propia solicitud. Pidele a otro administrador que la revise.';
  end if;

  if v_request.estado <> 'pendiente' then
    raise exception 'La solicitud de recarga no esta pendiente (estado actual: %)', v_request.estado;
  end if;

  update public.deposit_requests
  set estado = 'rechazado'::deposit_status,
      approved_at = now(),
      approved_by = v_admin_id,
      motivo_codigo = trim(p_motivo_codigo),
      motivo_etiqueta = v_etiqueta,
      motivo_nota = v_nota
  where id = v_request.id
    and estado = 'pendiente'::deposit_status;

  if not found then
    raise exception 'La solicitud cambio de estado mientras se procesaba';
  end if;

  -- EL AVISO, CON EL MOTIVO DENTRO. Un rechazo sin motivo es un mensaje de
  -- soporte garantizado, y el motivo ya lo tenemos aqui mismo.
  perform public._notificar(
    v_request.user_id, 'recarga', 'Recarga rechazada',
    'Tu recarga de ' || trim(to_char(v_request.monto, 'FM999999990.00')) ||
      ' Bs fue rechazada. Motivo: ' || v_etiqueta ||
      coalesce('. Nota: ' || v_nota, '') || '.',
    v_request.id::text, v_request.monto);

  perform public.log_admin_action(
    v_admin_id, 'rechazar_recarga', 'deposit_requests', v_request.id::text,
    jsonb_build_object(
      'prev', jsonb_build_object('estado', v_request.estado),
      'next', jsonb_build_object('estado', 'rechazado'),
      'motivo_codigo', trim(p_motivo_codigo),
      'motivo_etiqueta', v_etiqueta,
      'motivo_nota', v_nota
    ),
    true, null
  );

  return 'Recarga rechazada';
end $fn$;create or replace function public.procesar_retiro(
  p_withdraw_id uuid,
  p_nuevo_estado public.withdraw_status,
  p_motivo_codigo text default null,
  p_nota text default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_user_id uuid := auth.uid();
  v_request public.withdraw_requests%rowtype;
  v_wallet public.wallets%rowtype;
  v_etiqueta text;
  v_nota text := nullif(trim(coalesce(p_nota, '')), '');
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'No autorizado: solo administradores pueden procesar retiros';
  end if;

  -- El motivo se valida ANTES de tocar dinero. Si el codigo esta mal, que
  -- reviente aqui y no a mitad de la devolucion.
  if p_nuevo_estado = 'rechazado'::withdraw_status then
    v_etiqueta := public._motivo_etiqueta(p_motivo_codigo, 'retiro');
  end if;

  select * into v_request
  from public.withdraw_requests
  where id = p_withdraw_id;

  if not found then
    raise exception 'Solicitud de retiro no existe';
  end if;

  -- NADIE PROCESA SU PROPIA SOLICITUD (migracion 20261005130000).
  if v_request.user_id = v_user_id then
    raise exception 'No puedes procesar tu propia solicitud. Pidele a otro administrador que la revise.';
  end if;

  if v_request.estado <> 'pendiente' then
    raise exception 'La solicitud de retiro ya fue procesada (estado actual: %)', v_request.estado;
  end if;

  if p_nuevo_estado = 'pagado'::withdraw_status then
    update public.withdraw_requests
    set estado = 'pagado'::withdraw_status,
        processed_at = now(),
        processed_by = v_user_id
    where id = v_request.id
      and estado = 'pendiente'::withdraw_status;

    if not found then
      raise exception 'La solicitud cambio de estado mientras se procesaba';
    end if;

    perform public.log_admin_action(
      v_user_id, 'procesar_retiro', 'withdraw_requests', v_request.id::text,
      jsonb_build_object(
        'prev', jsonb_build_object('estado', v_request.estado),
        'next', jsonb_build_object('estado', 'pagado'),
        'monto', v_request.monto,
        'user_id', v_request.user_id,
        'metodo', v_request.metodo,
        'telefono_destino', v_request.telefono_destino
      ),
      true, null
    );

    perform public._notificar(
      v_request.user_id, 'retiro', 'Retiro pagado',
      'Tu retiro de ' || trim(to_char(v_request.monto, 'FM999999990.00')) ||
        ' Bs fue procesado por ' || v_request.metodo || '.',
      v_request.id::text, v_request.monto);

    return 'Retiro marcado como pagado';

  elsif p_nuevo_estado = 'rechazado'::withdraw_status then
    select * into v_wallet
    from public.wallets
    where user_id = v_request.user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para el usuario del retiro';
    end if;

    update public.wallets
    set saldo_disponible = saldo_disponible + v_request.monto
    where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (v_wallet.id, 'ajuste_manual'::wallet_movement_type, v_request.monto,
            'Devolucion de retiro rechazado', v_request.id::text);

    update public.withdraw_requests
    set estado = 'rechazado'::withdraw_status,
        processed_at = now(),
        processed_by = v_user_id,
        motivo_codigo = trim(p_motivo_codigo),
        motivo_etiqueta = v_etiqueta,
        motivo_nota = v_nota
    where id = v_request.id
      and estado = 'pendiente'::withdraw_status;

    if not found then
      raise exception 'La solicitud cambio de estado mientras se procesaba';
    end if;

    perform public.log_admin_action(
      v_user_id, 'procesar_retiro', 'withdraw_requests', v_request.id::text,
      jsonb_build_object(
        'prev', jsonb_build_object('estado', v_request.estado),
        'next', jsonb_build_object('estado', 'rechazado'),
        'monto', v_request.monto,
        'user_id', v_request.user_id,
        'motivo_codigo', trim(p_motivo_codigo),
        'motivo_etiqueta', v_etiqueta,
        'motivo_nota', v_nota,
        'devuelto', true
      ),
      true, null
    );

    -- Que el dinero volvio al saldo es lo PRIMERO que quiere saber quien ve
    -- un retiro rechazado. Va en el texto, no solo en el movimiento.
    perform public._notificar(
      v_request.user_id, 'retiro', 'Retiro rechazado',
      'Tu retiro de ' || trim(to_char(v_request.monto, 'FM999999990.00')) ||
        ' Bs fue rechazado y el dinero volvio a tu saldo. Motivo: ' ||
        v_etiqueta || coalesce('. Nota: ' || v_nota, '') || '.',
      v_request.id::text, v_request.monto);

    return 'Retiro rechazado y saldo devuelto';
  end if;

  raise exception 'Estado no soportado: %', p_nuevo_estado;
end $fn$;
revoke all on function public.aprobar_recarga(uuid)                                     from public, anon;
revoke all on function public.rechazar_recarga(uuid, text, text)                        from public, anon;
revoke all on function public.procesar_retiro(uuid, public.withdraw_status, text, text) from public, anon;

grant execute on function public.aprobar_recarga(uuid)                                     to authenticated;
grant execute on function public.rechazar_recarga(uuid, text, text)                        to authenticated;
grant execute on function public.procesar_retiro(uuid, public.withdraw_status, text, text) to authenticated;
