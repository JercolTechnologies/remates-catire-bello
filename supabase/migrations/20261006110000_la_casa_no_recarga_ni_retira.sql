-- ===========================================================================
--  20261006110000_la_casa_no_recarga_ni_retira.sql
--
--  Escrita el LUNES 5 DE OCTUBRE DE 2026, 22:40 hora de Caracas.
--  (El numero del archivo va en UTC, donde ya era dia 6. Ver la nota al final.)
--
--  UN AGUJERO QUE ABRI YO AYER Y QUE ENCONTRO JOTA PREGUNTANDO OTRA COSA
--
--  La regla "los admins no participan en remates" esta en la base desde el
--  30/09: `hacer_puja` la hace cumplir (20260930110000). Pero NADIE comprobaba
--  el rol en `solicitar_recarga` ni en `solicitar_retiro`. Un admin podia pedir
--  las dos cosas.
--
--  Hasta ayer eso era raro pero inofensivo. Ayer, con la separacion de
--  funciones del ADR-028 -- nadie procesa su propia solicitud -- se convirtio
--  en una trampa:
--
--    1. el admin pide un retiro
--    2. `solicitar_retiro` LE DESCUENTA EL SALDO en el acto
--    3. nadie puede procesarlo: el mismo no, por el ADR-028; y si es el unico
--       admin de la instalacion, no hay nadie mas
--    4. la solicitud queda pendiente para siempre, el dinero descontado, y
--       `casa_resumen` la cuenta como obligacion de la casa a perpetuidad
--
--  Lo introduje yo ayer y no lo vi. Lo encontro Jota preguntando por que el
--  menu de cliente le mostraba "Recargar" y "Retirar" a un admin -- una
--  pregunta de interfaz que destapo un defecto de dinero.
--
--  LA DECISION, que es la que ya estaba escrita para las pujas: LA CASA NO
--  JUEGA, y tampoco usa la cartera de jugador. El administrador es el operador
--  del sistema, no un usuario con saldo.
--
--  LA SALIDA PARA QUIEN YA TENIA DINERO. Un jugador con saldo al que ascienden
--  a admin no puede sacarlo. No se anula ni se mueve nada -- mismo criterio que
--  20260930110000 con las pujas viejas: tocar dinero ya comprometido por un
--  cambio de rol es peor que el problema. Lo que se hace es decirlo en el
--  propio mensaje de error: que un super admin le retire el cargo, haga la
--  operacion, y se lo devuelva. El codigo queda reservado (ADR-027), asi que
--  recupera su misma identidad en el registro.
--
--  SOBRE EL NUMERO DEL ARCHIVO. El prefijo de una migracion es una CLAVE DE
--  ORDEN, no una fecha: lo unico que la base exige es que sea creciente. Yo
--  trabajo en UTC y Jota en Colombia (UTC-5), con la aplicacion en hora de
--  Caracas (UTC-4), asi que a partir de las 19:00 suyas yo ya estoy en el dia
--  siguiente. La migracion anterior salio numerada 20261006 cuando aqui todavia
--  era 5. No se renumera -- ya esta aplicada en produccion y renombrarla
--  descuadraria `schema_migrations` -- y de aqui en adelante la fecha de verdad
--  va escrita en la cabecera, en hora de Caracas.
-- ===========================================================================

CREATE OR REPLACE FUNCTION "public"."solicitar_recarga"("p_monto" numeric, "p_metodo" "text", "p_telefono_pago" "text", "p_referencia" "text", "p_fecha_pago" "date") RETURNS "public"."deposit_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_request public.deposit_requests%rowtype;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if p_monto is null or p_monto <= 0 then
    raise exception 'El monto debe ser mayor a 0';
  end if;

  -- LA CASA NO JUEGA, Y TAMPOCO USA LA CARTERA DE JUGADOR.
  -- Ver la cabecera de esta migracion: con la guarda del ADR-028, una
  -- solicitud de un admin que nadie puede procesar se queda atascada para
  -- siempre, y en el caso del retiro ya le descontaron el saldo.
  if public.is_admin() then
    raise exception 'Un administrador no puede pedir una recarga. Si tienes saldo de antes de serlo, pide a un super admin que te retire el cargo, haz la operacion y que te lo devuelva: el codigo queda reservado.';
  end if;

  if p_metodo is null or length(trim(p_metodo)) = 0 then
    raise exception 'Debe especificar el método de pago';
  end if;

  if p_telefono_pago is null or length(trim(p_telefono_pago)) = 0 then
    raise exception 'Debe especificar el teléfono desde el que se realizó el pago';
  end if;

  if p_referencia is null or length(trim(p_referencia)) = 0 then
    raise exception 'Debe especificar la referencia del pago';
  end if;

  if p_fecha_pago is null then
    raise exception 'Debe especificar la fecha del pago';
  end if;

  insert into public.deposit_requests (
    user_id, monto, metodo, telefono_pago, referencia, fecha_pago, estado
  ) values (
    v_user_id, p_monto, p_metodo, p_telefono_pago, p_referencia, p_fecha_pago, 'pendiente'::deposit_status
  )
  returning * into v_request;

  return v_request;
