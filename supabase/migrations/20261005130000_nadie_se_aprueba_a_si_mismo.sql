-- ===========================================================================
--  20261005130000_nadie_se_aprueba_a_si_mismo.sql
--
--  EL AGUJERO QUE ABRE TENER VARIOS ADMINS
--
--  Hasta hoy `aprobar_recarga`, `rechazar_recarga` y `procesar_retiro` solo
--  comprobaban que quien llama sea admin. NO comprobaban de quien es la
--  solicitud. Con un unico administrador -- que ademas es el dueno -- eso no
--  importaba: aprobarse una recarga a si mismo es moverse dinero de un bolsillo
--  al otro.
--
--  En cuanto hay dos administradores deja de ser lo mismo, y pasa a ser la via
--  de fraude mas corta que tiene la aplicacion:
--
--    1. el admin pide una recarga de 50.000 para su propia cuenta
--    2. el admin se la aprueba
--    3. el saldo es real: puja, gana, o pide el retiro y se lo paga el mismo
--
--  Tres clics, sin tocar la base de datos, sin saber SQL, y dejando en la
--  bitacora una secuencia que parece normal salvo que alguien se fije en que
--  el que aprueba y el que cobra son la misma persona.
--
--  Esto va EN EL MISMO BLOQUE que la identidad de los admins (20261005120000)
--  a proposito. Entregar la posibilidad de tener varios administradores sin
--  esta guarda seria abrir la puerta y dejar la llave puesta.
--
--  LA GUARDA ES SEPARACION DE FUNCIONES, no desconfianza: es el principio de
--  que quien pide y quien autoriza no pueden ser la misma persona. Lo cumple
--  cualquier caja del mundo, y ninguna lo hace porque sus empleados sean
--  ladrones: lo hace porque asi nadie queda bajo sospecha cuando falta dinero.
--
--  QUE NO IMPIDE, Y HAY QUE VERLO ESCRITO
--  Dos admins compinchados se aprueban el uno al otro. Contra eso el software
--  no puede hacer nada, y no se pretende. Lo que si consigue es que la bitacora
--  diga con nombre y codigo quien autorizo cada cosa, que es la mitad del
--  trabajo (ver 20261005120000).
--
--  COMO SE ESCRIBIO ESTE ARCHIVO
--  Los tres cuerpos NO se reteclearon: se extrajeron de su ultima definicion
--  -- `aprobar_recarga` del baseline, las otras dos de la migracion del 01/10 --
--  y se les inserto la guarda justo despues de cargar la solicitud. Es la
--  leccion del ADR-021: reescribir a mano un cuerpo que ya funciona es una
--  forma barata de meter defectos que nadie va a buscar ahi.
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
$$;


create or replace function public.rechazar_recarga(
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
end $fn$;

create or replace function public.procesar_retiro(
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

    return 'Retiro rechazado y saldo devuelto';
  end if;

  raise exception 'Estado no soportado: %', p_nuevo_estado;
end $fn$;


-- El inventario de permisos, otra vez, porque `create or replace` conserva los
-- privilegios pero no cuesta nada dejarlo declarado y verificable (P47).
revoke all on function public.aprobar_recarga(uuid)                                     from public, anon;
revoke all on function public.rechazar_recarga(uuid, text, text)                        from public, anon;
revoke all on function public.procesar_retiro(uuid, public.withdraw_status, text, text) from public, anon;

grant execute on function public.aprobar_recarga(uuid)                                     to authenticated;
grant execute on function public.rechazar_recarga(uuid, text, text)                        to authenticated;
grant execute on function public.procesar_retiro(uuid, public.withdraw_status, text, text) to authenticated;