end;
$$;
create or replace function public.solicitar_retiro(
  p_monto numeric, p_metodo text, p_telefono_destino text, p_comentario text default null)
returns withdraw_requests
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_user_id uuid := auth.uid();
  v_wallet public.wallets%rowtype;
  v_request public.withdraw_requests%rowtype;
  v_compromiso numeric;
  v_retirable numeric;
  v_req record;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if p_monto is null or p_monto <= 0 then
    raise exception 'El monto debe ser mayor a 0';
  end if;

  -- LA CASA NO JUEGA, Y TAMPOCO USA LA CARTERA DE JUGADOR.
  -- Ver la cabecera de esta migracion: con la guarda del ADR-028, una
  -- solicitud de un admin que nadie puede procesar se queda atascada para
  -- siempre, y en el caso del retiro ya le descontaron el saldo.
  if public.is_admin() then
    raise exception 'Un administrador no puede pedir un retiro. Si tienes saldo de antes de serlo, pide a un super admin que te retire el cargo, haz la operacion y que te lo devuelva: el codigo queda reservado.';
  end if;

  if p_metodo is null or length(trim(p_metodo)) = 0 then
    raise exception 'Debe especificar el metodo de retiro';
  end if;

  if p_telefono_destino is null or length(trim(p_telefono_destino)) = 0 then
    raise exception 'Debe especificar el telefono destino';
  end if;

  -- MISMO candado que hacer_puja y que el cierre. Sin el, un usuario puja y
  -- pide el retiro al mismo tiempo desde dos pestanas: las dos operaciones leen
  -- el mismo compromiso viejo y las dos pasan.
  perform pg_advisory_xact_lock(1, hashtext(v_user_id::text));

  select * into v_wallet
  from public.wallets
  where user_id = v_user_id
  for update;

  if not found then
    raise exception 'No se encontro wallet para el usuario';
  end if;

  v_compromiso := public.compromiso_usuario(v_user_id);
  select * into v_req from public.requisito_apuesta(v_user_id);

  -- DOS TECHOS, y el mensaje tiene que decir cual de los dos choco. Un
  -- "no puedes retirar" sin motivo se convierte en un mensaje de soporte.
  v_retirable := least(v_wallet.saldo_disponible - v_compromiso, v_req.tope_por_regla);

  if p_monto > v_retirable then
    if not v_req.cumplido and p_monto > v_req.tope_por_regla then
      -- OJO con el porcentaje literal: en `raise`, `%%%` se lee como `%%`
      -- (porcentaje literal) y luego `%` (sustitucion), asi que sale "%50" en
      -- vez de "50%". Se escribe con palabras y se acaba la ambiguedad.
      raise exception
        'Para retirar tienes que haber apostado al menos el % por ciento de lo que has recargado. Has recargado % Bs y has apostado % Bs: te faltan % Bs por apostar. Puedes retirar % Bs, que es lo que llevas ganado en premios.',
        v_req.pct, v_req.recargado, v_req.apostado, v_req.falta_apostar,
        greatest(least(v_req.premios_libres, v_wallet.saldo_disponible - v_compromiso), 0);
    end if;

    raise exception 'Solo puedes retirar % Bs. Tienes % Bs en total, y % Bs comprometidos en pujas que lideras ahora mismo.',
      greatest(v_retirable, 0), v_wallet.saldo_disponible, v_compromiso;
  end if;

  update public.wallets
     set saldo_disponible = saldo_disponible - p_monto
   where id = v_wallet.id;

  insert into public.withdraw_requests (
    user_id, monto, metodo, telefono_destino, comentario, estado
  ) values (
    v_user_id, p_monto, p_metodo, p_telefono_destino, p_comentario, 'pendiente'::withdraw_status
  )
  returning * into v_request;

  insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
  values (v_wallet.id, 'retiro', -p_monto,
          'Solicitud de retiro (metodo: ' || p_metodo || ')',
          v_request.id::text);

  return v_request;
end;
$fn$;
revoke all on function public.solicitar_recarga(numeric, text, text, text, date)    from public, anon;
revoke all on function public.solicitar_retiro(numeric, text, text, text)           from public, anon;
grant execute on function public.solicitar_recarga(numeric, text, text, text, date) to authenticated;
grant execute on function public.solicitar_retiro(numeric, text, text, text)        to authenticated;
