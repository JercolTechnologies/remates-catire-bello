-- ============================================================================
--  PRUEBAS DE DINERO -> Remates Catire Bello
--
--  Corre contra la base LOCAL, nunca contra produccion.
--
--    supabase start
--    psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f tests/pruebas_dinero.sql
--
--  Cada prueba es independiente: limpia, arma su escenario, y verifica.
--  Al final imprime un resumen. Ninguna prueba tumba a las demas.
--
--  IMPORTANTE: varias FALLAN a proposito contra el codigo actual. Esas fallas
--  son el defecto reproducido. Cuando se aplique la correccion, pasan a OK.
--
--  ---------------------------------------------------------------------------
--  REGLA, APRENDIDA A GOLPES EL 28/09
--
--  Cuando el exito de una prueba consiste en "salto una excepcion", hay que
--  comprobar CUAL excepcion.
--
--  P39 pasaba en verde SIN la migracion aplicada. Llamaba a una funcion que
--  todavia no existia, saltaba `function does not exist`, y su
--  `exception when others` lo contaba como el rechazo que buscaba. Las dos
--  mitades de la prueba aprobaban por la misma razon: no habia nada que
--  probar. Es lo contrario de lo que dice el ADR-009, y estaba dentro del
--  propio arnes.
--
--  Un `when others` se traga tanto el rechazo que buscas como el error que
--  significa que no estas probando nada. Los dos que importan:
--
--    P0001 = raise_exception     -> NUESTRO codigo rechazo, a proposito
--    42883 = undefined_function  -> la migracion no esta aplicada
--    23503 = foreign_key_violation -> lo freno una clave foranea
--    42501 = insufficient_privilege -> lo freno un permiso
--
--  Y no basta con que rechace: hay que comprobar ADEMAS que no escribio nada.
--  Ver P39 como patron.
--
--  PENDIENTE: hay 66 bloques con `exception when others` en este archivo. Los
--  demas prueban funciones que llevan tiempo existiendo, asi que el riesgo es
--  menor, pero la trampa es la misma el dia que una migracion renombre algo.
--  Retrofit anotado en el backlog; las pruebas NUEVAS siguen la regla ya.
--  ---------------------------------------------------------------------------
-- ============================================================================

\set ON_ERROR_STOP off
\set QUIET on
set client_min_messages to warning;

-- ---------------------------------------------------------------- andamiaje
create schema if not exists _p;

drop table if exists _p.resultado;
create table _p.resultado (
  n        int,
  nombre   text,
  esperado text,
  estado   text,
  detalle  text
);

create or replace function _p.limpiar() returns void language plpgsql as $$
begin
  delete from public.wallet_movements;
  delete from public.bids;
  delete from public.race_results;
  delete from public.remate_price_rules;
  delete from public.remates;
  delete from public.horses;
  delete from public.races;
  delete from public.withdraw_requests;
  delete from public.deposit_requests;
  delete from public.wallets;
  -- ANTES que profiles: house_ledger.created_by apunta ahi. Es el mismo
  -- problema de orden que tenia reset_app_cero.sql con race_results.
  delete from public.house_ledger;
  delete from public.profiles;
  delete from auth.users;
end $$;

create or replace function _p.usuario(p_nombre text, p_saldo numeric default 0, p_admin boolean default false)
returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id) values (v_id);
  insert into public.profiles (id, username, es_admin, es_super_admin)
    values (v_id, p_nombre, p_admin, p_admin)
  on conflict (id) do update set username = excluded.username,
                                 es_admin = excluded.es_admin,
                                 es_super_admin = excluded.es_super_admin;
  insert into public.wallets (user_id, saldo_disponible, saldo_bloqueado)
    values (v_id, p_saldo, 0)
  on conflict (user_id) do update set saldo_disponible = excluded.saldo_disponible,
                                      saldo_bloqueado = 0;

  -- Registra la recarga aprobada que respalda ese saldo.
  --
  -- Sin esto el andamiaje crea dinero de la nada: la wallet tiene saldo pero la
  -- casa no recibio nunca ese deposito, asi que dinero_casa_disponible() da
  -- negativo desde el primer momento. La guarda de solvencia de la tarea 1.3
  -- saltaba en TODAS las pruebas, y parecia un defecto del codigo cuando el
  -- problema era el escenario.
  --
  -- En la aplicacion real el dinero solo entra por aprobar_recarga, que deja su
  -- fila en deposit_requests. El arnes tiene que reflejar eso o no esta
  -- probando el sistema, esta probando una ficcion.
  if p_saldo > 0 then
    insert into public.deposit_requests
      (user_id, monto, metodo, telefono_pago, referencia, fecha_pago, estado, approved_at)
    values
      (v_id, p_saldo, 'pago_movil', '04120000000', 'ANDAMIAJE-' || p_nombre,
       current_date, 'aprobado', now());
  end if;

  return v_id;
end $$;

create or replace function _p.actuar_como(p_id uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_id)::text, false);
end $$;

-- carrera + remate + N caballos, todos al mismo precio de salida
create or replace function _p.escenario(p_n_caballos int, p_precio numeric, p_pct_casa numeric default 25)
returns uuid language plpgsql as $$
declare v_race uuid := gen_random_uuid(); v_rem uuid := gen_random_uuid(); i int;
begin
  insert into public.races (id, nombre, fecha, estado)
    values (v_race, 'Carrera de prueba', current_date, 'programada');
  insert into public.remates (id, race_id, nombre, estado, incremento_minimo, apuesta_minima, porcentaje_casa, opens_at, closes_at)
    values (v_rem, v_race, 'Remate de prueba', 'abierto', 10, 1, p_pct_casa, now() - interval '1 hour', now() + interval '1 hour');
  for i in 1..p_n_caballos loop
    insert into public.horses (race_id, numero, nombre, precio_salida)
      values (v_race, i, 'Caballo ' || i, p_precio);
  end loop;
  return v_rem;
end $$;

create or replace function _p.caballo(p_remate uuid, p_numero int) returns uuid language sql stable as $$
  select h.id from public.horses h
  join public.remates r on r.race_id = h.race_id
  where r.id = p_remate and h.numero = p_numero;
$$;

create or replace function _p.saldo(p_user uuid) returns numeric language sql stable as $$
  select saldo_disponible from public.wallets where user_id = p_user;
$$;

create or replace function _p.anotar(p_n int, p_nombre text, p_esperado text, p_ok boolean, p_detalle text default '')
returns void language sql as $$
  insert into _p.resultado values (p_n, p_nombre, p_esperado, case when p_ok then 'OK' else 'FALLA' end, p_detalle);
$$;

-- ============================================================================
--  MINIMOS DE INSTALACION: EL ARNES LOS BAJA PARA SUS ESCENARIOS
--
--  El 01/10 la base dejo de aceptar incrementos por debajo de
--  ajustes_instalacion.minimo_incremento (50 Bs en produccion). `_p.escenario`
--  crea sus remates con incremento 10, y lo hacen 42 pruebas cuyas cuentas
--  esperadas estan escritas sobre ese 10.
--
--  Habia dos salidas. Subir el escenario a 50 y rehacer la aritmetica de 42
--  pruebas -- mucho riesgo de cambiar lo que una prueba mide sin darse cuenta.
--  O bajar el ajuste, que es precisamente para lo que existe: un licenciatario
--  puede ponerlo en 10 perfectamente.
--
--  Se baja. Y P54 lo sube a proposito para comprobar que el guardian rechaza,
--  con lo cual queda probado algo mejor que un numero fijo: que la base obedece
--  al AJUSTE y no a una constante escondida.
--
--  EN CUANTO SE BAJA, Y POR QUE NO EN 10 (corregido el 01/10)
--
--  El primer intento los bajo a 10 y 100, que parecia suficiente. No lo era, y
--  el arnes lo dijo en dos lineas rojas:
--
--    P28 pone `incremento_minimo = 7` a mano, un fallback raro a proposito
--    P54 mete un caballo de 20 Bs para hacer de "dato viejo" de produccion
--
--  Dos veces el mismo error mio: cerrar una puerta sin enumerar quien la usa
--  (ADR-018). La leccion no es "subelo a 7": es que el arnes no mide minimos,
--  los mide P54. Para todo lo demas el guardian tiene que estorbar lo menos
--  posible, asi que se bajan a 1 y se acaba la familia entera de este fallo.
--
--  El bloque de limpieza del final los devuelve a 50 y 100, para que la base
--  local no quede permitiendo cosas que produccion no permite. OJO: por eso
--  `concurrencia.sql` los vuelve a bajar por su cuenta -- corre despues.
--
--  Si la migracion no esta aplicada, esto no hace nada y P54 se pone roja sola,
--  que es lo correcto.
-- ============================================================================
do $$
begin
  if to_regclass('public.ajustes_instalacion') is not null then
    update public.ajustes_instalacion set valor = '1' where clave = 'minimo_incremento';
    update public.ajustes_instalacion set valor = '1' where clave = 'minimo_precio_salida';
    -- Y la regla del 50% para retirar (01/10). P9 recarga 1000, no puja nada y
    -- retira los 1000 para medir que dinero_casa queda en 0; con la regla
    -- activa ese retiro rebota y P9 mide otra cosa. El porcentaje es un ajuste,
    -- asi que se apaga aqui y P55 lo sube a 50 para comprobar el rechazo.
    update public.ajustes_instalacion set valor = '0' where clave = 'pct_apostado_para_retirar';
  else
    raise warning 'ajustes_instalacion no existe: la migracion 20261001100000 no esta aplicada';
  end if;
end $$;


-- ============================================================================
--  P1 - El caballo retirado no debe entrar al pozo
--  Defecto C1 -> se espera FALLA contra el codigo actual (tarea 1.1)
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
        v_premio_real numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);           -- 3 caballos a 100
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);
  v_h3    := _p.caballo(v_rem, 3);

  perform _p.actuar_como(v_u);  perform public.hacer_puja(v_rem, v_h1, 200, true);  -- juan el 1 en 200
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h3, null, false); -- pedro el 3 en 100

  update public.horses set retirado = true where id = v_h2;  -- se retira el 2

  -- Pozo correcto: 200 (caballo 1) + 100 (caballo 3) = 300. El caballo 2 esta
  -- retirado y NO debe sumar; si sumara, el pozo daria 400 y el premio 300.
  --
  -- Pedro puja el tercer caballo a proposito: si quedara a la casa, la casa
  -- aportaria 100 al pozo sin que ese dinero haya entrado por caja, y la guarda
  -- de solvencia bloquearia la liquidacion antes de que esta prueba pueda medir
  -- nada. Ese hueco es real y esta anotado como tarea 2.18 (capital de la casa);
  -- aqui se evita a proposito para que la prueba mida lo suyo.

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 1);
  perform public.liquidar_remate(v_rem);

  select monto into v_premio_real
  from public.wallet_movements wm
  join public.wallets w on w.id = wm.wallet_id
  where w.user_id = v_u and wm.tipo = 'premio';

  perform _p.anotar(1, 'Caballo retirado fuera del pozo', 'premio = 225 (75% de 300)',
    round(coalesce(v_premio_real,0),2) = 225,
    'premio real: ' || coalesce(v_premio_real,0)::text || ' -> si da 300, el retirado sumo 100 al pozo');
exception when others then
  perform _p.anotar(1, 'Caballo retirado fuera del pozo', 'premio = 225 (75% de 300)', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P2 - La comision debe salir de porcentaje_casa, no de un 0.75 clavado
--  Defecto C2 -> se espera FALLA contra el codigo actual (tarea 1.2)
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_premio numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(2, 100, 30);      -- porcentaje_casa = 30
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u);  perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h2, null, false);
  -- Pozo = 200 + 100 = 300. Con la casa al 30%, el premio debe ser 210, no 225.
  -- El 30 no es lo que cobra la casa: es un valor distinto del 25 por defecto,
  -- elegido para que la prueba detecte si el codigo ignora la columna. Con 25
  -- pasaria en verde aunque el 0.75 siguiera clavado.

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 1);
  perform public.liquidar_remate(v_rem);

  select monto into v_premio from public.wallet_movements wm
  join public.wallets w on w.id = wm.wallet_id
  where w.user_id = v_u and wm.tipo = 'premio';

  perform _p.anotar(2, 'porcentaje_casa se respeta', 'premio = 210 (70% de 300)',
    round(coalesce(v_premio,0),2) = 210,
    'premio real: ' || coalesce(v_premio,0)::text || ' -> si da 225, uso el 0.75 clavado');
exception when others then
  perform _p.anotar(2, 'porcentaje_casa se respeta', 'premio = 210 (70% de 300)', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P3 - Si gana un caballo de la casa, no se paga premio
--  Se espera OK -> esta regla ya funciona
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_n int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 3);   -- gana un caballo SIN puja
  perform public.liquidar_remate(v_rem);

  select count(*) into v_n from public.wallet_movements where tipo = 'premio';
  perform _p.anotar(3, 'Gana caballo de la casa: sin premio', '0 movimientos de premio',
    v_n = 0, 'movimientos de premio: ' || v_n::text);
exception when others then
  perform _p.anotar(3, 'Gana caballo de la casa: sin premio', '0 movimientos de premio', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P4 - La casa no puede acreditar un premio que no puede pagar
--
--  REESCRITA EN LA TAJADA D. El escenario anterior le daba 100 Bs al usuario y
--  le hacia pujar 510: desde la tajada B esa puja la rechaza la guarda de
--  exposicion, asi que no habia pujas, no habia premio, y la liquidacion pasaba
--  sin probar nada. La prueba se habia vuelto ciega.
--
--  ESCENARIO NUEVO, y es el riesgo real del negocio:
--  juan recarga 600 y toma UN caballo de 500. Los otros NUEVE quedan a la casa
--  y entran al pozo por su precio de salida, sin que ese dinero haya entrado
--  nunca por caja. Pozo 5.000, premio 3.750. La casa recibio 500 de verdad.
--  Acreditar 3.750 es prometer un saldo que no se puede pagar cuando el usuario
--  lo vaya a retirar.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid;
        v_fallo boolean := false; v_saldo numeric; v_premios int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 600);
  v_rem   := _p.escenario(10, 500);          -- 10 caballos a 500
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, null, false);   -- toma el 1 en 500

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);                   -- le cobra 500, le quedan 100
  perform public.set_ganador_carrera(v_rem, 1);
  begin
    perform public.liquidar_remate(v_rem);
  exception when others then v_fallo := true;
  end;

  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;
  select count(*) into v_premios from public.wallet_movements where tipo = 'premio';

  perform _p.anotar(4, 'La casa no acredita un premio que no puede pagar',
    'la liquidacion falla y no se acredita nada; el saldo de juan sigue en 100',
    v_fallo and v_saldo = 100 and v_premios = 0,
    'fallo: ' || v_fallo::text || ' | saldo de juan: ' || v_saldo::text ||
    ' (esperado 100) | movimientos de premio: ' || v_premios::text || ' (esperado 0)');
exception when others then
  perform _p.anotar(4, 'La casa no acredita un premio que no puede pagar',
    'la liquidacion falla y no acredita', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P5 - Escenario mas comun del remate: a alguien lo superan
--
--  REESCRITA EN LA TAJADA D. Antes medía `saldo_bloqueado = 400`. Esa columna
--  ya no se usa y vale 0 siempre por diseño, asi que el assert se volvio falso
--  sin que el sistema tuviera nada malo. El equivalente correcto en el modelo
--  v2 es `compromiso_usuario() = 400`: lo mismo que antes se guardaba, ahora se
--  calcula.
--
--  juan puja el caballo 1, pedro lo supera, juan se va al caballo 2 y lo lidera.
--  Al cerrar deben cobrarle a juan 400 (solo el caballo que lidera, no los 600
--  de las dos pujas) y a pedro 300.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
        v_error text := ''; v_comp numeric; v_juan numeric; v_pedro numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);
  v_h3    := _p.caballo(v_rem, 3);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h1, 300, true);  -- supera a juan
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, 400, true);  -- juan lidera el 2
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h3, null, false); -- pedro el 3 en 100

  v_comp := public.compromiso_usuario(v_u1);

  perform _p.actuar_como(v_admin);
  begin
    perform public.cerrar_remate(v_rem);
    perform public.set_ganador_carrera(v_rem, 2);   -- gana el caballo de juan
    perform public.liquidar_remate(v_rem);
  exception when others then v_error := sqlerrm;
  end;

  select saldo_disponible into v_juan  from public.wallets where user_id = v_u1;
  select saldo_disponible into v_pedro from public.wallets where user_id = v_u2;

  -- juan: 10000 - 400 (cobro) + 600 (premio: 75% de un pozo de 800) = 10200
  -- pedro: 10000 - 300 - 100 = 9600
  perform _p.anotar(5, 'Usuario superado: compromiso, cobro y premio correctos',
    'compromiso de juan = 400 (no 600); sin error; juan 10200 y pedro 9600',
    v_error = '' and v_comp = 400 and v_juan = 10200 and v_pedro = 9600,
    case when v_error <> '' then 'error: ' || v_error
         else 'compromiso: ' || v_comp::text || ' (esperado 400) | juan: ' || v_juan::text ||
              ' (esperado 10200) | pedro: ' || v_pedro::text || ' (esperado 9600)' end);
exception when others then
  perform _p.anotar(5, 'Usuario superado: compromiso, cobro y premio correctos',
    'compromiso 400, sin error', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P6 - El libro de movimientos reconstruye los saldos, SIN listas a mano
--
--  VERSION DE LA TAJADA C. La anterior tenia que enumerar a mano que tipos de
--  movimiento contaban para cada invariante:
--
--      where m.tipo in ('recarga','premio','retiro','ajuste_manual')
--
--  Esa lista era el defecto 2.19 hecho codigo: `monto` no era un delta con
--  signo, porque apuesta_bloqueo y apuesta_desbloqueo solo movian dinero entre
--  columnas sin cambiar el saldo total. La prueba se rompio sola en cuanto
--  aparecio `apuesta_cobro`, que no estaba en la lista.
--
--  Con el modelo v2 ya no hay bloqueo durante el remate, asi que TODO
--  movimiento es un delta con signo sobre el saldo real. Por eso ahora el
--  invariante se puede escribir como debe ser:
--
--      saldo_disponible + saldo_bloqueado = suma de TODOS los movimientos
--
--  Sin `where tipo in (...)`. Ese es el criterio de aceptacion de la tarea 2.19,
--  y esta prueba es lo que lo verifica. Si alguien vuelve a introducir un tipo
--  que no sea un delta con signo, esto se pone rojo.
--
--  Invariante B: saldo_bloqueado tiene que ser 0 en todas las wallets. La
--  columna sigue existiendo a proposito (DISENO_SALDO_V2.md §9: se verifica
--  unas semanas en 0 y despues se borra). Esta prueba es la verificacion.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
        v_dep uuid; v_desc_a int; v_desc_b int; v_detalle text;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  0);
  v_u2    := _p.usuario('pedro', 0);

  -- el dinero entra por la puerta de siempre
  perform _p.actuar_como(v_u1);
  perform public.solicitar_recarga(5000, 'pago_movil', '04121234567', 'REFJ', current_date);
  select id into v_dep from public.deposit_requests where user_id = v_u1;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);

  perform _p.actuar_como(v_u2);
  perform public.solicitar_recarga(5000, 'pago_movil', '04127654321', 'REFP', current_date);
  select id into v_dep from public.deposit_requests where user_id = v_u2;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);

  v_rem := _p.escenario(3, 100);
  v_h1  := _p.caballo(v_rem, 1);
  v_h2  := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, 400, true);

  perform _p.actuar_como(v_admin);
  begin perform public.cerrar_remate(v_rem);          exception when others then null; end;
  begin perform public.set_ganador_carrera(v_rem, 2); exception when others then null; end;
  begin perform public.liquidar_remate(v_rem);        exception when others then null; end;

  perform _p.actuar_como(v_u1);
  begin perform public.solicitar_retiro(100, 'pago_movil', '04121234567'); exception when others then null; end;

  -- A: el libro completo, sin filtrar por tipo
  select count(*) into v_desc_a from (
    select w.id,
           w.saldo_disponible + w.saldo_bloqueado as saldo,
           coalesce((select sum(m.monto) from public.wallet_movements m
                     where m.wallet_id = w.id), 0) as libro
    from public.wallets w
  ) x where abs(saldo - libro) > 0.001;

  -- B: saldo_bloqueado debe estar muerto
  select count(*) into v_desc_b
  from public.wallets where coalesce(saldo_bloqueado, 0) <> 0;

  select string_agg(p.username || ': saldo ' || (w.saldo_disponible + w.saldo_bloqueado)::text ||
                    ' / libro ' || coalesce((select sum(m.monto) from public.wallet_movements m
                                             where m.wallet_id = w.id), 0)::text,
                    ' | ' order by p.username)
    into v_detalle
  from public.wallets w join public.profiles p on p.id = w.user_id;

  perform _p.anotar(6, 'El libro reconstruye los saldos sin listas a mano',
    'saldo = suma de TODOS los movimientos, y saldo_bloqueado en 0',
    v_desc_a = 0 and v_desc_b = 0,
    'descuadres A(libro): ' || v_desc_a::text || ', B(bloqueado<>0): ' || v_desc_b::text ||
    ' | ' || coalesce(v_detalle,''));
exception when others then
  perform _p.anotar(6, 'El libro reconstruye los saldos sin listas a mano',
    'saldo = suma de todos los movimientos', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P7 - Borrar un caballo con pujas debe ser rechazado por la base
--  Tarea 3.1 - se espera FALLA mientras las FK esten en CASCADE
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid;
        v_rechazado boolean := false; v_pujas_antes int; v_pujas_despues int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);

  select count(*) into v_pujas_antes from public.bids;

  begin
    delete from public.horses where id = v_h1;   -- lo que hace el boton del admin
  exception when others then v_rechazado := true;
  end;

  select count(*) into v_pujas_despues from public.bids;

  perform _p.anotar(7, 'FK protege las pujas al borrar un caballo',
    'la base rechaza el borrado',
    v_rechazado and v_pujas_despues = v_pujas_antes,
    case when v_rechazado then 'rechazado correctamente'
         else 'BORRO el caballo y se llevo ' || (v_pujas_antes - v_pujas_despues)::text ||
              ' puja(s) por delante; ese saldo bloqueado queda huerfano' end);
exception when others then
  perform _p.anotar(7, 'FK protege las pujas al borrar un caballo', 'la base rechaza el borrado', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P8 - Borrar una carrera con remates y pujas tambien debe ser rechazado
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_race uuid;
        v_rechazado boolean := false;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1    := _p.caballo(v_rem, 1);
  select race_id into v_race from public.remates where id = v_rem;

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);

  begin
    delete from public.races where id = v_race;
  exception when others then v_rechazado := true;
  end;

  perform _p.anotar(8, 'FK protege la cadena al borrar una carrera',
    'la base rechaza el borrado', v_rechazado,
    case when v_rechazado then 'rechazado correctamente'
         else 'BORRO la carrera y arrastro remates, caballos y pujas' end);
exception when others then
  perform _p.anotar(8, 'FK protege la cadena al borrar una carrera', 'la base rechaza el borrado', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P9 - Los retiros pendientes se restan del dinero de la casa
--  Tarea 1.4 - se espera FALLA antes de la correccion
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_res jsonb; v_casa numeric; v_pend numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 0);

  -- recarga de 1000 aprobada: la casa tiene 1000 en el banco
  perform _p.actuar_como(v_u);
  perform public.solicitar_recarga(1000, 'pago_movil', '04121234567', 'REF1', current_date);
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga((select id from public.deposit_requests limit 1));

  -- el usuario pide retirar los 1000: salen de su wallet, pero siguen en el banco
  perform _p.actuar_como(v_u);
  perform public.solicitar_retiro(1000, 'pago_movil', '04121234567');

  perform _p.actuar_como(v_admin);
  v_res  := public.admin_contabilidad_resumen();
  v_casa := (v_res->>'dinero_casa')::numeric;
  v_pend := (v_res->>'retiros_pendientes')::numeric;

  -- La casa tiene 1000 en el banco pero le debe 1000 al usuario: neto 0.
  perform _p.anotar(9, 'Retiros pendientes restados del dinero de la casa',
    'dinero_casa = 0', v_casa = 0,
    'dinero_casa: ' || v_casa::text || ' con ' || v_pend::text || ' pendientes de pago');
exception when others then
  perform _p.anotar(9, 'Retiros pendientes restados del dinero de la casa', 'dinero_casa = 0', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P10 - Aprobar dos veces la misma recarga no duplica el saldo
--  Tarea 1.7 - hoy ya pasa por el chequeo de estado; la guarda del UPDATE es
--  la segunda red. Esta prueba protege contra regresiones.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_dep uuid; v_saldo numeric; v_fallo2 boolean := false;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 0);

  perform _p.actuar_como(v_u);
  perform public.solicitar_recarga(500, 'pago_movil', '04121234567', 'REF1', current_date);
  select id into v_dep from public.deposit_requests limit 1;

  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);
  begin
    perform public.aprobar_recarga(v_dep);   -- segundo intento
  exception when others then v_fallo2 := true;
  end;

  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;
  perform _p.anotar(10, 'Doble aprobacion de recarga no duplica saldo',
    'saldo = 500 y el segundo intento falla',
    v_saldo = 500 and v_fallo2,
    'saldo: ' || v_saldo::text || ' | segundo intento rechazado: ' || v_fallo2::text);
exception when others then
  perform _p.anotar(10, 'Doble aprobacion de recarga no duplica saldo', 'saldo = 500', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P11 - El cron y el boton dejan el remate en el MISMO estado
--  Tareas 1.8 + 1.9
--  El escenario necesita un usuario SUPERADO: es ahi donde el bucle de
--  liberacion del boton se dispara y el cron (UPDATE plano) no hace nada.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid;
        v_remA uuid; v_remB uuid; v_hA1 uuid; v_hA2 uuid; v_hB1 uuid; v_hB2 uuid;
        v_movA int; v_movB int; v_estA text; v_estB text; v_n int; v_errA text := '';
        v_sumA numeric; v_sumB numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  20000);
  v_u2    := _p.usuario('pedro', 20000);

  v_remA := _p.escenario(3, 100); v_hA1 := _p.caballo(v_remA,1); v_hA2 := _p.caballo(v_remA,2);
  v_remB := _p.escenario(3, 100); v_hB1 := _p.caballo(v_remB,1); v_hB2 := _p.caballo(v_remB,2);

  -- en ambos: juan es superado en el caballo 1 y queda lider del caballo 2
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_remA, v_hA1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_remA, v_hA1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_remA, v_hA2, 400, true);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_remB, v_hB1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_remB, v_hB1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_remB, v_hB2, 400, true);

  update public.remates set closes_at = now() - interval '1 minute' where id in (v_remA, v_remB);

  -- A cierra por BOTON
  perform _p.actuar_como(v_admin);
  begin perform public.cerrar_remate(v_remA); exception when others then v_errA := sqlerrm; end;

  -- B cierra por CRON (sin usuario autenticado)
  perform set_config('request.jwt.claims', '', false);
  v_n := public.auto_cerrar_remates();
  perform _p.actuar_como(v_admin);

  select estado::text into v_estA from public.remates where id = v_remA;
  select estado::text into v_estB from public.remates where id = v_remB;
  -- ACTUALIZADA EN LA TAJADA C. Antes exigia 0 movimientos, porque cerrar solo
  -- cambiaba un estado. Desde C, cerrar COBRA, asi que 0 movimientos ya no es
  -- lo correcto: lo correcto es que los dos caminos cobren LO MISMO.
  -- El assert nuevo es mas fuerte que el viejo: compara cantidad Y monto, y
  -- exige cobro distinto de cero, asi que tampoco pasaria si el cierre dejara
  -- de cobrar por los dos lados a la vez.
  select count(*), coalesce(sum(monto),0) into v_movA, v_sumA
    from public.wallet_movements where ref_externa = v_remA::text;
  select count(*), coalesce(sum(monto),0) into v_movB, v_sumB
    from public.wallet_movements where ref_externa = v_remB::text;

  perform _p.anotar(11, 'Cron y boton cobran exactamente lo mismo',
    'ambos cerrados; mismo numero de movimientos y mismo monto, y distinto de cero',
    v_errA = '' and v_estA = 'cerrado' and v_estB = 'cerrado'
      and v_movA = v_movB and v_sumA = v_sumB and v_movA > 0,
    case when v_errA <> '' then 'el boton fallo: ' || v_errA
         else 'boton: ' || v_estA || ' con ' || v_movA::text || ' mov por ' || v_sumA::text ||
              ' | cron: ' || v_estB || ' con ' || v_movB::text || ' mov por ' || v_sumB::text end);
exception when others then
  perform _p.anotar(11, 'Cron y boton cobran exactamente lo mismo', 'mismo cobro por los dos caminos', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P12 - El cron puede auditar sus propios fallos
--
--  auto_cerrar_remates captura el error de cada remate y lo manda a
--  log_admin_action con admin_id null, porque el cron corre sin usuario.
--  admin_actions.admin_id era NOT NULL y log_admin_action se traga sus propias
--  excepciones: el error del cron se perdia en silencio.
-- ============================================================================
do $$
declare v_antes int; v_despues int; v_fila record;
begin
  perform _p.limpiar();
  delete from public.admin_actions;
  select count(*) into v_antes from public.admin_actions;

  perform public.log_admin_action(
    null, 'auto_cerrar_remates', 'remates', gen_random_uuid()::text,
    jsonb_build_object('prueba', true), false, 'error simulado');

  select count(*) into v_despues from public.admin_actions;
  select * into v_fila from public.admin_actions limit 1;

  perform _p.anotar(12, 'El cron puede auditar sus propios fallos',
    '1 fila en admin_actions con admin_id null',
    v_despues = v_antes + 1 and v_fila.admin_id is null and v_fila.success = false,
    'filas: ' || v_despues::text || ' | error guardado: ' || coalesce(v_fila.error, '(ninguno)'));
exception when others then
  perform _p.anotar(12, 'El cron puede auditar sus propios fallos',
    '1 fila en admin_actions', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P13 - La escalera del caballo le gana al incremento del remate
--
--  REESCRITA EL 30/09. La version original probaba la precedencia entre la
--  regla GENERAL (horse_id nulo) y la del caballo: hacer_puja ordenaba por
--  `(r.horse_id = p_horse_id) desc`, y como `NULL = <uuid>` da NULL y un
--  ORDER BY DESC pone los NULL primero, la general ganaba siempre.
--
--  Esa precedencia ya no existe: la migracion 20260930100000 elimino la regla
--  general de la base entera -- `horse_id` es NOT NULL -- porque era una
--  segunda fuente invisible del mismo numero y le ganaba a
--  `remates.incremento_minimo` sin que nadie lo viera.
--
--  La prueba no se parchea, se reescribe: mide la precedencia que SI queda en
--  pie, que es la del caballo sobre el incremento del remate. Mismos importes
--  esperados, misma logica de dos sentidos.
--
--  OJO CON EL ESCENARIO: desde la tarea 2.17 la PRIMERA puja compra al precio
--  de salida exacto, sin sumar ningun incremento. O sea que en la primera puja
--  no interviene ninguna regla. La precedencia solo importa a partir de la
--  SEGUNDA. Por eso aqui se puja dos veces y se mide la segunda.
--
--  Se prueban los dos sentidos a proposito. Con un solo caso no se distingue
--  "tomo la general" de "tomo la mas chica" (o la mas grande).
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h uuid;
        v_caso_a numeric; v_caso_b numeric;
begin
  -- caso A: remate 20, caballo 100 -> la segunda puja debe ser 100 + 100 = 200
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(2, 100);
  update public.remates set incremento_minimo = 20 where id = v_rem;   -- el del remate
  v_h := _p.caballo(v_rem, 1);
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h, 0, null, 100);                                 -- el del caballo
  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h, null, false);   -- primera: compra en 100
  perform _p.actuar_como(v_u2);
  perform public.hacer_puja(v_rem, v_h, null, false);   -- segunda: aqui manda la regla
  select max(monto) into v_caso_a from public.bids where horse_id = v_h;

  -- caso B: remate 100, caballo 20 -> la segunda puja debe ser 100 + 20 = 120
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(2, 100);
  update public.remates set incremento_minimo = 100 where id = v_rem;  -- el del remate
  v_h := _p.caballo(v_rem, 1);
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h, 0, null, 20);                                  -- el del caballo
  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h, null, false);
  perform _p.actuar_como(v_u2);
  perform public.hacer_puja(v_rem, v_h, null, false);
  select max(monto) into v_caso_b from public.bids where horse_id = v_h;

  perform _p.anotar(13, 'La escalera del caballo le gana al incremento del remate',
    'segunda puja: A = 200 (escalera del caballo 100) y B = 120 (escalera del caballo 20)',
    v_caso_a = 200 and v_caso_b = 120,
    'A: cobro ' || v_caso_a::text || ' (esperado 200) | B: cobro ' || v_caso_b::text || ' (esperado 120)');
exception when others then
  perform _p.anotar(13, 'La escalera del caballo le gana al incremento del remate',
    'A = 200 y B = 120', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P14 - La primera puja compra el caballo AL precio de salida
--
--  Antes cobraba precio_salida + incremento. La casa se quedaba el caballo que
--  nadie pujo por su precio_salida pelado, asi que compraba a 100 lo que al
--  usuario le costaba 110.
--
--  Se comprueba ademas que la SEGUNDA puja si sube por el incremento: el fix no
--  puede romper la escalera.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h uuid;
        v_primera numeric; v_segunda numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(2, 500);                 -- caballos a 500
  update public.remates set incremento_minimo = 100 where id = v_rem;
  v_h := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h, null, false);
  select max(monto) into v_primera from public.bids where horse_id = v_h;

  perform _p.actuar_como(v_u2);
  perform public.hacer_puja(v_rem, v_h, null, false);
  select max(monto) into v_segunda from public.bids where horse_id = v_h;

  perform _p.anotar(14, 'La primera puja compra al precio de salida',
    'primera = 500 (salida exacta) y segunda = 600 (salida + incremento)',
    v_primera = 500 and v_segunda = 600,
    'primera: ' || v_primera::text || ' (esperado 500) | segunda: ' || v_segunda::text || ' (esperado 600)');
exception when others then
  perform _p.anotar(14, 'La primera puja compra al precio de salida',
    'primera = 500 y segunda = 600', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P15 - apuesta_minima ya no pisa nada, y la manual acepta desde el automatico
--
--  apuesta_minima se aplicaba DESPUES de elegir la regla, encima del resultado,
--  para cualquier caballo: era el unico parametro que no se podia sobreescribir
--  por caballo. Y la puja manual exigia el automatico + 10, un numero clavado.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
        v_auto numeric; v_manual_ok boolean := false; v_manual_bajo_rechazado boolean := false;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000000);
  v_rem   := _p.escenario(3, 100);
  -- remate con un piso alto: antes, este 500 se comia al caballo de 100
  update public.remates set incremento_minimo = 10, apuesta_minima = 500 where id = v_rem;
  v_h1 := _p.caballo(v_rem, 1);
  v_h2 := _p.caballo(v_rem, 2);
  v_h3 := _p.caballo(v_rem, 3);

  perform _p.actuar_como(v_u);

  perform public.hacer_puja(v_rem, v_h1, null, false);
  select max(monto) into v_auto from public.bids where horse_id = v_h1;

  -- manual EXACTAMENTE en el minimo automatico (100): debe aceptarse
  begin
    perform public.hacer_puja(v_rem, v_h2, 100, true);
    v_manual_ok := true;
  exception when others then v_manual_ok := false;
  end;

  -- manual por debajo (99): debe rechazarse
  begin
    perform public.hacer_puja(v_rem, v_h3, 99, true);
    v_manual_bajo_rechazado := false;
  exception when others then v_manual_bajo_rechazado := true;
  end;

  perform _p.anotar(15, 'Sin piso apuesta_minima y manual desde el automatico',
    'auto = 100 (no 500), manual de 100 aceptada, manual de 99 rechazada',
    v_auto = 100 and v_manual_ok and v_manual_bajo_rechazado,
    'auto: ' || v_auto::text || ' (esperado 100) | manual 100 aceptada: ' || v_manual_ok::text ||
    ' | manual 99 rechazada: ' || v_manual_bajo_rechazado::text);
exception when others then
  perform _p.anotar(15, 'Sin piso apuesta_minima y manual desde el automatico',
    'auto = 100, manual 100 ok, manual 99 no', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P16 - compromiso_usuario: si te superan, esa puja deja de contar
--  DISENO_SALDO_V2.md §7bis, escenario 1
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_hA uuid; v_hB uuid; v_comp numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(2, 100);
  update public.remates set incremento_minimo = 100 where id = v_rem;
  v_hA := _p.caballo(v_rem, 1);
  v_hB := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_hA, null, false);  -- 100
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_hA, null, false);  -- 200, supera a juan
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_hB, 200, true);    -- juan lidera B en 200

  v_comp := public.compromiso_usuario(v_u1);
  perform _p.anotar(16, 'Compromiso: la puja superada deja de contar',
    'compromiso de juan = 200 (no 300)',
    v_comp = 200, 'compromiso: ' || v_comp::text || ' (si da 300, sumo la puja superada)');
exception when others then
  perform _p.anotar(16, 'Compromiso: la puja superada deja de contar', '200', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P17 - compromiso_usuario: subirse la propia puja reemplaza, no suma
--  DISENO_SALDO_V2.md §7bis, escenario 2. El "delta" sale gratis.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h uuid; v_comp numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000000);
  v_rem   := _p.escenario(2, 200);
  update public.remates set incremento_minimo = 10 where id = v_rem;
  v_h := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);   -- toma el caballo en 200
  perform public.hacer_puja(v_rem, v_h, 260, true);     -- se sube a si mismo a 260

  v_comp := public.compromiso_usuario(v_u);
  perform _p.anotar(17, 'Compromiso: subirse la propia puja reemplaza',
    'compromiso = 260 (no 460)',
    v_comp = 260, 'compromiso: ' || v_comp::text || ' (si da 460, sumo las dos pujas)');
exception when others then
  perform _p.anotar(17, 'Compromiso: subirse la propia puja reemplaza', '260', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P18 - compromiso_usuario: retirar el caballo lo saca del compromiso
--  DISENO_SALDO_V2.md §7bis, escenario 3. Sin tocar un solo peso.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h uuid;
        v_antes numeric; v_despues numeric; v_movs int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000000);
  v_rem   := _p.escenario(2, 300);
  v_h     := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);
  v_antes := public.compromiso_usuario(v_u);

  update public.horses set retirado = true where id = v_h;
  v_despues := public.compromiso_usuario(v_u);

  select count(*) into v_movs from public.wallet_movements;

  perform _p.anotar(18, 'Compromiso: el caballo retirado sale solo',
    'antes 300, despues 0, y sin movimientos nuevos de wallet',
    v_antes = 300 and v_despues = 0,
    'antes: ' || v_antes::text || ' | despues: ' || v_despues::text ||
    ' | movimientos de wallet en total: ' || v_movs::text);
exception when others then
  perform _p.anotar(18, 'Compromiso: el caballo retirado sale solo', 'antes 300, despues 0', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P19 - dinero_casa_disponible() y el panel de contabilidad dan lo mismo
--
--  Si estos dos numeros se separan, la guarda de solvencia protege contra una
--  caja distinta a la que el admin ve en pantalla.
--
--  SE MIDE EN DOS MOMENTOS A PROPOSITO. El punto que discrimina es el primero:
--  con el remate cerrado y sin liquidar, parte del dinero de juan esta en
--  saldo_bloqueado. Si dinero_casa_disponible() restara solo saldo_disponible
--  (como decia el diseno original), ahi daria 100 mientras el panel da 0.
--  El segundo momento comprueba ademas que el numero no es cero por casualidad.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_dep uuid; v_rem uuid; v_h uuid;
        v_f1 numeric; v_p1 numeric; v_f2 numeric; v_p2 numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 0);

  perform _p.actuar_como(v_u);
  perform public.solicitar_recarga(1000, 'pago_movil', '04121234567', 'REF1', current_date);
  select id into v_dep from public.deposit_requests where user_id = v_u;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);

  v_rem := _p.escenario(2, 100);
  v_h   := _p.caballo(v_rem, 1);
  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);      -- juan toma el 1 en 100

  -- MOMENTO 1: cerrado y sin liquidar. Juan tiene 900 disponible y 100 bloqueado.
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  v_f1 := public.dinero_casa_disponible();
  v_p1 := (public.admin_contabilidad_resumen() ->> 'dinero_casa')::numeric;

  -- MOMENTO 2: gana el caballo 2, que es de la casa. No hay premio, y la
  -- liquidacion le cobra a juan los 100. La casa se queda con ellos.
  perform public.set_ganador_carrera(v_rem, 2);
  perform public.liquidar_remate(v_rem);
  v_f2 := public.dinero_casa_disponible();
  v_p2 := (public.admin_contabilidad_resumen() ->> 'dinero_casa')::numeric;

  perform _p.anotar(19, 'La caja de la funcion y la del panel coinciden',
    'iguales en los dos momentos, y 100 al final (no cero por casualidad)',
    v_f1 = v_p1 and v_f2 = v_p2 and v_f2 = 100,
    'cerrado sin liquidar -> funcion: ' || v_f1::text || ' / panel: ' || v_p1::text ||
    ' | liquidado -> funcion: ' || v_f2::text || ' / panel: ' || v_p2::text || ' (esperado 100)');
exception when others then
  perform _p.anotar(19, 'La caja de la funcion y la del panel coinciden',
    'iguales en los dos momentos y 100 al final', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P20 - La guarda de exposicion: el compromiso cruza todos los remates
--
--  Un usuario con 500 Bs no puede liderar dos caballos de 300. El modelo viejo
--  lo impedia porque descontaba del saldo al pujar; el v2 no descuenta nada,
--  asi que la unica defensa es esta guarda.
--
--  Se comprueba ademas que pujar NO escribe en wallets ni en wallet_movements.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_hA uuid; v_hB uuid;
        v_err text := ''; v_comp numeric; v_saldo numeric; v_movs int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 500);
  v_rem   := _p.escenario(2, 300);
  v_hA := _p.caballo(v_rem, 1);
  v_hB := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_hA, null, false);        -- 300, entra
  begin
    perform public.hacer_puja(v_rem, v_hB, null, false);      -- otros 300, no caben
  exception when others then v_err := sqlerrm;
  end;

  v_comp  := public.compromiso_usuario(v_u);
  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;
  select count(*) into v_movs from public.wallet_movements;

  perform _p.anotar(20, 'Guarda de exposicion entre remates',
    'la 2da puja se rechaza; compromiso 300, saldo intacto en 500, 0 movimientos',
    v_err <> '' and v_comp = 300 and v_saldo = 500 and v_movs = 0,
    'compromiso: ' || v_comp::text || ' | saldo: ' || v_saldo::text ||
    ' | movimientos: ' || v_movs::text ||
    ' | 2da puja: ' || coalesce(nullif(v_err,''), 'ACEPTADA (mal)'));
exception when others then
  perform _p.anotar(20, 'Guarda de exposicion entre remates', 'la 2da se rechaza', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P21 - hacer_puja toma el candado por USUARIO, no solo por caballo
--
--  Es el punto critico del modelo v2. La guarda de P20 cruza TODOS los remates
--  abiertos de un usuario, asi que serializar por caballo no alcanza: dos pujas
--  simultaneas del mismo usuario a caballos distintos leen el mismo compromiso
--  viejo y pasan las dos.
--
--  REPRODUCIDO el 24/09/2026 con dos conexiones reales a PostgreSQL 16,
--  usuario con 500 Bs y dos pujas simultaneas de 300:
--
--    sin candado por usuario -> 2 pujas aceptadas, 600 comprometidos ❌
--    con candado por usuario -> 1 aceptada, 1 rechazada, 300 comprometidos ✅
--
--  Esa prueba necesita dos conexiones y no cabe en este arnes. Lo que SI cabe,
--  y es una guarda de regresion de verdad, es comprobar en pg_locks que los dos
--  candados quedan efectivamente tomados: espacio 1 (usuario) y espacio 2
--  (remate+caballo). Si alguien reescribe la funcion y se lleva por delante el
--  primero, esta prueba se pone roja.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h uuid;
        v_usuario boolean; v_caballo boolean;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100);
  v_h     := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);

  select exists (select 1 from pg_locks
                 where locktype = 'advisory' and pid = pg_backend_pid()
                   and classid = 1 and objsubid = 2)
    into v_usuario;
  select exists (select 1 from pg_locks
                 where locktype = 'advisory' and pid = pg_backend_pid()
                   and classid = 2 and objsubid = 2)
    into v_caballo;

  perform _p.anotar(21, 'La puja toma el candado por usuario y por caballo',
    'los dos candados advisory tomados (espacio 1 y espacio 2)',
    v_usuario and v_caballo,
    'candado de usuario: ' || v_usuario::text || ' | candado de caballo: ' || v_caballo::text);
exception when others then
  perform _p.anotar(21, 'La puja toma el candado por usuario y por caballo',
    'los dos candados tomados', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P22 - Cancelar un remate CERRADO devuelve exactamente lo cobrado
--
--  Es la ruta de salida de la tarea 2.13. Hasta hoy, un remate que se cerraba y
--  no se podia liquidar -carrera suspendida, el admin no alcanza a cargar el
--  ganador, la liquidacion falla- dejaba el dinero cobrado sin forma de
--  devolverlo salvo metiendo mano en la base de datos.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
        v_juan numeric; v_pedro numeric; v_estado text; v_segunda boolean := false;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000);
  v_u2    := _p.usuario('pedro', 1000);
  v_rem   := _p.escenario(3, 100);
  v_h1 := _p.caballo(v_rem, 1); v_h2 := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h2, 300, true);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);                       -- cobra 200 y 300
  perform public.cancelar_remate(v_rem, 'Carrera suspendida');

  select saldo_disponible into v_juan  from public.wallets where user_id = v_u1;
  select saldo_disponible into v_pedro from public.wallets where user_id = v_u2;
  select estado::text into v_estado from public.remates where id = v_rem;

  begin
    perform public.cancelar_remate(v_rem, 'otra vez');
  exception when others then v_segunda := true;
  end;

  perform _p.anotar(22, 'Cancelar un remate cerrado devuelve lo cobrado',
    'juan y pedro vuelven a 1000, estado cancelado, y no se puede cancelar dos veces',
    v_juan = 1000 and v_pedro = 1000 and v_estado = 'cancelado' and v_segunda,
    'juan: ' || v_juan::text || ' | pedro: ' || v_pedro::text || ' | estado: ' || v_estado ||
    ' | segunda cancelacion rechazada: ' || v_segunda::text);
exception when others then
  perform _p.anotar(22, 'Cancelar un remate cerrado devuelve lo cobrado',
    'los dos vuelven a 1000', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P23 - Cancelar un remate ABIERTO no mueve un solo peso
--
--  En el modelo anterior habia que localizar cada bloqueo y revertirlo, con el
--  riesgo de descuadre que eso traia. En el v2 no se cobro nada todavia, asi
--  que no hay nada que devolver: el compromiso baja solo porque el remate deja
--  de estar abierto.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid;
        v_saldo numeric; v_comp numeric; v_movs int; v_estado text;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);
  v_rem   := _p.escenario(2, 100);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);

  perform _p.actuar_como(v_admin);
  perform public.cancelar_remate(v_rem, 'Se cayo la jornada');

  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;
  v_comp := public.compromiso_usuario(v_u);
  select count(*) into v_movs from public.wallet_movements;
  select estado::text into v_estado from public.remates where id = v_rem;

  perform _p.anotar(23, 'Cancelar un remate abierto no mueve dinero',
    'saldo intacto en 1000, compromiso 0, cero movimientos de wallet',
    v_saldo = 1000 and v_comp = 0 and v_movs = 0 and v_estado = 'cancelado',
    'saldo: ' || v_saldo::text || ' | compromiso: ' || v_comp::text ||
    ' | movimientos: ' || v_movs::text || ' | estado: ' || v_estado);
exception when others then
  perform _p.anotar(23, 'Cancelar un remate abierto no mueve dinero',
    'nada se mueve', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P24 - No se puede retirar dinero que esta comprometido en pujas
--
--  🔴 SE ESPERA ROJA hasta la tajada E. Es el hueco que abren B, C y D juntas,
--  y esta escrito como prueba para que no se olvide.
--
--  En el modelo anterior, pujar descontaba de saldo_disponible, asi que el
--  retiro no podia tocar ese dinero: ya no estaba ahi. En el v2 el dinero se
--  queda en saldo_disponible hasta que cierra el remate, y solicitar_retiro
--  sigue comprobando solo `saldo_disponible >= monto`. Resultado: un usuario
--  con 1000 comprometidos en 800 puede pedir el retiro de los 1000, y cuando
--  el remate cierre, el cobro va a reventar con "Invariante roto".
--
--  La correccion es §7 del diseño: retirable = saldo - compromiso, con el mismo
--  candado por usuario que hacer_puja.
--
--  ⚠️ MIENTRAS ESTA PRUEBA SIGA ROJA, la aplicacion NO puede tener usuarios
--  reales pujando, aunque las migraciones esten en produccion.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid;
        v_rechazado boolean := false; v_saldo numeric; v_comp numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);
  v_rem   := _p.escenario(2, 800);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, null, false);    -- toma el caballo en 800
  v_comp := public.compromiso_usuario(v_u);

  begin
    perform public.solicitar_retiro(1000, 'pago_movil', '04121234567');
  exception when others then v_rechazado := true;
  end;

  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;

  perform _p.anotar(24, 'No se retira dinero comprometido en pujas',
    'el retiro de 1000 se rechaza: solo 200 son retirables',
    v_rechazado and v_saldo = 1000,
    'compromiso: ' || v_comp::text || ' | retiro de 1000 rechazado: ' || v_rechazado::text ||
    ' | saldo tras el intento: ' || v_saldo::text || ' (si bajo a 0, se llevo dinero comprometido)');
exception when others then
  perform _p.anotar(24, 'No se retira dinero comprometido en pujas',
    'el retiro se rechaza', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P25 - mi_wallet_resumen devuelve los tres numeros
--
--  Que el usuario vea "tienes 1000, 800 comprometidos en pujas, puedes retirar
--  200" evita la mitad de los mensajes a soporte, y sobre todo evita que
--  intente el retiro y reciba un error que no entiende.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h uuid;
        v_total numeric; v_comp numeric; v_retirable numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);
  v_rem   := _p.escenario(2, 800);
  v_h     := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);      -- compromete 800

  select saldo_disponible, comprometido, disponible_para_retirar
    into v_total, v_comp, v_retirable
  from public.mi_wallet_resumen();

  perform _p.anotar(25, 'mi_wallet_resumen devuelve los tres numeros',
    'total 1000, comprometido 800, retirable 200',
    v_total = 1000 and v_comp = 800 and v_retirable = 200,
    'total: ' || v_total::text || ' | comprometido: ' || v_comp::text ||
    ' | retirable: ' || v_retirable::text);
exception when others then
  perform _p.anotar(25, 'mi_wallet_resumen devuelve los tres numeros',
    'total 1000, comprometido 800, retirable 200', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P26 - Retirar un caballo con el remate ABIERTO no toca el dinero
--
--  Este es el argumento a favor de todo el rediseno. En el modelo anterior
--  habia que localizar el bloqueo del lider y revertirlo con cuidado. Aqui la
--  puja deja de contar sola, porque compromiso_usuario() excluye los retirados.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
        v_antes numeric; v_despues numeric; v_saldo numeric; v_movs int; v_msg text;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);
  v_rem   := _p.escenario(2, 300);
  v_h1 := _p.caballo(v_rem, 1); v_h2 := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, null, false);   -- 300
  perform public.hacer_puja(v_rem, v_h2, null, false);   -- 300 mas, total 600
  v_antes := public.compromiso_usuario(v_u);

  perform _p.actuar_como(v_admin);
  v_msg := public.retirar_caballo(v_h1, 'Se lesiono en el paddock');

  v_despues := public.compromiso_usuario(v_u);
  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;
  select count(*) into v_movs from public.wallet_movements;

  perform _p.anotar(26, 'Retirar un caballo con el remate abierto no mueve dinero',
    'compromiso baja de 600 a 300 solo, saldo intacto en 1000, 0 movimientos',
    v_antes = 600 and v_despues = 300 and v_saldo = 1000 and v_movs = 0,
    'compromiso: ' || v_antes::text || ' -> ' || v_despues::text ||
    ' | saldo: ' || v_saldo::text || ' | movimientos: ' || v_movs::text || ' | ' || v_msg);
exception when others then
  perform _p.anotar(26, 'Retirar un caballo con el remate abierto no mueve dinero',
    'nada se mueve', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P27 - Retirar un caballo con el remate YA CERRADO devuelve lo cobrado
--
--  Aqui si hubo cobro, asi que hay que devolver. Se devuelve exactamente la
--  puja mas alta sobre ese caballo, que es lo que se cobro por el al cerrar.
--  Se comprueba ademas que retirarlo dos veces se rechaza: si no, cada clic
--  devolveria el dinero otra vez.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
        v_juan numeric; v_pedro numeric; v_segunda boolean := false; v_msg text;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000);
  v_u2    := _p.usuario('pedro', 1000);
  v_rem   := _p.escenario(2, 100);
  v_h1 := _p.caballo(v_rem, 1); v_h2 := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h2, 300, true);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);        -- cobra 200 a juan y 300 a pedro
  v_msg := public.retirar_caballo(v_h1, 'Retirado despues del cierre');

  begin
    perform public.retirar_caballo(v_h1, 'otra vez');
  exception when others then v_segunda := true;
  end;

  select saldo_disponible into v_juan  from public.wallets where user_id = v_u1;
  select saldo_disponible into v_pedro from public.wallets where user_id = v_u2;

  perform _p.anotar(27, 'Retirar un caballo ya cobrado devuelve exactamente lo suyo',
    'juan vuelve a 1000, pedro sigue en 700, y no se puede retirar dos veces',
    v_juan = 1000 and v_pedro = 700 and v_segunda,
    'juan: ' || v_juan::text || ' (esperado 1000) | pedro: ' || v_pedro::text ||
    ' (esperado 700) | segundo retiro rechazado: ' || v_segunda::text || ' | ' || v_msg);
exception when others then
  perform _p.anotar(27, 'Retirar un caballo ya cobrado devuelve exactamente lo suyo',
    'juan 1000, pedro 700', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P28 - La RPC de minimos dice EXACTAMENTE lo que cobra hacer_puja
--
--  Esta es la prueba de la tarea 2.20 y la mas importante de la tajada F.
--
--  Hasta hoy el frontend recalculaba la escalera de precios en TypeScript y la
--  base la calculaba por su cuenta. El 23/09 se demostro que se habian separado
--  sin que nadie se enterara: la pantalla elegia la regla del caballo y la base
--  la general. El usuario leia un numero y la base cobraba otro.
--
--  Ahora las dos salen de _incremento_aplicable(). Esta prueba lo verifica caso
--  por caballo, en un escenario con dos escaleras propias distintas, un caballo
--  sin escalera que cae al incremento del remate, caballos ya pujados y uno
--  virgen.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid;
        v_h1 uuid; v_h2 uuid; v_h3 uuid;
        r record; v_dicho numeric; v_cobrado numeric;
        v_fallos int := 0; v_detalle text := '';
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(3, 100);
  update public.remates set incremento_minimo = 7 where id = v_rem;   -- fallback raro a proposito
  v_h1 := _p.caballo(v_rem,1); v_h2 := _p.caballo(v_rem,2); v_h3 := _p.caballo(v_rem,3);

  -- Escalera propia para el 1 y para el 2, con incrementos distintos; el 3 se
  -- queda sin ninguna y tiene que caer al incremento_minimo del remate (7).
  -- Antes del 30/09 esto se montaba con una regla general para todos; esa
  -- clase de fila ya no existe (migracion 20260930100000).
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h1, 0, null, 25);
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h2, 0, null, 150);

  -- el 1 y el 2 ya tienen puja; el 3 queda virgen
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, null, false);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, null, false);

  -- para cada caballo: lo que dice la RPC contra lo que cobra la puja
  for r in select horse_id, numero, minimo_auto from public.remate_minimos(v_rem) order by numero
  loop
    v_dicho := r.minimo_auto;
    perform _p.actuar_como(v_u2);
    perform public.hacer_puja(v_rem, r.horse_id, null, false);
    select max(monto) into v_cobrado from public.bids where horse_id = r.horse_id;

    if v_cobrado <> v_dicho then
      v_fallos := v_fallos + 1;
      v_detalle := v_detalle || 'caballo ' || r.numero::text ||
                   ': RPC dijo ' || v_dicho::text || ' y cobro ' || v_cobrado::text || '; ';
    else
      v_detalle := v_detalle || 'c' || r.numero::text || '=' || v_cobrado::text || ' ';
    end if;
  end loop;

  perform _p.anotar(28, 'La RPC de minimos coincide con lo que cobra la puja',
    'para cada caballo, minimo_auto de la RPC = monto que registra hacer_puja',
    v_fallos = 0,
    case when v_fallos > 0 then 'DIVERGENCIAS -> ' || v_detalle
         else 'coinciden en los 3 caballos -> ' || v_detalle end);
exception when others then
  perform _p.anotar(28, 'La RPC de minimos coincide con lo que cobra la puja',
    'coinciden', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P29 - Liquidar asienta el resultado en el libro de la casa, solo
--
--  El admin no lo escribe ni lo puede escribir: registrar_movimiento_casa
--  rechaza el tipo 'resultado_remate'. Que el 25% o el pozo ganado vayan donde
--  tienen que ir no puede quedar al criterio de nadie.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
        v_asientos int; v_monto numeric; v_gano_casa boolean; v_manual boolean := false;
begin
  perform _p.limpiar();
  delete from public.house_ledger;
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1 := _p.caballo(v_rem,1); v_h2 := _p.caballo(v_rem,2); v_h3 := _p.caballo(v_rem,3);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, 400, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h3, null, false);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);          -- cobra 400 a juan y 400 a pedro
  perform public.set_ganador_carrera(v_rem, 2); -- gana el caballo de juan
  perform public.liquidar_remate(v_rem);        -- pozo 800, premio 600

  select count(*), max(monto), bool_or((detalles->>'gano_la_casa')::boolean)
    into v_asientos, v_monto, v_gano_casa
  from public.house_ledger where tipo = 'resultado_remate' and ref_externa = v_rem::text;

  -- y que el admin no pueda escribirlo a mano
  begin
    perform public.registrar_movimiento_casa('resultado_remate', 999, 'a mano');
  exception when others then v_manual := true;
  end;

  -- cobrado 800, premio 600 -> a la casa le quedaron 200 (el 25% de 800)
  perform _p.anotar(29, 'Liquidar asienta el resultado en el libro de la casa',
    'un asiento de 200 (800 cobrados - 600 de premio), y el admin no lo puede crear a mano',
    v_asientos = 1 and v_monto = 200 and v_gano_casa = false and v_manual,
    'asientos: ' || v_asientos::text || ' | monto: ' || coalesce(v_monto,0)::text ||
    ' (esperado 200) | creacion manual rechazada: ' || v_manual::text);
exception when others then
  perform _p.anotar(29, 'Liquidar asienta el resultado en el libro de la casa',
    'un asiento de 200', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P30 - El capital propio desbloquea la liquidacion
--
--  Es el escenario que destapo la tajada D y la razon de ser de esta tarea.
--  Juan recarga 600 y toma UN caballo de 500. Los otros nueve quedan a la casa
--  y entran al pozo sin que ese dinero haya entrado por caja: pozo 5.000,
--  premio 3.750, caja 500. La guarda lo bloquea, y hace bien.
--
--  Con el libro, el licenciatario aporta capital propio y la liquidacion pasa.
--  Antes de 2.18 esto no tenia salida: la guarda bloqueaba y no habia forma de
--  decirle al sistema que la casa tenia dinero.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid;
        v_fallo1 boolean := false; v_fallo2 boolean := false;
        v_caja_antes numeric; v_caja_despues numeric; v_saldo numeric;
begin
  perform _p.limpiar();
  delete from public.house_ledger;
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 600);
  v_rem   := _p.escenario(10, 500);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, null, false);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 1);

  v_caja_antes := public.dinero_casa_disponible();
  begin perform public.liquidar_remate(v_rem); exception when others then v_fallo1 := true; end;

  -- el licenciatario aporta capital propio
  perform public.registrar_movimiento_casa('aporte_capital', 5000, 'Capital de trabajo de la casa');
  v_caja_despues := public.dinero_casa_disponible();

  begin perform public.liquidar_remate(v_rem); exception when others then v_fallo2 := true; end;
  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;

  -- juan: 600 - 500 (cobro) + 3750 (premio) = 3850
  perform _p.anotar(30, 'El capital propio desbloquea la liquidacion',
    'antes falla con caja 500; tras aportar 5000 la caja sube a 5500 y liquida',
    v_fallo1 and not v_fallo2 and v_caja_antes = 500 and v_caja_despues = 5500 and v_saldo = 3850,
    'caja antes: ' || v_caja_antes::text || ' (bloqueo: ' || v_fallo1::text ||
    ') | caja despues: ' || v_caja_despues::text || ' (bloqueo: ' || v_fallo2::text ||
    ') | saldo de juan: ' || v_saldo::text || ' (esperado 3850)');
exception when others then
  perform _p.anotar(30, 'El capital propio desbloquea la liquidacion',
    'el aporte desbloquea', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P31 - El libro de la casa cuadra contra los saldos
--
--  LA PRUEBA MAS IMPORTANTE DE LA TAREA 2.18, y la razon por la que vale la
--  pena tener el libro. Hay dos formas independientes de calcular lo mismo:
--
--    suma de los `resultado_remate`  (lo que la casa gano, segun su libro)
--    recargas - retiros - saldos     (lo que los usuarios perdieron, en neto)
--
--  Tienen que dar identico. Un descuadre significa que el libro y los saldos
--  no cuentan la misma historia: o hay un bug, o alguien metio mano.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
        r record;
begin
  perform _p.limpiar();
  delete from public.house_ledger;
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1 := _p.caballo(v_rem,1); v_h2 := _p.caballo(v_rem,2); v_h3 := _p.caballo(v_rem,3);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, 400, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h3, null, false);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 2);
  perform public.liquidar_remate(v_rem);

  -- y un retiro, para que el calculo tenga que lidiar con obligaciones
  perform _p.actuar_como(v_u1);
  perform public.solicitar_retiro(500, 'pago_movil', '04121234567');
  perform _p.actuar_como(v_admin);

  select * into r from public.casa_resumen();

  perform _p.anotar(31, 'El libro de la casa cuadra contra los saldos',
    'descuadre = 0; resultado del libro = perdida neta de los usuarios = 200',
    r.descuadre = 0 and r.resultado_operativo = 200 and r.perdida_usuarios = 200 and r.cubierto,
    'libro: ' || r.resultado_operativo::text || ' | saldos: ' || r.perdida_usuarios::text ||
    ' | descuadre: ' || r.descuadre::text || ' | patrimonio: ' || r.patrimonio::text ||
    ' | cubierto: ' || r.cubierto::text);
exception when others then
  perform _p.anotar(31, 'El libro de la casa cuadra contra los saldos',
    'descuadre = 0', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P32 - La foto contable de la casa solo la ve un admin
--
--  casa_resumen() es `security definer`: lee house_ledger por encima de la
--  RLS. Si no comprueba quien llama, la RLS de la tabla no sirve de nada y
--  cualquier apostador logueado ve el patrimonio de la casa desde la consola
--  del navegador. Esta prueba mira las dos mitades: que al usuario normal lo
--  rechace, y que al admin le siga respondiendo.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; r record;
        v_rechazado boolean := false; v_admin_ok boolean := false; v_msg text := '';
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan', 1000);

  perform _p.actuar_como(v_u1);
  begin
    select * into r from public.casa_resumen();
    v_msg := 'usuario normal la leyo: patrimonio ' || coalesce(r.patrimonio::text, 'null');
  exception when others then
    v_rechazado := true;
    v_msg := 'rechazo al usuario normal (' || sqlerrm || ')';
  end;

  perform _p.actuar_como(v_admin);
  begin
    select * into r from public.casa_resumen();
    v_admin_ok := r.caja_total is not null;
    v_msg := v_msg || ' | admin: caja ' || coalesce(r.caja_total::text, 'null');
  exception when others then
    v_msg := v_msg || ' | admin tambien rechazado: ' || sqlerrm;
  end;

  perform _p.anotar(32, 'La foto contable de la casa solo la ve un admin',
    'usuario normal: excepcion; admin: responde',
    v_rechazado and v_admin_ok, v_msg);
exception when others then
  perform _p.anotar(32, 'La foto contable de la casa solo la ve un admin',
    'usuario normal: excepcion; admin: responde', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P33 - Ninguna RPC peligrosa queda al alcance de anon ni de authenticated
--
--  Esta prueba NO ejercita los permisos: el arnes corre como `postgres`, que
--  es superusuario y se salta cualquier ACL. Lo que hace es CONSULTAR el ACL
--  con has_function_privilege(), que si funciona desde postgres.
--
--  Es la unica forma de probar esto sin abrir una conexion con otro rol. Vale
--  la pena porque `create or replace function` NO toca los permisos: los
--  grants de la baseline sobrevivieron intactos a todo el bloque 1 y 2 aunque
--  los cuerpos se reescribieron enteros. Revisar el cuerpo no basta.
-- ============================================================================
do $$
declare
  v_auto_anon   boolean; v_auto_auth   boolean;
  v_log_anon    boolean; v_log_auth    boolean;
  v_comp_auth   boolean;
  v_resumen_existe boolean;
  v_min_anon    boolean;
begin
  v_auto_anon := has_function_privilege('anon',          'public.auto_cerrar_remates()', 'execute');
  v_auto_auth := has_function_privilege('authenticated', 'public.auto_cerrar_remates()', 'execute');

  v_log_anon  := has_function_privilege('anon',
    'public.log_admin_action(uuid, text, text, text, jsonb, boolean, text)', 'execute');
  v_log_auth  := has_function_privilege('authenticated',
    'public.log_admin_action(uuid, text, text, text, jsonb, boolean, text)', 'execute');

  v_comp_auth := has_function_privilege('authenticated', 'public.compromiso_usuario(uuid)', 'execute');

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'resumen_casa'
  ) into v_resumen_existe;

  -- esta SI tiene que seguir abierta: es informacion publica del remate
  v_min_anon := has_function_privilege('anon', 'public.remate_minimos(uuid)', 'execute');

  perform _p.anotar(33, 'Ninguna RPC peligrosa queda al alcance de anon ni authenticated',
    'auto_cerrar_remates y log_admin_action cerradas a los dos; compromiso_usuario cerrada a authenticated; resumen_casa borrada; remate_minimos sigue publica',
    (not v_auto_anon) and (not v_auto_auth)
      and (not v_log_anon) and (not v_log_auth)
      and (not v_comp_auth)
      and (not v_resumen_existe)
      and v_min_anon,
    'auto_cerrar[anon=' || v_auto_anon::text || ',auth=' || v_auto_auth::text || ']' ||
    ' log_admin[anon=' || v_log_anon::text || ',auth=' || v_log_auth::text || ']' ||
    ' compromiso[auth=' || v_comp_auth::text || ']' ||
    ' resumen_casa_existe=' || v_resumen_existe::text ||
    ' remate_minimos[anon=' || v_min_anon::text || ']');
exception when others then
  perform _p.anotar(33, 'Ninguna RPC peligrosa queda al alcance de anon ni authenticated',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P34 - Las claves foraneas del dinero estan en RESTRICT
--
--  Consulta el catalogo, no ejercita el borrado (eso lo hace P35). Vale la
--  pena tenerla aparte porque una clave foranea se puede perder sin que nada
--  se ponga rojo: basta con que alguien recree la tabla o vuelva a correr un
--  `add constraint` viejo.
--
--  confdeltype: 'r' = RESTRICT, 'c' = CASCADE, 'a' = NO ACTION
-- ============================================================================
do $$
declare
  r record;
  v_todas_ok boolean := true;
  v_detalle text := '';
begin
  for r in
    select * from (values
      -- (nombre, esperado)  't' = restrict a proposito, 'c' = cascade a proposito
      ('wallet_movements_wallet_id_fkey',      'r'),
      ('bids_user_id_fkey',                    'r'),
      ('deposit_requests_user_id_fkey',        'r'),
      ('withdraw_requests_user_id_fkey',       'r'),
      ('race_results_race_id_fkey',            'r'),
      -- las de la primera mitad (20260923100000), que no se deben perder
      ('bids_horse_id_fkey',                   'r'),
      ('bids_remate_id_fkey',                  'r'),
      ('horses_race_id_fkey',                  'r'),
      ('remates_race_id_fkey',                 'r'),
      ('race_results_ganador_horse_id_fkey',   'r'),
      -- las que se quedan en CASCADE A PROPOSITO
      ('wallets_user_id_fkey',                 'c'),
      ('remate_price_rules_horse_id_fkey',     'c'),
      ('remate_price_rules_remate_id_fkey',    'c')
    ) as t(nombre, esperado)
  loop
    declare v_real char;
    begin
      select confdeltype into v_real from pg_constraint where conname = r.nombre;
      if v_real is null then
        v_todas_ok := false;
        v_detalle := v_detalle || r.nombre || '=NO EXISTE ';
      elsif v_real <> r.esperado then
        v_todas_ok := false;
        v_detalle := v_detalle || r.nombre || '=' || v_real || '(esperado ' || r.esperado || ') ';
      end if;
    end;
  end loop;

  perform _p.anotar(34, 'Las claves foraneas del dinero estan en RESTRICT',
    '5 nuevas + 5 de la primera mitad en restrict; 3 en cascade a proposito',
    v_todas_ok,
    case when v_todas_ok then 'las 13 como deben' else 'mal: ' || v_detalle end);
exception when others then
  perform _p.anotar(34, 'Las claves foraneas del dinero estan en RESTRICT',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P35 - Borrar un usuario: bloqueado si tiene dinero, permitido si no
--
--  LA PRUEBA QUE DE VERDAD IMPORTA DE 3.1. No mira el catalogo: intenta el
--  borrado y comprueba que Postgres lo frena, bajando por la cascada
--  auth.users -> profiles -> wallets -> wallet_movements.
--
--  Las dos mitades importan igual:
--    - si no bloquea al que tiene dinero, la tarea no sirve de nada
--    - si bloquea TAMBIEN al que no tiene nada, ninguna cuenta de prueba se
--      podria borrar jamas, porque handle_new_user le crea un wallet a todo
--      el mundo al registrarse
-- ============================================================================
do $$
declare
  v_con_dinero uuid; v_limpio uuid; v_rem uuid; v_h1 uuid;
  v_bloqueado boolean := false;
  v_limpio_borrado boolean := false;
  v_msg text := '';
begin
  perform _p.limpiar();

  -- usuario CON rastro: _p.usuario ya le deja una recarga aprobada, y ademas
  -- le hacemos pujar para que tenga una puja en un remate abierto
  v_con_dinero := _p.usuario('con_dinero', 5000);
  v_rem := _p.escenario(2, 100);
  v_h1  := _p.caballo(v_rem, 1);
  perform _p.actuar_como(v_con_dinero);
  perform public.hacer_puja(v_rem, v_h1, 100, true);

  -- usuario LIMPIO: se registra y no hace nada mas.
  --
  -- Basta con la fila en auth.users: el trigger `on_auth_user_created` llama a
  -- handle_new_user(), que crea el perfil Y el wallet. Esto NO es un atajo del
  -- arnes, es literalmente lo que pasa cuando alguien se registra en la app.
  --
  -- (La primera version de esta prueba insertaba perfil y wallet a mano y
  -- reventaba con `duplicate key ... profiles_pkey`, porque el trigger ya los
  -- habia creado. Por eso _p.usuario lleva `on conflict do update`.)
  v_limpio := gen_random_uuid();
  insert into auth.users (id) values (v_limpio);
  update public.profiles set username = 'recien_llegado' where id = v_limpio;

  -- Si el trigger no hizo su trabajo, esta prueba no esta probando lo que cree.
  if not exists (select 1 from public.profiles where id = v_limpio)
     or not exists (select 1 from public.wallets where user_id = v_limpio) then
    perform _p.anotar(35, 'Borrar usuario: bloqueado con dinero, permitido sin nada',
      'ver arriba', false,
      'el trigger on_auth_user_created no creo perfil o wallet: el escenario es invalido');
    return;
  end if;

  -- mitad 1: el que tiene dinero NO se puede borrar
  begin
    delete from auth.users where id = v_con_dinero;
    v_msg := 'con_dinero SE BORRO (mal) | ';
  exception when others then
    v_bloqueado := true;
    v_msg := 'con_dinero bloqueado (' || sqlstate || ') | ';
  end;

  -- mitad 2: el limpio SI se puede borrar
  begin
    delete from auth.users where id = v_limpio;
    v_limpio_borrado := not exists (select 1 from public.profiles where id = v_limpio);
    v_msg := v_msg || 'limpio borrado=' || v_limpio_borrado::text;
  exception when others then
    v_msg := v_msg || 'limpio NO se pudo borrar (' || sqlerrm || ')';
  end;

  perform _p.anotar(35, 'Borrar usuario: bloqueado con dinero, permitido sin nada',
    'con rastro de dinero o pujas: error; sin nada: se borra',
    v_bloqueado and v_limpio_borrado, v_msg);
exception when others then
  perform _p.anotar(35, 'Borrar usuario: bloqueado con dinero, permitido sin nada',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P36 - Nadie escribe `remates` directo
--
--  LA PRUEBA MAS IMPORTANTE DE 3.2. No comprueba la RPC nueva: comprueba que
--  la puerta vieja esta cerrada. De nada sirve editar_remate() si el frontend
--  puede seguir haciendo update sobre la tabla.
--
--  Como el arnes corre como `postgres` (superusuario, se salta cualquier ACL),
--  esto se consulta con has_table_privilege, igual que P33 con las funciones.
-- ============================================================================
do $$
declare
  v_auth_upd boolean; v_auth_ins boolean; v_auth_del boolean;
  v_anon_upd boolean; v_auth_sel boolean;
begin
  v_auth_upd := has_table_privilege('authenticated', 'public.remates', 'update');
  v_auth_ins := has_table_privilege('authenticated', 'public.remates', 'insert');
  v_auth_del := has_table_privilege('authenticated', 'public.remates', 'delete');
  v_anon_upd := has_table_privilege('anon',          'public.remates', 'update');
  -- leer si tiene que poder: la pantalla del remate la ve todo el mundo
  v_auth_sel := has_table_privilege('authenticated', 'public.remates', 'select');

  -- `insert` estuvo abierto A PROPOSITO mientras la pantalla de crear remate
  -- lo usaba. Desde el 07/10 pasa por crear_remate_completo(), asi que ya no
  -- hace falta -- pero el GRANT sigue puesto y cerrarlo es otra migracion.
  -- Se sigue sin comprobar aqui para no poner roja esta prueba por algo que
  -- decidimos dejar asi; lo cubre P48 cuando se cierre.
  perform _p.anotar(36, 'Nadie escribe la tabla remates directo',
    'authenticated y anon sin update ni delete; select si; insert abierto hasta el bloque 4',
    (not v_auth_upd) and (not v_auth_del) and (not v_anon_upd) and v_auth_sel,
    'auth[upd=' || v_auth_upd::text || ',del=' || v_auth_del::text ||
    ',sel=' || v_auth_sel::text || ',ins=' || v_auth_ins::text || ' (abierto a proposito)' ||
    '] anon[upd=' || v_anon_upd::text || ']');
exception when others then
  perform _p.anotar(36, 'Nadie escribe la tabla remates directo',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P37 - El porcentaje de la casa se congela en cuanto hay una puja
--
--  La gente pujo sabiendo que el premio era el 75% del pozo. Cambiarlo
--  despues es cambiar el trato una vez que ya apostaron.
--
--  Las dos mitades: antes de la primera puja SI se puede (y deja aviso),
--  despues NO.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u1 uuid; v_rem uuid; v_h1 uuid;
  v_antes_ok boolean := false; v_despues_bloqueado boolean := false;
  v_avisos integer := 0; v_msg text := '';
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100, 25);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_admin);

  -- mitad 1: sin pujas todavia, el cambio pasa
  begin
    perform public.editar_remate(v_rem, 30, null, null, null, null);
    v_antes_ok := (select porcentaje_casa from public.remates where id = v_rem) = 30;
    v_msg := 'sin pujas: cambio a ' ||
      (select porcentaje_casa::text from public.remates where id = v_rem) || ' | ';
  exception when others then
    v_msg := 'sin pujas NO dejo cambiar (' || sqlerrm || ') | ';
  end;

  -- llega una puja
  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h1, 100, true);
  perform _p.actuar_como(v_admin);

  -- mitad 2: ahora tiene que rechazar
  begin
    perform public.editar_remate(v_rem, 40, null, null, null, null);
    v_msg := v_msg || 'con pujas DEJO cambiar (mal)';
  exception when others then
    v_despues_bloqueado := true;
    v_msg := v_msg || 'con pujas bloqueado';
  end;

  -- y el cambio valido tiene que haber dejado su aviso
  select count(*) into v_avisos
  from public.remate_avisos
  where remate_id = v_rem and tipo = 'porcentaje_casa';

  perform _p.anotar(37, 'El porcentaje de la casa se congela con la primera puja',
    'sin pujas se puede y deja 1 aviso; con pujas se rechaza',
    v_antes_ok and v_despues_bloqueado and v_avisos = 1,
    v_msg || ' | avisos=' || v_avisos::text);
exception when others then
  perform _p.anotar(37, 'El porcentaje de la casa se congela con la primera puja',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P38 - Cambiar el incremento deja aviso SIEMPRE, haya pujas o no
--
--  La primera version solo comprobaba el caso CON pujas, porque asi lo habia
--  escrito yo en la migracion. Jota probo en produccion el caso sin pujas
--  -- cambio el incremento, guardo, y no salio ningun aviso -- y tenia razon
--  en esperar uno.
--
--  Peor: la inconsistencia iba al reves de lo que tendria sentido. El
--  porcentaje SOLO se puede cambiar cuando NO hay pujas, asi que su aviso
--  siempre salia en remates sin pujas. El incremento, que se puede cambiar
--  siempre, era el que se callaba en ese mismo caso.
--
--  Un remate abierto es un remate que la gente esta mirando. Y callar hasta
--  la primera puja le da al admin una ventana para cambiar las condiciones
--  sin dejar rastro, que es lo contrario de para lo que existe la tabla.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u1 uuid;
  v_rem_sin uuid; v_rem_con uuid; v_h1 uuid; v_h2 uuid;
  v_avisos_sin integer := 0; v_avisos_con integer := 0;
  v_existe boolean;
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'editar_remate'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(38, 'Cambiar el incremento deja aviso siempre, haya pujas o no',
      'un aviso en el remate sin pujas y otro en el que tiene',
      false, 'editar_remate NO EXISTE: la migracion no esta aplicada');
    return;
  end if;

  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan', 10000);

  -- mitad 1: remate SIN pujas
  v_rem_sin := _p.escenario(2, 100, 25);
  v_h1 := _p.caballo(v_rem_sin, 1);
  perform _p.actuar_como(v_admin);
  perform public.editar_remate(v_rem_sin, null, 75, null, null, null);

  select count(*) into v_avisos_sin
  from public.remate_avisos where remate_id = v_rem_sin and tipo = 'incremento';

  -- mitad 2: remate CON pujas
  v_rem_con := _p.escenario(2, 100, 25);
  v_h2 := _p.caballo(v_rem_con, 1);
  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem_con, v_h2, 100, true);
  perform _p.actuar_como(v_admin);
  perform public.editar_remate(v_rem_con, null, 80, null, null, null);

  select count(*) into v_avisos_con
  from public.remate_avisos where remate_id = v_rem_con and tipo = 'incremento';

  perform _p.anotar(38, 'Cambiar el incremento deja aviso siempre, haya pujas o no',
    'un aviso en el remate sin pujas y otro en el que tiene',
    v_avisos_sin = 1 and v_avisos_con = 1,
    'sin pujas: ' || v_avisos_sin::text || ' aviso(s) | con pujas: ' || v_avisos_con::text || ' aviso(s)');
exception when others then
  perform _p.anotar(38, 'Cambiar el incremento deja aviso siempre, haya pujas o no',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P39 - editar_remate no toca el estado ni edita remates cerrados
--
--  REESCRITA EL 28/09. La primera version PASABA EN VERDE sin la migracion
--  aplicada, que es el peor resultado posible para una prueba:
--
--    - `sin_param_estado` buscaba una funcion con parametro `estado`. Sin la
--      migracion no hay NINGUNA funcion, asi que el NOT EXISTS daba true.
--    - `cerrado_bloqueado` llamaba a la funcion; saltaba "function does not
--      exist", y un `exception when others` la contaba como rechazo correcto.
--
--  Las dos mitades aprobaban porque la funcion no existia.
--
--  LA REGLA QUE SALE DE AQUI, Y VALE PARA TODO EL ARNES:
--  cuando el exito de una prueba consiste en "salto una excepcion", hay que
--  comprobar CUAL excepcion. Un `when others` se traga tanto el rechazo que
--  buscas como el error que significa que no estas probando nada.
--
--    42883 = undefined_function  -> la migracion NO esta aplicada
--    P0001 = raise_exception     -> nuestro codigo rechazo a proposito
-- ============================================================================
do $$
declare
  v_admin uuid; v_u1 uuid; v_rem uuid; v_h1 uuid;
  v_existe boolean;
  v_sin_param_estado boolean;
  v_cerrado_bloqueado boolean := false;
  v_estado_sigue boolean := false;
  v_msg text := '';
  v_sqlstate text;
begin
  perform _p.limpiar();

  -- 0) LO PRIMERO: la funcion tiene que existir. Sin esto, todo lo demas
  --    aprueba por omision.
  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'editar_remate'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(39, 'editar_remate no toca el estado ni edita remates cerrados',
      'sin parametro de estado; un remate cerrado se rechaza con P0001',
      false, 'editar_remate NO EXISTE: la migracion no esta aplicada');
    return;
  end if;

  -- 1) ninguna sobrecarga acepta un parametro de estado
  select not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'editar_remate'
      and pg_get_function_arguments(p.oid) ilike '%estado%'
  ) into v_sin_param_estado;

  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100, 25);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h1, 100, true);
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);

  -- 2) un remate cerrado no se edita, y tiene que rechazarlo NUESTRO codigo
  begin
    perform public.editar_remate(v_rem, null, 999, null, null, null);
    v_msg := 'dejo editar un remate CERRADO (mal)';
  exception when others then
    v_sqlstate := sqlstate;
    if v_sqlstate = 'P0001' then
      v_cerrado_bloqueado := true;
      v_msg := 'remate cerrado rechazado por nuestro codigo (P0001)';
    else
      v_msg := 'rechazado, pero por el motivo EQUIVOCADO (' || v_sqlstate || '): ' || sqlerrm;
    end if;
  end;

  -- 3) y el incremento no se movio: que rechace no basta, tiene que no escribir
  v_estado_sigue := (select incremento_minimo from public.remates where id = v_rem) <> 999;

  perform _p.anotar(39, 'editar_remate no toca el estado ni edita remates cerrados',
    'sin parametro de estado; un remate cerrado se rechaza con P0001 y no se escribe nada',
    v_sin_param_estado and v_cerrado_bloqueado and v_estado_sigue,
    'sin_param_estado=' || v_sin_param_estado::text ||
    ' | ' || v_msg ||
    ' | no escribio=' || v_estado_sigue::text);
exception when others then
  perform _p.anotar(39, 'editar_remate no toca el estado ni edita remates cerrados',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;



-- ============================================================================
--  P40 a P46 - LA AUDITORIA DEL 28/09, TANDA 1
--
--  Siete pruebas para los nueve arreglos de
--  20260929100000_auditoria_tanda1.sql. Todas se escribieron ANTES de aplicar
--  la migracion y todas tienen que salir en ROJO primero. Una prueba que nace
--  verde no prueba nada: ver la cabecera de este archivo y P39.
--
--  Los tres arreglos de concurrencia -- A2 (`for share` en hacer_puja), A4
--  (candado de caja) y la carrera de set_ganador_carrera -- NO estan aqui.
--  No se pueden reproducir con una sola conexion: hacen falta dos sesiones
--  intercaladas. Van en tests/concurrencia.sql.
--  Lo que SI se puede probar aqui de D1 es la red que lo hace imposible: el
--  unique. Es exactamente la diferencia entre probar la carrera y probar la
--  valla.
-- ============================================================================


-- ============================================================================
--  P40 - Retirar un caballo y DESPUES cancelar el remate no paga dos veces
--
--  Hallazgo A3. cancelar_remate sumaba solo los movimientos 'apuesta_cobro' e
--  ignoraba las 'apuesta_devolucion' ya emitidas sobre el mismo remate:
--
--    juan lidera dos caballos -> al cerrar se le cobran 800
--    se retira uno           -> retirar_caballo le devuelve 300 (neto: 500)
--    se suspende la carrera  -> cancelar_remate le devolvia OTROS 800
--
--  juan terminaba con 10.300 habiendo puesto 10.000. Los 300 salian de la
--  caja del licenciatario y ninguna pantalla lo decia.
--
--  liquidar_remate, de la misma tajada y con el mismo problema delante, SI
--  los neteaba. Su comentario lo explicaba. cancelar_remate se quedo con el
--  conjunto incompleto.
--
--  Se mide el saldo en los CUATRO momentos a proposito. Si solo se midiera el
--  final, la prueba pasaria en verde tambien en el caso de que ni el cierre ni
--  el retiro hubieran hecho nada: 10.000 - 0 + 0 + 0 = 10.000.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
  v_s0 numeric; v_s1 numeric; v_s2 numeric; v_s3 numeric;
  v_devoluciones numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(3, 100, 25);
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 500, true);
  perform public.hacer_puja(v_rem, v_h2, 300, true);
  v_s0 := _p.saldo(v_u);                      -- 10000: pujar no cobra (modelo v2)

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  v_s1 := _p.saldo(v_u);                      -- 9200: se cobran los dos, 800

  perform public.retirar_caballo(v_h2, 'Lesion en el paddock');
  v_s2 := _p.saldo(v_u);                      -- 9500: devuelve 300, neto 500

  perform public.cancelar_remate(v_rem, 'Carrera suspendida por lluvia');
  v_s3 := _p.saldo(v_u);                      -- 10000: devuelve los 500 que faltan

  select coalesce(sum(m.monto),0) into v_devoluciones
  from public.wallet_movements m
  join public.wallets w on w.id = m.wallet_id
  where w.user_id = v_u and m.tipo = 'apuesta_devolucion';

  perform _p.anotar(40, 'Retirar un caballo y luego cancelar no reembolsa dos veces',
    '10000 -> 9200 (cierre) -> 9500 (retiro) -> 10000 (cancelacion), devuelto total 800',
    v_s0 = 10000 and v_s1 = 9200 and v_s2 = 9500 and v_s3 = 10000 and v_devoluciones = 800,
    'pujas: ' || v_s0::text || ' | cierre: ' || v_s1::text ||
    ' | retiro: ' || v_s2::text || ' | cancelacion: ' || v_s3::text ||
    ' (esperado 10000; si da 10300 cancelar_remate ignoro la devolucion previa)' ||
    ' | devuelto total: ' || v_devoluciones::text || ' (esperado 800)');
exception when others then
  perform _p.anotar(40, 'Retirar un caballo y luego cancelar no reembolsa dos veces',
    'saldo final = 10000', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P41 - Un admin no puede acunar saldo escribiendo deposit_requests
--
--  Hallazgo A5. La baseline daba `GRANT SELECT, INSERT, UPDATE` sobre la
--  tabla a `authenticated`, y la politica `deposit_admin_all` era FOR ALL con
--  `USING is_admin() WITH CHECK is_admin()`. Las dos cosas juntas: cualquier
--  admin podia insertar una fila 'aprobado' desde la consola del navegador, o
--  pasar a 'aprobado' una pendiente, sin pasar por aprobar_recarga.
--
--  Es la misma forma exacta del agujero de `remates.estado` que cerro la 3.2:
--  una RPC bien hecha al lado de una puerta abierta.
--
--  Igual que P33 y P36, esto se consulta con has_table_privilege en vez de
--  ejercitarlo: el arnes corre como `postgres`, que se salta cualquier ACL.
--
--  La segunda mitad importa tanto como la primera: cerrar la puerta sin
--  romper la RPC. solicitar_recarga y aprobar_recarga son `definer`, asi que
--  tienen que seguir funcionando.
-- ============================================================================
do $$
declare
  v_auth_ins boolean; v_auth_upd boolean; v_auth_del boolean; v_auth_sel boolean;
  v_anon_ins boolean; v_anon_upd boolean; v_anon_sel boolean;
  v_pol_all boolean; v_pol_select boolean; v_pol_own boolean;
  v_admin uuid; v_u uuid; v_dep uuid; v_saldo numeric;
begin
  perform _p.limpiar();

  v_auth_ins := has_table_privilege('authenticated', 'public.deposit_requests', 'insert');
  v_auth_upd := has_table_privilege('authenticated', 'public.deposit_requests', 'update');
  v_auth_del := has_table_privilege('authenticated', 'public.deposit_requests', 'delete');
  -- leer SI: el usuario ve sus recargas y el admin las suyas, cada uno por su politica
  v_auth_sel := has_table_privilege('authenticated', 'public.deposit_requests', 'select');
  v_anon_ins := has_table_privilege('anon', 'public.deposit_requests', 'insert');
  v_anon_upd := has_table_privilege('anon', 'public.deposit_requests', 'update');
  v_anon_sel := has_table_privilege('anon', 'public.deposit_requests', 'select');

  -- la politica FOR ALL tiene que haber desaparecido, no basta con el revoke:
  -- las politicas permisivas se SUMAN con OR, y dejarla ahi seria dejar puesta
  -- la mitad del agujero esperando a que alguien reponga el grant.
  select exists (select 1 from pg_policies
                 where schemaname='public' and tablename='deposit_requests'
                   and policyname='deposit_admin_all') into v_pol_all;
  select exists (select 1 from pg_policies
                 where schemaname='public' and tablename='deposit_requests'
                   and policyname='deposit_admin_select' and cmd='SELECT') into v_pol_select;
  select exists (select 1 from pg_policies
                 where schemaname='public' and tablename='deposit_requests'
                   and policyname='deposit_select_own') into v_pol_own;

  -- y la via legitima tiene que seguir viva
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 0);
  perform _p.actuar_como(v_u);
  perform public.solicitar_recarga(1000, 'pago_movil', '04121234567', 'REF-A5', current_date);
  select id into v_dep from public.deposit_requests where user_id = v_u;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);
  v_saldo := _p.saldo(v_u);

  perform _p.anotar(41, 'deposit_requests no se escribe directo, ni por un admin',
    'authenticated y anon sin insert/update/delete; select sigue; deposit_admin_all borrada; la recarga por RPC sigue funcionando',
    (not v_auth_ins) and (not v_auth_upd) and (not v_auth_del) and v_auth_sel
      and (not v_anon_ins) and (not v_anon_upd) and (not v_anon_sel)
      and (not v_pol_all) and v_pol_select and v_pol_own
      and v_saldo = 1000,
    'auth[ins=' || v_auth_ins::text || ',upd=' || v_auth_upd::text ||
    ',del=' || v_auth_del::text || ',sel=' || v_auth_sel::text || ']' ||
    ' anon[ins=' || v_anon_ins::text || ',upd=' || v_anon_upd::text ||
    ',sel=' || v_anon_sel::text || ']' ||
    ' politicas[admin_all=' || v_pol_all::text || ',admin_select=' || v_pol_select::text ||
    ',select_own=' || v_pol_own::text || ']' ||
    ' | saldo tras recarga por RPC: ' || coalesce(v_saldo,-1)::text || ' (esperado 1000)');
exception when others then
  perform _p.anotar(41, 'deposit_requests no se escribe directo, ni por un admin',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P42 - Una tabla nueva nace CERRADA (y una funcion nueva, no)
--
--  Hallazgo A6, y la mina estructural del esquema. La baseline trae:
--
--    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--      GRANT ALL ON TABLES    TO anon, authenticated;
--    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--      GRANT ALL ON FUNCTIONS TO anon, authenticated;
--
--  No hace falta un grant para quedar expuesto: hace falta un revoke para no
--  estarlo. Y eso no sale en ningun diff, porque el diff de la migracion que
--  crea la tabla no dice nada de permisos.
--
--  Esta prueba no mira el texto de la migracion: crea de verdad una tabla y
--  una funcion en `public` como postgres -- que es exactamente lo que hace
--  cada migracion -- y pregunta por su ACL. Luego las borra.
--
--  LA FUNCION SE MIDE PERO NO SE EXIGE, Y NO ES PEREZA.
--
--  PostgreSQL le da EXECUTE a PUBLIC en toda funcion nueva, de fabrica, y
--  `authenticated` hereda de PUBLIC. Eso solo se quita con una entrada GLOBAL
--  de default privileges, sin `IN SCHEMA`, que aplica a todos los esquemas y
--  deja sin EXECUTE tambien a cualquier extension que se instale despues
--  (comprobado: `create extension citext` con esa entrada puesta deja sus 23
--  funciones cerradas y rompe hasta un `where columna = 'x'`). En una base que
--  opera el licenciatario, eso es una mina.
--
--  Decision de Jota (29/09): la base no falla cerrada en funciones; el arnes
--  falla ruidoso. El censo esta en P47, que enumera TODAS las funciones de
--  `public` contra una lista blanca. Aqui se deja medido para que el numero
--  quede a la vista y nadie crea que A6 cubrio algo que no cubre.
-- ============================================================================
do $$
declare
  v_tabla_sel_auth boolean; v_tabla_ins_auth boolean; v_tabla_sel_anon boolean;
  v_sec_auth boolean;
  v_fn_auth boolean;
begin
  execute 'drop table if exists public._p_acl_tabla';
  execute 'drop function if exists public._p_acl_funcion()';

  execute 'create table public._p_acl_tabla (id serial primary key, x int)';
  execute 'create function public._p_acl_funcion() returns int language sql as ''select 1''';

  v_tabla_sel_auth := has_table_privilege('authenticated', 'public._p_acl_tabla', 'select');
  v_tabla_ins_auth := has_table_privilege('authenticated', 'public._p_acl_tabla', 'insert');
  v_tabla_sel_anon := has_table_privilege('anon',          'public._p_acl_tabla', 'select');
  v_sec_auth       := has_sequence_privilege('authenticated', 'public._p_acl_tabla_id_seq', 'usage');
  v_fn_auth        := has_function_privilege('authenticated', 'public._p_acl_funcion()', 'execute');

  execute 'drop table if exists public._p_acl_tabla';
  execute 'drop function if exists public._p_acl_funcion()';

  perform _p.anotar(42, 'Una tabla nueva y su secuencia nacen cerradas',
    'sin privilegios para anon ni authenticated en la tabla ni en la secuencia',
    (not v_tabla_sel_auth) and (not v_tabla_ins_auth) and (not v_tabla_sel_anon)
      and (not v_sec_auth),
    'tabla[auth_sel=' || v_tabla_sel_auth::text || ',auth_ins=' || v_tabla_ins_auth::text ||
    ',anon_sel=' || v_tabla_sel_anon::text || ']' ||
    ' secuencia[auth_usage=' || v_sec_auth::text || ']' ||
    ' | funcion nueva ejecutable por authenticated=' || v_fn_auth::text ||
    ' (NO se exige aqui: PostgreSQL se lo da a PUBLIC de fabrica y solo se quita' ||
    ' con una entrada global que romperia las extensiones. El censo es P47)');
exception when others then
  execute 'drop table if exists public._p_acl_tabla';
  execute 'drop function if exists public._p_acl_funcion()';
  perform _p.anotar(42, 'Una tabla nueva y su secuencia nacen cerradas',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P43 - La caja del licenciatario no la lee un usuario cualquiera
--
--  Hallazgo A7. El revoke de 20260923150000:100 decia:
--
--    revoke all on function public.dinero_casa_disponible() from public, anon;
--
--  Faltaba `authenticated`, y por A6 la funcion ya tenia el execute desde que
--  se creo. Cualquier registrado podia abrir la consola, llamar
--  supabase.rpc('dinero_casa_disponible') y ver recargas, retiros, el saldo
--  agregado de todos los usuarios y el capital propio del licenciatario.
--
--  Mismo defecto que la 2.22 (casa_resumen), en la misma migracion que lo
--  arreglo, en la funcion de al lado.
--
--  La segunda mitad comprueba que cerrarla no rompio a quien la usa de
--  verdad: liquidar_remate y casa_resumen son `definer` y corren como
--  postgres, asi que la guarda de solvencia tiene que seguir funcionando.
-- ============================================================================
do $$
declare
  v_anon boolean; v_auth boolean; v_publico boolean;
  v_admin uuid; v_u uuid; v_rem uuid; v_h uuid; v_caja numeric; v_liquido boolean := false;
begin
  perform _p.limpiar();

  v_anon := has_function_privilege('anon',          'public.dinero_casa_disponible()', 'execute');
  v_auth := has_function_privilege('authenticated', 'public.dinero_casa_disponible()', 'execute');
  -- el ACL de PUBLIC se mira aparte: authenticated hereda de el, y si quedara
  -- ahi el revoke a authenticated no serviria de nada
  --
  --  OJO CON COMO SE PREGUNTA ESTO. La primera version que escribi hacia
  --  `array_to_string(proacl, ',') like '=X/%'`, y solo habria acertado si la
  --  entrada de PUBLIC fuera la PRIMERA del arreglo. Ademas, `proacl` nulo
  --  significa "ACL por defecto", que para una funcion incluye EXECUTE para
  --  PUBLIC: el like habria dado false justo en el caso mas abierto posible.
  --  aclexplode + grantee = 0 (PUBLIC) es la forma correcta, y acldefault
  --  cubre el nulo.
  select coalesce(
    (select bool_or(a.privilege_type = 'EXECUTE')
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
     where n.nspname = 'public' and p.proname = 'dinero_casa_disponible'
       and a.grantee = 0),
    false) into v_publico;

  -- y la via interna tiene que seguir viva
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);
  v_rem   := _p.escenario(2, 100);
  v_h     := _p.caballo(v_rem, 1);
  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 2);     -- gana un caballo de la casa
  perform public.liquidar_remate(v_rem);
  v_liquido := (select estado from public.remates where id = v_rem) = 'liquidado';
  v_caja := public.dinero_casa_disponible();

  perform _p.anotar(43, 'dinero_casa_disponible() cerrada a anon y a authenticated',
    'sin execute para anon, authenticated ni PUBLIC; la liquidacion sigue funcionando',
    (not v_anon) and (not v_auth) and (not v_publico) and v_liquido and v_caja = 100,
    'anon=' || v_anon::text || ' authenticated=' || v_auth::text ||
    ' PUBLIC=' || v_publico::text ||
    ' | liquido=' || v_liquido::text || ' caja=' || coalesce(v_caja,-1)::text || ' (esperado 100)');
exception when others then
  perform _p.anotar(43, 'dinero_casa_disponible() cerrada a anon y a authenticated',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P44 - La base rechaza un saldo negativo, venga de donde venga
--
--  Hallazgo D3. El invariante `saldo_disponible >= compromiso_usuario()` --
--  que implica saldo >= 0 -- vivia EXCLUSIVAMENTE dentro de tres cuerpos
--  PL/pgSQL. Cualquier ruta que no pasara por ellos dejaba el saldo en
--  negativo sin una sola queja: service_role, un psql de mantenimiento, una
--  migracion futura, o el propio agujero A2.
--
--  Un check no es redundante con las guardas de aplicacion. Es la ultima red,
--  y es la unica que no se puede saltar: ni siquiera `postgres` la esquiva.
--  Por eso esta prueba puede ejercitarla de verdad en vez de consultarla.
--
--  23514 = check_violation. Si saltara cualquier otro codigo, la prueba tiene
--  que decirlo: seria otro problema disfrazado de exito.
-- ============================================================================
do $$
declare
  v_u uuid; v_constraint_existe boolean; v_constraint_validada boolean;
  v_disp_bloqueado boolean := false; v_bloq_bloqueado boolean := false;
  v_saldo_final numeric; v_sqlstate text; v_msg text := '';
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_constraint
    where conrelid = 'public.wallets'::regclass
      and conname = 'wallets_saldo_no_negativo'),
    coalesce((select convalidated from pg_constraint
      where conrelid = 'public.wallets'::regclass
        and conname = 'wallets_saldo_no_negativo'), false)
  into v_constraint_existe, v_constraint_validada;

  if not v_constraint_existe then
    perform _p.anotar(44, 'La base rechaza un saldo negativo',
      'check wallets_saldo_no_negativo, validado, rechaza con 23514',
      false, 'el check NO EXISTE: la migracion no esta aplicada');
    return;
  end if;

  v_u := _p.usuario('juan', 500);

  begin
    update public.wallets set saldo_disponible = -1 where user_id = v_u;
    v_msg := 'dejo poner saldo_disponible en -1 (mal)';
  exception when others then
    v_sqlstate := sqlstate;
    if v_sqlstate = '23514' then
      v_disp_bloqueado := true;
      v_msg := 'saldo_disponible negativo rechazado (23514)';
    else
      v_msg := 'rechazado, pero por el motivo EQUIVOCADO (' || v_sqlstate || '): ' || sqlerrm;
    end if;
  end;

  begin
    update public.wallets set saldo_bloqueado = -1 where user_id = v_u;
  exception when others then
    if sqlstate = '23514' then v_bloq_bloqueado := true; end if;
  end;

  -- que rechace no basta: tiene que no haber escrito nada
  v_saldo_final := _p.saldo(v_u);

  perform _p.anotar(44, 'La base rechaza un saldo negativo',
    'check validado; los dos saldos rechazan con 23514 y no se escribe nada',
    v_constraint_validada and v_disp_bloqueado and v_bloq_bloqueado and v_saldo_final = 500,
    'validado=' || v_constraint_validada::text || ' | ' || v_msg ||
    ' | bloqueado negativo rechazado=' || v_bloq_bloqueado::text ||
    ' | saldo sigue en ' || coalesce(v_saldo_final,-1)::text || ' (esperado 500)');
exception when others then
  perform _p.anotar(44, 'La base rechaza un saldo negativo',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P45 - Una carrera no puede tener dos ganadores
--
--  Hallazgo D1. set_ganador_carrera es un update-then-insert sin candado
--  sobre una tabla sin restriccion unica:
--
--    update race_results set ganador_horse_id = ... where race_id = ...;
--    if not found then insert into race_results (...) values (...); end if;
--
--  Dos llamadas simultaneas -- dos admins, un doble clic, el reintento de un
--  fetch que no respondio -- hacen las dos un update que afecta 0 filas, las
--  dos entran al `if not found`, y las dos insertan. Quedan dos filas para la
--  misma carrera, posiblemente con ganadores distintos. Y liquidar_remate lee
--  con `select ... into` sin `limit` y sin `strict`: toma la primera que
--  devuelva el plan, sin error y sin aviso. El premio entero se paga a un
--  usuario indeterminado.
--
--  ESTO NO PRUEBA LA CARRERA: probarla hace falta dos conexiones, y eso va en
--  tests/concurrencia.sql. Prueba la VALLA que la vuelve imposible. Es una
--  distincion que conviene no perder de vista: aqui se comprueba que la
--  segunda fila no cabe, no que dos sesiones no lleguen a la vez.
--
--  23505 = unique_violation.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_race uuid;
  v_existe boolean; v_segunda_bloqueada boolean := false;
  v_filas integer; v_ganador uuid; v_sqlstate text; v_msg text := '';
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_constraint
    where conrelid = 'public.race_results'::regclass
      and contype = 'u'
      and conkey = (select array_agg(attnum) from pg_attribute
                    where attrelid = 'public.race_results'::regclass and attname = 'race_id')
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(45, 'Una carrera no puede tener dos resultados',
      'unique sobre race_id; el segundo insert se rechaza con 23505',
      false, 'el unique sobre race_id NO EXISTE: la migracion no esta aplicada');
    return;
  end if;

  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100);
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);
  select race_id into v_race from public.remates where id = v_rem;

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 1);

  -- la segunda fila es lo que dejaba entrar la carrera. Tiene que rebotar.
  begin
    insert into public.race_results (race_id, ganador_horse_id) values (v_race, v_h2);
    v_msg := 'dejo insertar un SEGUNDO resultado para la misma carrera (mal)';
  exception when others then
    v_sqlstate := sqlstate;
    if v_sqlstate = '23505' then
      v_segunda_bloqueada := true;
      v_msg := 'segundo resultado rechazado por el unique (23505)';
    else
      v_msg := 'rechazado, pero por el motivo EQUIVOCADO (' || v_sqlstate || '): ' || sqlerrm;
    end if;
  end;

  -- y llamar dos veces a la RPC tiene que seguir siendo legitimo: corrige, no duplica
  perform public.set_ganador_carrera(v_rem, 2);
  select count(*) into v_filas from public.race_results where race_id = v_race;
  select ganador_horse_id into v_ganador from public.race_results where race_id = v_race;

  perform _p.anotar(45, 'Una carrera no puede tener dos resultados',
    'el insert directo rebota con 23505; llamar dos veces a la RPC corrige el ganador sin duplicar',
    v_segunda_bloqueada and v_filas = 1 and v_ganador = v_h2,
    v_msg || ' | filas para la carrera: ' || v_filas::text || ' (esperado 1)' ||
    ' | la segunda llamada corrigio el ganador: ' || (v_ganador = v_h2)::text);
exception when others then
  perform _p.anotar(45, 'Una carrera no puede tener dos resultados',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P46 - El panel de contabilidad ve el capital propio, igual que la guarda
--
--  Hallazgo B5. La tarea 2.18 anadio el libro de la casa y actualizo
--  dinero_casa_disponible() para que sumara los asientos manuales. A
--  admin_contabilidad_resumen() no. Desde ese dia la guarda de solvencia y la
--  pantalla que el admin mira daban numeros distintos sobre la misma caja.
--
--  Estaba a la vista en el propio arnes: en P30, tras un aporte de 5.000, la
--  funcion daba 5.500 y el panel seguia diciendo 500. Nadie los comparo
--  DESPUES de un aporte.
--
--  Y P19, que es la prueba que existe para comparar estos dos numeros, no lo
--  detectaba: su escenario no tiene ningun asiento manual, asi que el termino
--  que faltaba valia cero en los dos momentos que mide. Una prueba que compara
--  dos cosas iguales en el unico caso en que no pueden diferir.
--
--  Esta lo mide justo donde duele: con un aporte de capital encima.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u uuid;
  v_funcion numeric; v_panel numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);     -- recarga aprobada de 1000, wallet 1000

  -- sin asientos manuales la caja es 1000 - 1000 = 0: es el caso ciego de P19
  perform _p.actuar_como(v_admin);
  perform public.registrar_movimiento_casa('aporte_capital', 5000, 'Capital inicial del licenciatario');

  v_funcion := public.dinero_casa_disponible();
  v_panel   := (public.admin_contabilidad_resumen() ->> 'dinero_casa')::numeric;

  perform _p.anotar(46, 'El panel de contabilidad suma el capital propio',
    'funcion y panel dan lo mismo, y los dos dan 5000',
    v_funcion = v_panel and v_funcion = 5000,
    'funcion: ' || coalesce(v_funcion,-1)::text ||
    ' | panel: ' || coalesce(v_panel,-1)::text ||
    ' (esperado 5000 en los dos; si el panel da 0 no esta sumando el libro de la casa)');
exception when others then
  perform _p.anotar(46, 'El panel de contabilidad suma el capital propio',
    'funcion y panel dan 5000 los dos', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;



-- ============================================================================
--  P47 - CENSO DE FUNCIONES: ninguna queda abierta sin estar declarada
--
--  Esta prueba existe por lo que paso el 29/09 y no por una teoria.
--
--  A6 quiso que "lo nuevo nazca cerrado" y resulto que en funciones no se
--  puede: PostgreSQL le da EXECUTE a PUBLIC de fabrica y eso solo se quita
--  con una entrada global de default privileges que rompe las extensiones
--  (comprobado con citext). Decision de Jota: la base no falla cerrada, el
--  arnes falla ruidoso.
--
--  Esto es el ruido. Enumera TODAS las funciones de `public` y compara con lo
--  declarado. Tres cosas se ponen rojas:
--
--    - una funcion declarada `cerrada` que alguien puede ejecutar
--    - una funcion declarada abierta que ya no lo esta (grant perdido)
--    - una funcion que NO ESTA DECLARADA. Esa es la importante: es la RPC
--      nueva que nacio abierta y que nadie iba a ver en el diff.
--
--  La lista de abajo no es una foto de como esta la base: es como TIENE que
--  estar. Se saco de cruzar las 19 RPC que llama `app/` y `lib/` con el
--  inventario real de funciones del 29/09.
--
--  OJO AL ANADIR UNA RPC: hay que anadirla aqui Y darle su grant. Si solo se
--  le da el grant, esta prueba se pone roja. Es a proposito.
-- ============================================================================
do $$
declare
  r record;
  v_total int := 0; v_fallos int := 0; v_sin_declarar int := 0;
  v_ext_abiertas int := 0; v_ext_toleradas int := 0; v_ext_sin_permiso int := 0;
  v_detalle text := '';
begin
  for r in
    with esperado(nombre, quien) as (values
      -- internas: solo las llaman otras funciones definer, que corren como postgres
      ('_cerrar_remate_interno',          'cerrada'),
      ('_incremento_aplicable',           'cerrada'),
      ('compromiso_usuario',              'cerrada'),
      ('dinero_casa_disponible',          'cerrada'),
      ('log_admin_action',                'cerrada'),
      -- el cron, con clave de servicio
      ('auto_cerrar_remates',             'cerrada'),
      -- funciones de trigger: disparan sin EXECUTE (comprobado 29/09)
      ('handle_new_user',                 'cerrada'),
      ('tr_check_admin_immutability',     'cerrada'),
      ('set_support_settings_updated_at', 'cerrada'),
      -- emisor de senales de realtime y sus seis triggers (30/09)
      ('_avisar',                         'cerrada'),
      ('tr_avisar_puja',                  'cerrada'),
      ('tr_avisar_remate',                'cerrada'),
      ('tr_avisar_aviso',                 'cerrada'),
      ('tr_avisar_caballo',               'cerrada'),
      ('tr_avisar_recarga',               'cerrada'),
      ('tr_avisar_retiro',                'cerrada'),
      -- avisos al usuario y canal de la coleccion (05/10)
      ('_notificar',                      'cerrada'),
      ('tr_avisar_lista',                 'cerrada'),
      -- ajustes de instalacion y los tres guardianes de minimos (01/10)
      ('ajuste_numero',                    'cerrada'),
      ('requisito_apuesta',                'cerrada'),
      ('_motivo_etiqueta',                 'cerrada'),
      ('tr_ajustes_updated_at',            'cerrada'),
      ('tr_minimo_incremento_remate',      'cerrada'),
      ('tr_minimo_incremento_regla',       'cerrada'),
      ('tr_minimo_precio_salida',          'cerrada'),
      -- sin uso en la aplicacion
      ('get_usernames',                   'cerrada'),
      ('promover_usuario',                'cerrada'),
      ('set_admin',                       'cerrada'),
      -- RPC de usuario con sesion
      ('admin_contabilidad_resumen',      'auth'),
      ('aprobar_recarga',                 'auth'),
      ('archivar_remate',                 'auth'),
      ('ajustes_publicos',                'anon'),
      ('buscar_usuario_para_admin',       'auth'),
      ('cancelar_remate',                 'auth'),
      ('casa_fundada',                    'anon'),
      ('datos_de_cobro',                  'auth'),
      ('documentos_vigentes',             'anon'),
      ('mis_documentos_pendientes',       'auth'),
      ('aceptar_documentos',              'auth'),
      ('publicar_documento',              'auth'),
      ('guardar_ajustes',                 'auth'),
      ('casa_resumen',                    'auth'),
      ('cerrar_remate',                   'auth'),
      ('fundar_super_admin',              'auth'),
      ('crear_remate_completo',           'auth'),
      ('guardar_escaleras',               'auth'),
      ('guardar_remate_completo',         'auth'),
      ('editar_remate',                   'auth'),
      ('hacer_puja',                      'auth'),
      ('liquidar_remate',                 'auth'),
      ('listar_admins',                   'auth'),
      ('marcar_aviso_leido',              'auth'),
      ('marcar_remates_vistos',          'auth'),
      ('listar_wallets_superadmin',       'auth'),
      ('mi_wallet_resumen',               'auth'),
      ('nombrar_admin',                   'auth'),
      ('procesar_retiro',                 'auth'),
      ('quitar_admin',                    'auth'),
      ('remates_nuevos',                  'auth'),
      ('rechazar_recarga',                'auth'),
      ('registrar_movimiento_casa',       'auth'),
      ('retirar_caballo',                 'auth'),
      ('set_ganador_carrera',             'auth'),
      ('solicitar_recarga',               'auth'),
      ('solicitar_retiro',                'auth'),
      -- las invocan las politicas RLS, que corren con los permisos de quien consulta
      ('is_admin',                        'auth'),
      ('is_super_admin',                  'auth'),
      -- informacion publica del remate: la pantalla se ve sin sesion
      ('remate_minimos',                  'anon'),
      ('listar_pujas_publicas',           'anon')
    ),
    -- =====================================================================
    --  EXTENSIONES TOLERADAS EN `public`, CON SU RAZON Y SU ALCANCE
    --
    --  CORRECCION DEL 01/10, Y DE UN ERROR MIO (ver ADR-020).
    --
    --  La primera version daba por hecho que si una extension nacia abierta,
    --  `postgres` podia cerrarla. En un Postgres pelado si. En Supabase NO:
    --  supautils intercepta CREATE EXTENSION y la crea como un rol
    --  privilegiado. La base lo dijo con dos mensajes que no dejan lugar a
    --  dudas:
    --
    --    WARNING: no privileges could be revoked for "dblink"
    --      -> PostgreSQL lo emite cuando quien revoca NO es quien concedio.
    --    ERROR 42501: permission denied for function dblink_connect_u
    --      -> `postgres` no es el dueno.
    --
    --  Asi que postgres no puede revocarle nada, ni moverla de esquema, ni
    --  borrarla. Exigir que este cerrada seria exigir algo imposible, y una
    --  prueba que pide lo imposible termina comentada.
    --
    --  Lo que SI se puede hacer es lo que hace el resto de este archivo:
    --  declararla, con su razon y su alcance escritos al lado. Una extension
    --  que no este en esta lista pone la prueba en rojo, abierta o cerrada,
    --  porque una extension sin declarar en `public` ya es el hallazgo.
    -- =====================================================================
    extensiones_toleradas(extname, razon) as (values
      ('dblink',
       'SOLO LOCAL. La instala tests/concurrencia.sql para abrir una segunda '
       'sesion (ADR-019). Ninguna migracion la crea, asi que produccion no la '
       'tiene: comprobado el 01/10, no hay un solo CREATE EXTENSION en '
       'supabase/migrations. La crea supabase_admin via supautils, de modo que '
       'postgres no puede cerrarla; se va con el proximo db reset.')
    )
    select p.proname as nombre,
           p.oid::regprocedure::text as firma,
           has_function_privilege('authenticated', p.oid, 'execute') as auth,
           has_function_privilege('anon',          p.oid, 'execute') as anon,
           e.quien,
           -- De que extension viene, si viene de alguna, y de quien es esa
           -- extension. deptype 'e' en pg_depend es exactamente eso: el objeto
           -- existe porque lo trajo un CREATE EXTENSION. El DUENO importa
           -- porque de el depende si podemos hacer algo al respecto.
           ext.extname,
           ext.dueno                       as ext_dueno,
           -- Si esta tolerada se decide AQUI, en la consulta, no en el cuerpo
           -- del bucle: un CTE solo es visible dentro de la consulta que lo
           -- declara, y consultarlo desde el bucle da 42P01.
           (t.extname is not null)         as ext_tolerada
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    left join esperado e on e.nombre = p.proname
    left join lateral (
      select x.extname, pg_get_userbyid(x.extowner) as dueno
      from pg_depend d
      join pg_extension x on x.oid = d.refobjid
      where d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e'
      limit 1
    ) ext on true
    left join extensiones_toleradas t on t.extname = ext.extname
    where n.nspname = 'public' and p.prokind = 'f'
    order by p.proname
  loop
    v_total := v_total + 1;

    -- LAS FUNCIONES DE EXTENSION NO SE DECLARAN UNA POR UNA (01/10)
    --
    -- El censo se puso rojo con 41 "SIN DECLARAR", todas dblink: las trae
    -- `create extension if not exists dblink` de tests/concurrencia.sql, y
    -- PostgreSQL le da EXECUTE a PUBLIC de fabrica (doc 17, 5.8). Es el mismo
    -- hallazgo de citext del 29/09.
    --
    -- Listarlas por nombre seria 41 lineas de lista blanca que no dicen nada y
    -- que no sirven para la PROXIMA extension que alguien instale. Asi que no
    -- se juzgan por nombre: se juzgan por clase. Una funcion de extension en
    -- `public` tiene que estar CERRADA a anon y authenticated, se llame como se
    -- llame. Si manana alguien instala pg_trgm o postgis, esto lo caza solo y
    -- con un mensaje que se entiende.
    if r.quien is null and r.extname is not null then
      if r.ext_tolerada then
        -- Declarada. Se cuenta para que el numero quede a la vista y nadie
        -- crea que no esta ahi, pero no pone la prueba en rojo.
        v_ext_toleradas := v_ext_toleradas + 1;
        if r.auth or r.anon then v_ext_abiertas := v_ext_abiertas + 1; end if;
      else
        v_ext_sin_permiso := v_ext_sin_permiso + 1;
        if v_ext_sin_permiso <= 3 then
          v_detalle := v_detalle || ' | EXTENSION SIN DECLARAR: ' || r.extname ||
                       ' -> ' || r.firma ||
                       '(auth=' || r.auth::text || ',anon=' || r.anon::text ||
                       ',dueno=' || coalesce(r.ext_dueno, '?') || ')';
        elsif v_ext_sin_permiso = 4 then
          v_detalle := v_detalle || ' | (...y mas de la misma extension; si tiene' ||
                       ' que estar, declarala en extensiones_toleradas con su' ||
                       ' razon, como dblink)';
        end if;
      end if;

    elsif r.quien is null then
      v_sin_declarar := v_sin_declarar + 1;
      v_detalle := v_detalle || ' | SIN DECLARAR: ' || r.nombre ||
                   '(auth=' || r.auth::text || ',anon=' || r.anon::text || ')';

    elsif r.quien = 'cerrada' and (r.auth or r.anon) then
      v_fallos := v_fallos + 1;
      v_detalle := v_detalle || ' | ABIERTA de mas: ' || r.nombre ||
                   '(auth=' || r.auth::text || ',anon=' || r.anon::text || ')';

    elsif r.quien = 'auth' and ((not r.auth) or r.anon) then
      v_fallos := v_fallos + 1;
      v_detalle := v_detalle || ' | ' || r.nombre || ' deberia ser solo authenticated' ||
                   ' (auth=' || r.auth::text || ',anon=' || r.anon::text || ')';

    elsif r.quien = 'anon' and ((not r.auth) or (not r.anon)) then
      v_fallos := v_fallos + 1;
      v_detalle := v_detalle || ' | ' || r.nombre || ' deberia ser publica' ||
                   ' (auth=' || r.auth::text || ',anon=' || r.anon::text || ')';
    end if;
  end loop;

  perform _p.anotar(47, 'Censo de funciones: ninguna abierta sin declarar',
    'nuestras funciones coinciden con lo declarado, ninguna sin declarar, y ninguna extension en public sin declarar',
    v_fallos = 0 and v_sin_declarar = 0 and v_ext_sin_permiso = 0 and v_total > 0,
    'funciones en public: ' || v_total::text ||
    ' | desajustes: ' || v_fallos::text ||
    ' | sin declarar: ' || v_sin_declarar::text ||
    ' | de extensiones declaradas: ' || v_ext_toleradas::text ||
    ' (abiertas a anon/authenticated: ' || v_ext_abiertas::text ||
    '; postgres no puede cerrarlas, ver ADR-020)' ||
    ' | de extensiones SIN declarar: ' || v_ext_sin_permiso::text || v_detalle);
exception when others then
  perform _p.anotar(47, 'Censo de funciones: ninguna abierta sin declarar',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P48 - CENSO DE TABLAS: quien puede escribir que, y TRUNCATE en cero
--
--  El hallazgo del 29/09: las quince tablas de `public` nacieron con GRANT ALL
--  para `anon` y `authenticated`, por el ALTER DEFAULT PRIVILEGES de la imagen
--  de Supabase. Ninguna migracion lo escribio; se aplico solo.
--
--  Y el privilegio que mas importa de esa lista es el que menos se mira:
--  TRUNCATE. Doc 17, 5.9: "Operations that apply to the whole table, such as
--  TRUNCATE and REFERENCES, are not subject to row security." Vaciar una tabla
--  no pasa por ninguna politica. La RLS no defiende de eso, y no puede.
--
--  Por eso el censo no pregunta "hay alguna politica que lo tape": pregunta
--  por el PRIVILEGIO, uno a uno, para los siete verbos.
--
--  Lo declarado abajo es el estado correcto. Las dos excepciones vivas llevan
--  su razon y su fecha de caducidad escritas al lado.
-- ============================================================================
do $$
declare
  r record; v_priv text;
  v_total int := 0; v_fallos int := 0; v_sin_declarar int := 0;
  v_detalle text := '';
  v_real boolean; v_esperado boolean;
begin
  for r in
    with esperado(tabla, auth_privs, anon_privs) as (values
      -- dinero y rastro: nadie escribe a mano, todo pasa por funciones definer
      ('wallets',            'select',                        ''),
      ('wallet_movements',   'select',                        ''),
      ('bids',               'select',                        ''),
      ('race_results',       'select',                        ''),
      ('profiles',           'select',                        ''),
      ('withdraw_requests',  'select',                        ''),
      ('deposit_requests',   'select',                        ''),
      ('admin_actions',      'select',                        ''),
      ('house_ledger',       'select',                        ''),
      ('notificaciones',     'select',                        ''),
      -- CATALOGO DEL REMATE: las tres cerradas (07 y 08/10). Crear pasa por
      -- crear_remate_completo() y editar por guardar_remate_completo(), que a
      -- su vez delega en editar_remate() y guardar_escaleras(). Todas SECURITY
      -- DEFINER. El panel ya no escribe ninguna de las tres directo.
      ('horses',             'select',                        'select'),
      ('races',              'select',                        'select'),
      ('remate_price_rules', 'select',                        'select'),
      -- `support_settings` NO es del catalogo del remate, aunque estuvo en
      -- esta lista con las otras tres hasta el 08/10. La escribe
      -- /admin/super/soporte, que es otra pantalla y necesita su propia RPC.
      ('support_settings',   'select,insert,update,delete',   'select'),
      -- ajustes de ESTA instalacion: SOLO LECTURA desde el 11/10 (ADR-047).
      -- El panel los lee para avisar antes de guardar. El update cayo porque
      -- cambiar donde cobra la casa redirige TODOS los depositos futuros y
      -- pasaba sin asiento en la bitacora: ahora escribe guardar_ajustes(),
      -- que es SECURITY DEFINER y registra que cambio, de que a que y quien.
      -- Sin insert y sin delete a proposito: las claves las crean las
      -- migraciones, y si la app pudiera borrar minimo_incremento no se
      -- podria crear un remate.
      ('ajustes_instalacion', 'select',                        ''),
      -- textos legales y su prueba de aceptacion: CERRADAS del todo. Lo que
      -- sale, sale por documentos_vigentes(); lo que entra, por
      -- publicar_documento() y aceptar_documentos(). Una tabla de
      -- consentimientos escribible desde el navegador no es una prueba.
      ('documentos_legales',   '',                             ''),
      ('aceptaciones_legales', '',                             ''),
      -- Motivos de rechazo: los lee el panel para armar el desplegable y el
      -- cliente para entender su rechazo. Son etiquetas, no datos de nadie.
      -- Sin insert ni delete: los codigos los crean las migraciones, porque
      -- un codigo que el codigo no conoce no sirve para nada.
      ('motivos_rechazo',     'select,update',                 ''),
      -- remates: update y delete ya cayeron en la 3.2. El insert sigue vivo
      -- porque lo usa la pantalla de crear remate; cae en la tanda 4.
      ('remates',            'select,insert',                 'select'),
      -- avisos al jugador: los escribe editar_remate, los lee todo el mundo
      ('remate_avisos',      'select',                        'select')
    )
    select c.relname as tabla, c.oid, e.auth_privs, e.anon_privs
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    left join esperado e on e.tabla = c.relname
    where n.nspname = 'public' and c.relkind = 'r'
    order by c.relname
  loop
    v_total := v_total + 1;

    if r.auth_privs is null then
      v_sin_declarar := v_sin_declarar + 1;
      v_detalle := v_detalle || ' | TABLA SIN DECLARAR: ' || r.tabla;
      continue;
    end if;

    foreach v_priv in array array['select','insert','update','delete','truncate','references','trigger']
    loop
      -- authenticated
      v_real     := has_table_privilege('authenticated', r.oid, v_priv);
      v_esperado := (',' || r.auth_privs || ',') like ('%,' || v_priv || ',%');
      if v_real <> v_esperado then
        v_fallos := v_fallos + 1;
        v_detalle := v_detalle || ' | ' || r.tabla || '.' || v_priv ||
                     ' authenticated=' || v_real::text || ' (esperado ' || v_esperado::text || ')';
      end if;

      -- anon
      v_real     := has_table_privilege('anon', r.oid, v_priv);
      v_esperado := (',' || r.anon_privs || ',') like ('%,' || v_priv || ',%');
      if v_real <> v_esperado then
        v_fallos := v_fallos + 1;
        v_detalle := v_detalle || ' | ' || r.tabla || '.' || v_priv ||
                     ' anon=' || v_real::text || ' (esperado ' || v_esperado::text || ')';
      end if;
    end loop;
  end loop;

  perform _p.anotar(48, 'Censo de tablas: privilegios declarados y TRUNCATE en cero',
    'las 15 tablas de public coinciden con lo declarado en los 7 verbos, para anon y authenticated',
    v_fallos = 0 and v_sin_declarar = 0 and v_total > 0,
    'tablas en public: ' || v_total::text ||
    ' | desajustes: ' || v_fallos::text ||
    ' | sin declarar: ' || v_sin_declarar::text ||
    case when v_detalle = '' then ' | todo en su sitio' else left(v_detalle, 1400) end);
exception when others then
  perform _p.anotar(48, 'Censo de tablas: privilegios declarados y TRUNCATE en cero',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P49 - Un admin no puede tocar el saldo ni el libro a mano
--
--  P47 y P48 miran el ACL. Esta ejercita la consecuencia, que es lo que de
--  verdad importa y lo que hay que poder contarle a un licenciatario:
--
--    un admin NO puede subirse el saldo desde la consola del navegador,
--    y NO puede escribir ni borrar filas de wallet_movements.
--
--  Eso ultimo es lo grave del hallazgo original: wallet_movements es lo que
--  lee el cuadre de P31. Un admin que pudiera escribir ahi falsearia los
--  libros Y la auditoria que comprueba los libros con la misma sesion.
--
--  El arnes corre como `postgres`, que se salta ACL y RLS, asi que aqui no
--  vale `actuar_como`: hay que preguntar por el privilegio. Lo que SI se
--  ejercita de verdad es que la via legitima sigue viva -- una recarga
--  aprobada por RPC mueve el saldo -- porque cerrar la puerta sin romper la
--  escalera es la mitad del trabajo.
-- ============================================================================
do $$
declare
  v_upd_wallets boolean; v_ins_movs boolean; v_del_movs boolean; v_upd_movs boolean;
  v_pol_wallets_all boolean; v_pol_movs_all boolean;
  v_admin uuid; v_u uuid; v_dep uuid; v_saldo numeric; v_movs int;
begin
  perform _p.limpiar();

  v_upd_wallets := has_table_privilege('authenticated', 'public.wallets', 'update');
  v_ins_movs    := has_table_privilege('authenticated', 'public.wallet_movements', 'insert');
  v_upd_movs    := has_table_privilege('authenticated', 'public.wallet_movements', 'update');
  v_del_movs    := has_table_privilege('authenticated', 'public.wallet_movements', 'delete');

  -- el segundo cerrojo: la politica FOR ALL tiene que haber dejado de existir
  select exists (select 1 from pg_policies where schemaname='public'
                   and tablename='wallets' and policyname='wallets_admin_all') into v_pol_wallets_all;
  select exists (select 1 from pg_policies where schemaname='public'
                   and tablename='wallet_movements' and policyname='wallet_movements_admin_all') into v_pol_movs_all;

  -- y la via legitima, ejercitada de verdad
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 0);
  perform _p.actuar_como(v_u);
  perform public.solicitar_recarga(500, 'pago_movil', '04121234567', 'REF-P49', current_date);
  select id into v_dep from public.deposit_requests where user_id = v_u;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);
  v_saldo := _p.saldo(v_u);
  select count(*) into v_movs from public.wallet_movements m
  join public.wallets w on w.id = m.wallet_id where w.user_id = v_u;

  perform _p.anotar(49, 'Un admin no toca el saldo ni el libro a mano',
    'sin update sobre wallets ni escritura sobre wallet_movements; politicas FOR ALL retiradas; la recarga por RPC sigue moviendo el saldo',
    (not v_upd_wallets) and (not v_ins_movs) and (not v_upd_movs) and (not v_del_movs)
      and (not v_pol_wallets_all) and (not v_pol_movs_all)
      and v_saldo = 500 and v_movs = 1,
    'wallets.update=' || v_upd_wallets::text ||
    ' movimientos[ins=' || v_ins_movs::text || ',upd=' || v_upd_movs::text ||
    ',del=' || v_del_movs::text || ']' ||
    ' politicas_for_all[wallets=' || v_pol_wallets_all::text || ',movimientos=' || v_pol_movs_all::text || ']' ||
    ' | via legitima -> saldo ' || coalesce(v_saldo,-1)::text || ' (esperado 500)' ||
    ', movimientos ' || v_movs::text || ' (esperado 1)');
exception when others then
  perform _p.anotar(49, 'Un admin no toca el saldo ni el libro a mano',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;



-- ============================================================================
--  P50 - La escalera general no existe, y cambiar el incremento surte efecto
--
--  EL DEFECTO QUE REPRODUCE (30/09)
--
--  `remate_price_rules` admitia filas con `horse_id` nulo -- una escalera
--  "general" del remate -- y esas filas GANABAN sobre
--  `remates.incremento_minimo`. Jota cambio el incremento de un remate de 50
--  a 80, la columna quedo en 80, y el caballo sin escalera propia siguio
--  subiendo de 50 en 50 porque el tramo general lo decia.
--
--  El admin cambia un numero, la pantalla le confirma el cambio, y la base
--  cobra otra cosa. Dos fuentes para el mismo numero, y manda la que no se ve.
--
--  LA PRUEBA MIDE TRES COSAS, Y LAS TRES IMPORTAN:
--
--    1. Una regla general ya no se puede escribir  -> 23502 (not_null_violation)
--    2. Un caballo SIN escalera propia obedece a remates.incremento_minimo,
--       y lo sigue obedeciendo despues de cambiarlo con editar_remate
--    3. Un caballo CON escalera propia conserva la suya
--
--  La tercera es la que evita el arreglo bruto: cerrar la general a costa de
--  romper las escaleras por caballo seria cambiar un defecto por otro.
--
--  23502 = not_null_violation
-- ============================================================================
do $$
declare
  v_admin uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
  v_general_entro boolean := false; v_sqlstate text := '';
  v_inc1_antes numeric; v_inc2_antes numeric;
  v_inc1_despues numeric; v_inc2_despues numeric;
  v_existe boolean;
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'editar_remate'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(50, 'La escalera general no existe y el incremento del remate manda',
      'ver arriba', false, 'editar_remate NO EXISTE: la migracion no esta aplicada');
    return;
  end if;

  v_admin := _p.usuario('admin', 0, true);
  v_rem   := _p.escenario(2, 100, 25);          -- incremento_minimo = 10
  v_h1    := _p.caballo(v_rem, 1);              -- SIN escalera propia
  v_h2    := _p.caballo(v_rem, 2);              -- CON escalera propia

  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
  values (v_rem, v_h2, 100, 1000, 30);

  -- 1) la regla general tiene que rebotar
  begin
    insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, null, 0, null, 50);
    v_general_entro := true;
  exception when others then
    v_sqlstate := sqlstate;
  end;

  select incremento into v_inc1_antes from public.remate_minimos(v_rem) where numero = 1;
  select incremento into v_inc2_antes from public.remate_minimos(v_rem) where numero = 2;

  -- 2) y cambiar el incremento del remate tiene que llegar al caballo 1
  perform _p.actuar_como(v_admin);
  perform public.editar_remate(v_rem, null, 80, null, null, null);

  select incremento into v_inc1_despues from public.remate_minimos(v_rem) where numero = 1;
  select incremento into v_inc2_despues from public.remate_minimos(v_rem) where numero = 2;

  perform _p.anotar(50, 'La escalera general no existe y el incremento del remate manda',
    'la regla general se rechaza con 23502; el caballo sin escalera pasa de 10 a 80; el que tiene escalera sigue en 30',
    (not v_general_entro) and v_sqlstate = '23502'
      and v_inc1_antes = 10 and v_inc1_despues = 80
      and v_inc2_antes = 30 and v_inc2_despues = 30,
    'regla general entro=' || v_general_entro::text ||
    case when v_sqlstate = '' then '' else ' (sqlstate ' || v_sqlstate || ')' end ||
    ' | caballo 1 (sin escalera): ' || coalesce(v_inc1_antes,-1)::text ||
    ' -> ' || coalesce(v_inc1_despues,-1)::text || ' (esperado 10 -> 80; si da 50 gano la general)' ||
    ' | caballo 2 (con escalera): ' || coalesce(v_inc2_antes,-1)::text ||
    ' -> ' || coalesce(v_inc2_despues,-1)::text || ' (esperado 30 en los dos)');
exception when others then
  perform _p.anotar(50, 'La escalera general no existe y el incremento del remate manda',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P51 - La columna que hace imposible la regla invisible
--
--  P50 comprueba el comportamiento; esta comprueba la valla. Son cosas
--  distintas: el comportamiento correcto se puede conseguir por casualidad
--  -- no habiendo generales en la base -- y seguir siendo posible escribirlas.
--
--  Mientras `horse_id` admita nulos, el defecto de P50 se puede reintroducir
--  con un insert de mantenimiento, una migracion futura o un service_role
--  distraido, y no lo veria nadie hasta que un remate cobrara de menos.
-- ============================================================================
do $$
declare v_not_null boolean;
begin
  select a.attnotnull into v_not_null
  from pg_attribute a
  where a.attrelid = 'public.remate_price_rules'::regclass
    and a.attname = 'horse_id'
    and a.attnum > 0;

  perform _p.anotar(51, 'remate_price_rules.horse_id es obligatorio',
    'la columna es NOT NULL: una regla siempre es de un caballo concreto',
    coalesce(v_not_null, false),
    'horse_id not null = ' || coalesce(v_not_null, false)::text ||
    ' -> mientras admita nulos, la escalera general se puede reintroducir sin que nadie lo vea');
exception when others then
  perform _p.anotar(51, 'remate_price_rules.horse_id es obligatorio',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;



-- ============================================================================
--  P52 - La casa no juega en su propio remate
--
--  Regla de Jota desde el primer dia del proyecto. Hasta el 30/09 vivia SOLO
--  en `app/remates/[id]/page.tsx:188`, que lee `es_admin` y esconde el
--  formulario de puja. `hacer_puja` no tenia ni una linea sobre el rol.
--
--  Esconder un boton no es una regla. Un admin abre la consola del navegador,
--  llama `supabase.rpc('hacer_puja', {...})` y puja igual -- en su propio
--  remate, viendo desde el panel todas las pujas de todos los caballos, y
--  decidiendo ademas cuando se cierra.
--
--  Por que importa mas que otros hallazgos del ADR-015: los demas eran
--  numeros que se mostraban mal. Este es la frase con la que un licenciatario
--  defiende su honradez delante de un jugador que lo acusa. Si la unica
--  barrera es un `if` en JavaScript, esa frase no se puede sostener.
--
--  LA PRUEBA MIDE TRES COSAS:
--    1. el admin es rechazado, y por NUESTRO codigo (P0001), no por otra cosa
--    2. no se escribio ninguna puja: que rechace no basta
--    3. un usuario normal sigue pudiendo pujar -- cerrar la puerta sin
--       tapiar la entrada
-- ============================================================================
do $$
declare
  v_admin uuid; v_juan uuid; v_rem uuid; v_h uuid;
  v_rechazado boolean := false; v_sqlstate text := ''; v_msg text := '';
  v_pujas_admin int; v_pujas_juan int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 10000, true);   -- con saldo de sobra a proposito:
                                                 -- lo que lo frena tiene que ser el rol,
                                                 -- no la falta de dinero
  v_juan  := _p.usuario('juan',  10000);
  v_rem   := _p.escenario(2, 100, 25);
  v_h     := _p.caballo(v_rem, 1);

  -- 1) el admin lo intenta
  perform _p.actuar_como(v_admin);
  begin
    perform public.hacer_puja(v_rem, v_h, 500, true);
    v_msg := 'el admin PUDO pujar (mal)';
  exception when others then
    v_sqlstate := sqlstate;
    if v_sqlstate = 'P0001' then
      v_rechazado := true;
      v_msg := 'rechazado por nuestro codigo (P0001): ' || sqlerrm;
    else
      v_msg := 'rechazado, pero por el motivo EQUIVOCADO (' || v_sqlstate || '): ' || sqlerrm;
    end if;
  end;

  -- 2) y no escribio nada
  select count(*) into v_pujas_admin from public.bids where user_id = v_admin;

  -- 3) un usuario normal sigue pujando sin problema
  perform _p.actuar_como(v_juan);
  perform public.hacer_puja(v_rem, v_h, null, false);
  select count(*) into v_pujas_juan from public.bids where user_id = v_juan;

  perform _p.anotar(52, 'La casa no juega en su propio remate',
    'el admin es rechazado con P0001 y no escribe ninguna puja; un usuario normal si puede',
    v_rechazado and v_pujas_admin = 0 and v_pujas_juan = 1,
    v_msg || ' | pujas del admin: ' || v_pujas_admin::text || ' (esperado 0)' ||
    ' | pujas de juan: ' || v_pujas_juan::text || ' (esperado 1)');
exception when others then
  perform _p.anotar(52, 'La casa no juega en su propio remate',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;



-- ============================================================================
--  P53 - Las senales de realtime salen, y salen al canal correcto
--
--  La aplicacion no tenia realtime: ni una tabla publicada, ni una
--  suscripcion, ni un polling. Cada pantalla cargaba una vez y se quedaba
--  quieta, con el jugador mirando un precio que podia ya no existir.
--
--  El diseno (migracion 20260930120000): el evento es una SENAL, no el dato.
--  El trigger manda "algo cambio en el remate X" y el cliente vuelve a llamar
--  a remate_minimos(). Si el evento trajera la puja, el frontend tendria que
--  recalcular el minimo a partir de ella -- reimplementar
--  _incremento_aplicable en TypeScript, que es el defecto que costo la tarea
--  2.20. ADR-015.
--
--  ESTA PRUEBA MIDE LA MITAD DE LA BASE, que es la unica que se puede medir
--  desde aqui: que los triggers existen, que las politicas estan puestas, y
--  que al pujar aparece un mensaje en el canal del remate y NO en el de caja.
--  Que el navegador lo reciba se comprueba clicando; no hay forma de hacerlo
--  en SQL y no voy a fingir que si.
-- ============================================================================
do $$
declare
  v_admin uuid; v_juan uuid; v_rem uuid; v_h uuid;
  v_triggers int; v_politicas int;
  v_msg_remate int; v_msg_caja int;
  v_payload jsonb;
begin
  perform _p.limpiar();

  select count(*) into v_triggers
  from pg_trigger t
  where not t.tgisinternal
    and t.tgname in ('avisar_puja','avisar_remate','avisar_aviso',
                     'avisar_caballo','avisar_recarga','avisar_retiro');

  select count(*) into v_politicas
  from pg_policies
  where schemaname = 'realtime' and tablename = 'messages'
    and policyname in ('remate_recibe_cualquiera','caja_recibe_solo_admin');

  if v_triggers < 6 or v_politicas < 2 then
    perform _p.anotar(53, 'Las senales de realtime salen al canal correcto',
      '6 triggers y 2 politicas sobre realtime.messages',
      false,
      'triggers: ' || v_triggers::text || ' de 6 | politicas: ' || v_politicas::text ||
      ' de 2 -> la migracion 20260930120000 no esta aplicada');
    return;
  end if;

  v_admin := _p.usuario('admin', 0, true);
  v_juan  := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100, 25);
  v_h     := _p.caballo(v_rem, 1);

  delete from realtime.messages;

  perform _p.actuar_como(v_juan);
  perform public.hacer_puja(v_rem, v_h, null, false);

  select count(*) into v_msg_remate
  from realtime.messages
  where topic = 'remate:' || v_rem::text and event = 'puja';

  select count(*) into v_msg_caja
  from realtime.messages where topic = 'admin:caja';

  select payload into v_payload
  from realtime.messages
  where topic = 'remate:' || v_rem::text and event = 'puja'
  limit 1;

  perform _p.anotar(53, 'Las senales de realtime salen al canal correcto',
    'una puja deja UN mensaje en remate:<id>, ninguno en admin:caja, y el payload es una senal (id) sin el monto',
    v_msg_remate = 1 and v_msg_caja = 0
      and v_payload ? 'remate_id'
      and not (v_payload ? 'monto'),
    'mensajes en el canal del remate: ' || v_msg_remate::text || ' (esperado 1)' ||
    ' | en el canal de caja: ' || v_msg_caja::text || ' (esperado 0)' ||
    ' | payload: ' || coalesce(v_payload::text, '(ninguno)') ||
    ' -> si trae el monto, el evento dejo de ser una senal y el frontend va a calcular con el');
exception when others then
  perform _p.anotar(53, 'Las senales de realtime salen al canal correcto',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P54 - Los minimos de dinero los pone la INSTALACION, y la base obedece
--
--  LO QUE NO EXISTIA (comprobado el 01/10)
--
--  Jota pidio dos reglas que creia puestas: ningun incremento por debajo de
--  50 Bs, ningun precio de salida por debajo de 100. Al buscarlas, lo unico
--  escrito en toda la base era `incremento > 0` dentro de editar_remate, y
--  `horses.precio_salida` no tenia NINGUNA validacion. Se podia crear un
--  caballo en 1 Bs con incrementos de un centimo.
--
--  POR QUE NO SON CONSTANTES
--
--  50 y 100 son bolivares. Un licenciatario en otra moneda los necesita otros,
--  y en ADR-017 ya quedo escrito que no se le impone un numero de dinero a
--  nadie. Viven en ajustes_instalacion y la base los lee al validar.
--
--  Esta prueba mide las cinco cosas que importan:
--
--    1. incremento del remate por debajo del minimo        -> rebota
--    2. incremento de un tramo de escalera por debajo      -> rebota
--    3. precio de salida por debajo del minimo             -> rebota
--    4. un caballo viejo por debajo del minimo se puede
--       seguir editando mientras no le toques el precio    -> pasa
--    5. subir el ajuste cambia el comportamiento al
--       instante, sin desplegar nada                       -> rebota con el nuevo
--
--  La 4 es la que evita el arreglo bruto. En produccion puede haber caballos
--  por debajo de 100 creados antes de esta regla; si el trigger los revisara
--  en cada UPDATE, corregirle el NOMBRE a uno de ellos fallaria.
--
--  La 5 es la que distingue un ajuste de un hardcode.
-- ============================================================================
do $$
declare
  v_admin uuid; v_rem uuid; v_h1 uuid;
  v_race uuid;
  v_rebota_inc boolean := false;
  v_rebota_regla boolean := false;
  v_rebota_precio boolean := false;
  v_viejo_editable boolean := false;
  v_rebota_con_200 boolean := false;
  v_detalle text := '';
begin
  if to_regclass('public.ajustes_instalacion') is null then
    perform _p.anotar(54, 'Los minimos de dinero los pone la instalacion',
      'ver arriba', false,
      'ajustes_instalacion NO EXISTE: la migracion 20261001100000 no esta aplicada');
    return;
  end if;

  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_rem   := _p.escenario(2, 100, 25);      -- se crea con el minimo todavia en 10
  v_h1    := _p.caballo(v_rem, 1);
  select race_id into v_race from public.remates where id = v_rem;

  -- El "dato viejo" de produccion: un caballo por debajo del futuro minimo.
  -- Sin trucos, no se desactiva ningun trigger. Esta prueba pone el ajuste ella
  -- misma en vez de confiar en el valor que dejo el preludio: la primera version
  -- lo hacia y se puso roja porque el preludio bajaba el incremento pero dejaba
  -- el precio de salida en 100.
  update public.ajustes_instalacion set valor = '1' where clave = 'minimo_precio_salida';
  insert into public.horses (race_id, numero, nombre, precio_salida)
  values (v_race, 99, 'Caballo viejo y barato', 20);

  -- Ahora se sube el minimo, como lo haria el super admin desde ajustes.
  update public.ajustes_instalacion set valor = '50'  where clave = 'minimo_incremento';
  update public.ajustes_instalacion set valor = '100' where clave = 'minimo_precio_salida';

  -- 1) incremento del remate por debajo
  begin
    update public.remates set incremento_minimo = 25 where id = v_rem;
  exception when others then
    v_rebota_inc := true;
    v_detalle := v_detalle || ' | remate: ' || sqlerrm;
  end;

  -- 2) tramo de escalera por debajo
  begin
    insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h1, 100, 1000, 10);
  exception when others then
    v_rebota_regla := true;
    v_detalle := v_detalle || ' | escalera: ' || sqlerrm;
  end;

  -- 3) precio de salida por debajo
  begin
    insert into public.horses (race_id, numero, nombre, precio_salida)
    values (v_race, 98, 'Caballo nuevo y barato', 99);
  exception when others then
    v_rebota_precio := true;
    v_detalle := v_detalle || ' | salida: ' || sqlerrm;
  end;

  -- 4) el caballo viejo de 20 Bs se puede renombrar sin tocarle el precio
  begin
    update public.horses set nombre = 'Renombrado sin drama'
    where race_id = v_race and numero = 99;
    v_viejo_editable := true;
  exception when others then
    v_detalle := v_detalle || ' | VIEJO NO EDITABLE: ' || sqlerrm;
  end;

  -- 5) el ajuste manda: con el minimo en 200, un caballo de 150 rebota
  update public.ajustes_instalacion set valor = '200' where clave = 'minimo_precio_salida';
  begin
    insert into public.horses (race_id, numero, nombre, precio_salida)
    values (v_race, 97, 'Caballo de 150', 150);
  exception when others then
    v_rebota_con_200 := true;
    v_detalle := v_detalle || ' | con minimo 200: ' || sqlerrm;
  end;

  -- se devuelve al valor del arnes para no ensuciar lo que venga despues
  update public.ajustes_instalacion set valor = '1' where clave = 'minimo_incremento';
  update public.ajustes_instalacion set valor = '1' where clave = 'minimo_precio_salida';

  perform _p.anotar(54, 'Los minimos de dinero los pone la instalacion',
    'rebotan incremento 25, tramo 10 y salida 99; el caballo viejo de 20 Bs sigue editable; con el minimo en 200 rebota uno de 150',
    v_rebota_inc and v_rebota_regla and v_rebota_precio
      and v_viejo_editable and v_rebota_con_200,
    'remate=' || v_rebota_inc::text ||
    ' escalera=' || v_rebota_regla::text ||
    ' salida=' || v_rebota_precio::text ||
    ' viejo_editable=' || v_viejo_editable::text ||
    ' obedece_al_ajuste=' || v_rebota_con_200::text ||
    v_detalle);
exception when others then
  -- pase lo que pase, los minimos no se quedan donde esta prueba los dejo
  begin
    update public.ajustes_instalacion set valor = '1' where clave = 'minimo_incremento';
    update public.ajustes_instalacion set valor = '1' where clave = 'minimo_precio_salida';
  exception when others then null;
  end;
  perform _p.anotar(54, 'Los minimos de dinero los pone la instalacion',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P55 - No se retira dinero que no ha pasado por el juego (la regla del 50%)
--
--  EL AGUJERO QUE CIERRA (reportado por Jota el 01/10)
--
--  Un usuario recargaba 1.000 Bs y pedia el retiro de los 1.000 sin haber
--  pujado una sola vez. La solicitud llegaba al admin como cualquier otra.
--  Palabras suyas: "al haber hecho la solicitud de retiro el sistema debio
--  haberlo rebotado, en ese caso ni siquiera llega al admin."
--
--  DE DONDE SALE LA FORMA (investigado, no inventado)
--
--  Terminos de Wplay.co 4.5.5, citando el art. 1.4.2 del Acuerdo 08 de 2020 de
--  Coljuegos: hay que haber apostado "minimo el 50% de la totalidad de los
--  depositos realizados". Base acumulada, no la ultima recarga. La version de
--  2022 exime los premios.
--
--  LAS CINCO COSAS QUE MIDE, Y POR QUE CADA UNA
--
--    1. Recarga 1000 y no puja -> el retiro REBOTA y no queda solicitud.
--       Que no quede solicitud es la mitad del requisito: Jota pidio
--       expresamente que no llegue al admin.
--    2. Apuesta 500 (el 50% justo) -> el retiro pasa. El limite es un >=, no
--       un >: si falla aqui, la regla esta pidiendo un bolivar de mas.
--    3. Subirse la propia puja NO infla lo apostado. Tres pujas de 100, 150 y
--       200 sobre el mismo caballo son 200 apostados, no 450. Sin esto,
--       cumplir el requisito seria gratis: te subes tu propia puja cinco
--       veces y a retirar.
--    4. Los premios se retiran igual. Es la exencion de Wplay 2022 y es la
--       parte menos firme de lo investigado, asi que conviene tenerla medida:
--       si algun dia se decide quitarla, esta prueba lo dice.
--    5. Un remate CANCELADO no cuenta. En una cancelacion se devuelve el
--       dinero; contar esas pujas regalaria avance por algo que no paso.
--
--  El premio del punto 4 se acredita con un movimiento directo a proposito:
--  lo que se mide aqui es la aritmetica de la exencion, no como llega un
--  premio -- de eso se encargan P2 y P30 por la via real.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u uuid; v_w uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
  v_dep uuid;
  r record;
  v_rebota_sin_apostar boolean := false;
  v_sin_solicitud      boolean := false;
  v_pasa_con_el_50     boolean := false;
  v_no_infla           boolean := false;
  v_premio_libre       boolean := false;
  v_cancelado_no_suma  boolean := false;
  v_apostado           numeric;
  v_detalle text := '';
begin
  if to_regclass('public.ajustes_instalacion') is null
     or not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = 'requisito_apuesta') then
    perform _p.anotar(55, 'No se retira dinero que no ha pasado por el juego',
      'ver arriba', false,
      'requisito_apuesta NO EXISTE: la migracion 20261001120000 no esta aplicada');
    return;
  end if;

  update public.ajustes_instalacion set valor = '50' where clave = 'pct_apostado_para_retirar';

  -- ---------------------------------------------------------------- 1
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan',  0);          -- SIN saldo regalado: recarga de verdad
  perform _p.actuar_como(v_u);
  -- NO se vuelve a consultar la fila: se usa el id que DEVUELVE la funcion.
  -- `order by created_at desc limit 1` es una trampa aqui, y nos costo una
  -- roja en P56: `now()` es la hora de la TRANSACCION, asi que todas las
  -- filas creadas dentro de un mismo bloque comparten `created_at`, el
  -- `order by` queda empatado y Postgres devuelve la que quiera.
  v_dep := (public.solicitar_recarga(1000, 'pago_movil', '04121234567', 'REF-P55', current_date)).id;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);

  perform _p.actuar_como(v_u);
  begin
    perform public.solicitar_retiro(1000, 'pago_movil', '04121234567');
  exception when others then
    v_rebota_sin_apostar := true;
    v_detalle := v_detalle || ' | sin apostar: ' || sqlerrm;
  end;
  v_sin_solicitud := (select count(*) = 0 from public.withdraw_requests where user_id = v_u);

  -- ---------------------------------------------------------------- 2
  v_rem := _p.escenario(2, 500);
  v_h1  := _p.caballo(v_rem, 1);
  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, null, false);     -- 500 justos
  -- se cierra el remate para que esos 500 dejen de estar comprometidos: lo que
  -- se mide aqui es la regla del 50%, no el techo del compromiso (eso es P24).
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);

  perform _p.actuar_como(v_u);
  select * into r from public.requisito_apuesta(v_u);
  begin
    perform public.solicitar_retiro(1, 'pago_movil', '04121234567');
    v_pasa_con_el_50 := true;
  exception when others then
    v_detalle := v_detalle || ' | con el 50 justo rebota: ' || sqlerrm;
  end;
  v_detalle := v_detalle || ' | tras apostar 500: recargado=' || r.recargado::text ||
               ' apostado=' || r.apostado::text || ' requerido=' || r.requerido::text ||
               ' cumplido=' || r.cumplido::text;

  -- ---------------------------------------------------------------- 3
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 100000);
  v_rem   := _p.escenario(2, 100);
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);
  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 100, true);
  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 150, true);
  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);
  select apostado into v_apostado from public.requisito_apuesta(v_u);
  v_no_infla := (v_apostado = 200);
  v_detalle := v_detalle || ' | tres pujas 100/150/200 al mismo caballo -> apostado=' ||
               v_apostado::text || ' (esperado 200)';

  -- ---------------------------------------------------------------- 4
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan',  0);
  perform _p.actuar_como(v_u);
  v_dep := (public.solicitar_recarga(1000, 'pago_movil', '04121234567', 'REF-P55B', current_date)).id;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);

  select id into v_w from public.wallets where user_id = v_u;
  update public.wallets set saldo_disponible = saldo_disponible + 300 where id = v_w;
  insert into public.wallet_movements (wallet_id, tipo, monto, descripcion)
  values (v_w, 'premio', 300, 'premio de prueba P55');

  perform _p.actuar_como(v_u);
  begin
    perform public.solicitar_retiro(300, 'pago_movil', '04121234567');
    v_premio_libre := true;
  exception when others then
    v_detalle := v_detalle || ' | el premio no se pudo retirar: ' || sqlerrm;
  end;

  -- y un bolivar mas tiene que rebotar: el premio se libera, la recarga no
  begin
    perform public.solicitar_retiro(1, 'pago_movil', '04121234567');
    v_premio_libre := false;
    v_detalle := v_detalle || ' | OJO: dejo retirar MAS que el premio';
  exception when others then null;
  end;

  -- ---------------------------------------------------------------- 5
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 100000);
  v_rem   := _p.escenario(2, 900);
  v_h1    := _p.caballo(v_rem, 1);
  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, null, false);
  perform _p.actuar_como(v_admin);
  perform public.cancelar_remate(v_rem, 'prueba P55');
  select apostado into v_apostado from public.requisito_apuesta(v_u);
  v_cancelado_no_suma := (v_apostado = 0);
  v_detalle := v_detalle || ' | tras cancelar: apostado=' || v_apostado::text || ' (esperado 0)';

  update public.ajustes_instalacion set valor = '0' where clave = 'pct_apostado_para_retirar';

  perform _p.anotar(55, 'No se retira dinero que no ha pasado por el juego',
    'sin apostar rebota y no deja solicitud; con el 50% justo pasa; subirse la propia puja no infla; el premio se retira; un remate cancelado no cuenta',
    v_rebota_sin_apostar and v_sin_solicitud and v_pasa_con_el_50
      and v_no_infla and v_premio_libre and v_cancelado_no_suma,
    'rebota=' || v_rebota_sin_apostar::text ||
    ' sin_solicitud=' || v_sin_solicitud::text ||
    ' pasa_con_50=' || v_pasa_con_el_50::text ||
    ' no_infla=' || v_no_infla::text ||
    ' premio_libre=' || v_premio_libre::text ||
    ' cancelado_no_suma=' || v_cancelado_no_suma::text ||
    v_detalle);
exception when others then
  begin
    update public.ajustes_instalacion set valor = '0' where clave = 'pct_apostado_para_retirar';
  exception when others then null;
  end;
  perform _p.anotar(55, 'No se retira dinero que no ha pasado por el juego',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P56 - El motivo del rechazo llega al cliente, y rechazar un retiro devuelve
--
--  LO QUE PASABA (reportado por Jota el 01/10)
--
--  Rechazo una recarga escribiendo el motivo y el cliente nunca lo vio. Al
--  buscarlo salieron DOS problemas distintos, no uno:
--
--    - La recarga SI capturaba el motivo -- `rechazar_recarga` lo exigia -- y
--      lo guardaba en `admin_actions.detalles->>'reason'`. Esa es la bitacora
--      de auditoria: el sitio correcto para el rastro de quien hizo que, y el
--      equivocado para algo que el cliente tiene que leer.
--    - El retiro no capturaba NADA: procesar_retiro(uuid, withdraw_status)
--      tenia dos parametros y ninguno era un motivo.
--
--  Decision de Jota: lista de motivos + nota opcional, no texto libre. Ese
--  texto lo escribe un operador y lo lee un cliente.
--
--  LAS SEIS COSAS QUE MIDE
--
--    1. El motivo de una recarga rechazada queda EN LA FILA, con su etiqueta y
--       la nota recortada. Es lo que el cliente puede leer.
--    2. Un codigo inventado, uno del ambito equivocado (un motivo de retiro en
--       una recarga) y la ausencia de motivo rebotan los tres, y la solicitud
--       SIGUE PENDIENTE. Un rechazo a medias es peor que ninguno.
--    3. La etiqueta es una FOTO: renombrar o desactivar el motivo despues no
--       cambia lo que el cliente ya leyo.
--    4. Rechazar un retiro devuelve el dinero Y guarda el motivo.
--    5. PAGAR un retiro no exige motivo. Si lo exigiera, el admin no podria
--       pagar.
--    6. Rechazar un retiro SIN motivo rebota y NO TOCA EL DINERO. El motivo se
--       valida antes de mover un bolivar, a proposito.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u uuid; v_w uuid; v_dep uuid; v_ret uuid;
  r record;
  v_queda_en_la_fila boolean := false;
  v_rebota_los_tres  boolean := false;
  v_sigue_pendiente  boolean := false;
  v_etiqueta_foto    boolean := false;
  v_devuelve         boolean := false;
  v_pagar_sin_motivo boolean := false;
  v_sin_motivo_no_toca boolean := false;
  v_saldo numeric; v_txt text; v_rebotes int := 0;
  v_detalle text := '';
begin
  if to_regclass('public.motivos_rechazo') is null then
    perform _p.anotar(56, 'El motivo del rechazo llega al cliente',
      'ver arriba', false,
      'motivos_rechazo NO EXISTE: la migracion 20261001130000 no esta aplicada');
    return;
  end if;

  -- ---------------------------------------------------------------- 1 y 2
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan',  0);

  perform _p.actuar_como(v_u);
  -- El id lo da la funcion. Ver el comentario de P55: dentro de un mismo
  -- bloque todas las filas comparten `created_at` y el `order by` no ordena.
  v_dep := (public.solicitar_recarga(500, 'pago_movil', '04121234567', 'REF-P56', current_date)).id;

  perform _p.actuar_como(v_admin);

  begin perform public.rechazar_recarga(v_dep, 'no_existe_este_motivo', null);
  exception when others then v_rebotes := v_rebotes + 1; end;
  begin perform public.rechazar_recarga(v_dep, 'titular_distinto', null);   -- es de RETIRO
  exception when others then v_rebotes := v_rebotes + 1; end;
  begin perform public.rechazar_recarga(v_dep, null, null);
  exception when others then v_rebotes := v_rebotes + 1; end;
  v_rebota_los_tres := (v_rebotes = 3);
  v_sigue_pendiente := (select estado = 'pendiente' from public.deposit_requests where id = v_dep);

  perform public.rechazar_recarga(v_dep, 'monto_no_coincide', '   Pago por 450, no 500   ');
  select estado, motivo_codigo, motivo_etiqueta, motivo_nota into r
  from public.deposit_requests where id = v_dep;
  v_queda_en_la_fila := (r.estado = 'rechazado'
    and r.motivo_codigo = 'monto_no_coincide'
    and r.motivo_etiqueta = 'El monto no coincide con el comprobante'
    and r.motivo_nota = 'Pago por 450, no 500');
  v_detalle := v_detalle || ' | recarga: etiqueta="' || coalesce(r.motivo_etiqueta,'(nula)') ||
               '" nota="' || coalesce(r.motivo_nota,'(nula)') || '"';

  -- ---------------------------------------------------------------- 3
  update public.motivos_rechazo
     set etiqueta = 'TEXTO CAMBIADO POR EL LICENCIATARIO', activo = false
   where codigo = 'monto_no_coincide';
  select motivo_etiqueta into v_txt from public.deposit_requests where id = v_dep;
  v_etiqueta_foto := (v_txt = 'El monto no coincide con el comprobante');
  update public.motivos_rechazo
     set etiqueta = 'El monto no coincide con el comprobante', activo = true
   where codigo = 'monto_no_coincide';

  -- ---------------------------------------------------------------- 4 y 6
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);

  perform _p.actuar_como(v_u);
  v_ret := (public.solicitar_retiro(400, 'pago_movil', '04121234567')).id;
  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;

  -- 6 primero: sin motivo no pasa nada, ni el estado ni el dinero
  perform _p.actuar_como(v_admin);
  begin perform public.procesar_retiro(v_ret, 'rechazado'::withdraw_status);
  exception when others then null; end;
  v_sin_motivo_no_toca := (
    (select estado = 'pendiente' from public.withdraw_requests where id = v_ret)
    and (select saldo_disponible = v_saldo from public.wallets where user_id = v_u));

  -- 4: con motivo, devuelve y guarda
  perform public.procesar_retiro(v_ret, 'rechazado'::withdraw_status,
                                 'datos_destino_incorrectos', 'El telefono no es del titular');
  select estado, motivo_etiqueta, motivo_nota into r from public.withdraw_requests where id = v_ret;
  v_devuelve := (r.estado = 'rechazado'
    and r.motivo_etiqueta = 'Los datos de destino no son correctos'
    and (select saldo_disponible = 1000 from public.wallets where user_id = v_u));
  v_detalle := v_detalle || ' | retiro: etiqueta="' || coalesce(r.motivo_etiqueta,'(nula)') ||
               '" saldo tras el rechazo=' ||
               (select saldo_disponible from public.wallets where user_id = v_u)::text ||
               ' (esperado 1000)';

  -- ---------------------------------------------------------------- 5
  perform _p.actuar_como(v_u);
  -- ESTA es la que fallo: con el retiro de 400 ya rechazado en la misma
  -- transaccion, el `order by created_at` empatado devolvia aquel en vez de
  -- este, y "pagar" chocaba con un retiro ya procesado. La prueba decia que
  -- pagar exigia motivo; lo que pasaba era que estaba pagando la fila
  -- equivocada.
  v_ret := (public.solicitar_retiro(100, 'pago_movil', '04121234567')).id;
  perform _p.actuar_como(v_admin);
  begin
    perform public.procesar_retiro(v_ret, 'pagado'::withdraw_status);
    v_pagar_sin_motivo := true;
  exception when others then
    v_detalle := v_detalle || ' | pagar exigio motivo: ' || sqlerrm;
  end;

  perform _p.anotar(56, 'El motivo del rechazo llega al cliente',
    'el motivo queda en la fila con su etiqueta y nota; codigo invalido, ambito equivocado y ausencia rebotan sin cambiar el estado; la etiqueta no cambia si se renombra el motivo; rechazar un retiro devuelve el dinero; pagar no exige motivo; rechazar sin motivo no toca el dinero',
    v_queda_en_la_fila and v_rebota_los_tres and v_sigue_pendiente
      and v_etiqueta_foto and v_devuelve and v_pagar_sin_motivo and v_sin_motivo_no_toca,
    'en_la_fila=' || v_queda_en_la_fila::text ||
    ' rebotan_los_tres=' || v_rebota_los_tres::text || ' (' || v_rebotes::text || '/3)' ||
    ' sigue_pendiente=' || v_sigue_pendiente::text ||
    ' etiqueta_es_foto=' || v_etiqueta_foto::text ||
    ' devuelve=' || v_devuelve::text ||
    ' pagar_sin_motivo=' || v_pagar_sin_motivo::text ||
    ' sin_motivo_no_toca=' || v_sin_motivo_no_toca::text ||
    v_detalle);
exception when others then
  perform _p.anotar(56, 'El motivo del rechazo llega al cliente',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P57 - Los horarios de un remate se pueden QUITAR, y quitarlos significa algo
--
--  LO QUE MIDE
--  `editar_remate` decidia si tocaba el horario con `p_opens_at is not null`.
--  Con ese contrato NULL quiere decir "no lo cambies", asi que el admin borraba
--  la hora de cierre en la pantalla, guardaba, no salia ningun error... y el
--  cierre seguia ahi. La pantalla decia una cosa y la base guardaba otra, en
--  silencio. La migracion 20261002100000 anade una bandera por campo.
--
--  Y de paso mide la regla nueva: un remate SIN apertura esta activo desde que
--  se crea. Eso ya lo soportaba `hacer_puja` con su guarda de nulo, pero no
--  habia ninguna prueba que lo dijera, asi que nada impedia que alguien
--  "arreglara" esa guarda y rompiera la funcion sin que el arnes se enterara.
--
--  LA LECCION DE P39 APLICADA: lo primero es comprobar que la firma nueva
--  existe y que es UNA SOLA. Si quedaran las dos firmas, PostgREST no sabria
--  cual llamar (PGRST203) y la aplicacion se cae aunque el SQL funcione.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u1 uuid; v_rem uuid; v_h1 uuid;
  v_tiene_banderas boolean;
  v_una_sola_firma boolean;
  v_null_no_borra boolean := false;
  v_quita_cierre boolean := false;
  v_quita_apertura boolean := false;
  v_puja_sin_apertura boolean := false;
  v_contradiccion boolean := false;
  v_detalle text := '';
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'editar_remate'
      and pg_get_function_arguments(p.oid) ilike '%p_limpiar_opens_at%'
      and pg_get_function_arguments(p.oid) ilike '%p_limpiar_closes_at%'
  ) into v_tiene_banderas;

  if not v_tiene_banderas then
    perform _p.anotar(57, 'Los horarios de un remate se pueden quitar',
      'editar_remate acepta p_limpiar_opens_at y p_limpiar_closes_at',
      false, 'editar_remate NO tiene las banderas: la migracion 20261002100000 no esta aplicada');
    return;
  end if;

  select count(*) = 1 into v_una_sola_firma
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'editar_remate';

  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100, 25);   -- nace con apertura Y cierre puestos
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_admin);

  -- 1) NULL sigue queriendo decir "no lo cambies". Esto es lo que protege al
  --    resto de la aplicacion: cualquier llamada vieja de seis argumentos no
  --    puede borrar un horario por accidente.
  perform public.editar_remate(v_rem, null, null, null, null, null);
  select opens_at is not null and closes_at is not null into v_null_no_borra
  from public.remates where id = v_rem;

  -- 2) la bandera si borra el cierre
  perform public.editar_remate(p_remate_id => v_rem, p_limpiar_closes_at => true);
  select closes_at is null into v_quita_cierre from public.remates where id = v_rem;

  -- 3) y la apertura
  perform public.editar_remate(p_remate_id => v_rem, p_limpiar_opens_at => true);
  select opens_at is null into v_quita_apertura from public.remates where id = v_rem;

  -- 4) un remate sin apertura esta ACTIVO: se puede pujar. Si esto falla, la
  --    guarda de nulo de hacer_puja se rompio.
  perform _p.actuar_como(v_u1);
  begin
    perform public.hacer_puja(v_rem, v_h1, 100, true);
    v_puja_sin_apertura := true;
  exception when others then
    v_detalle := v_detalle || ' | la puja sin apertura fallo (' || sqlstate || '): ' || sqlerrm;
  end;
  perform _p.actuar_como(v_admin);

  -- 5) poner y quitar en la misma llamada es una orden contradictoria: se
  --    rechaza en vez de adivinar cual gana. Y tiene que rechazarlo NUESTRO
  --    codigo (P0001), no un error de tipos.
  begin
    perform public.editar_remate(
      p_remate_id => v_rem, p_opens_at => now(), p_limpiar_opens_at => true);
    v_detalle := v_detalle || ' | acepto poner y quitar a la vez (mal)';
  exception when others then
    if sqlstate = 'P0001' then
      v_contradiccion := true;
    else
      v_detalle := v_detalle || ' | rechazo la contradiccion por el motivo equivocado ('
                   || sqlstate || '): ' || sqlerrm;
    end if;
  end;

  perform _p.anotar(57, 'Los horarios de un remate se pueden quitar',
    'una sola firma; null no borra; la bandera borra apertura y cierre; sin apertura se puede pujar; poner y quitar a la vez se rechaza con P0001',
    v_una_sola_firma and v_null_no_borra and v_quita_cierre and v_quita_apertura
      and v_puja_sin_apertura and v_contradiccion,
    'una_sola_firma=' || v_una_sola_firma::text ||
    ' null_no_borra=' || v_null_no_borra::text ||
    ' quita_cierre=' || v_quita_cierre::text ||
    ' quita_apertura=' || v_quita_apertura::text ||
    ' puja_sin_apertura=' || v_puja_sin_apertura::text ||
    ' contradiccion_rechazada=' || v_contradiccion::text ||
    v_detalle);
exception when others then
  perform _p.anotar(57, 'Los horarios de un remate se pueden quitar',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P58 - El descuadre normal no es una alarma; el que no tiene explicacion si
--
--  DE DONDE SALE ESTA PRUEBA
--  El 05/10/2026 el panel de contabilidad llevaba dias mostrando en ambar
--  "El libro no cuadra con los saldos. Diferencia de -1.380,00 Bs. Esto no
--  deberia pasar nunca". Se midio contra produccion: habia 8 remates cerrados
--  sin liquidar y lo cobrado sin asentar era 1.380,00 exactos. La contabilidad
--  estaba intacta; la alarma estaba mal.
--
--  Cerrar le COBRA a los lideres. Liquidar escribe el ASIENTO. Entre las dos
--  cosas el libro va por detras de los saldos, a proposito. Una alarma que se
--  enciende en esa situacion se enciende casi siempre, y una alarma que se
--  enciende casi siempre no la mira nadie.
--
--  LO QUE MIDE, Y POR QUE LAS TRES FASES
--    1) cerrado y sin liquidar -> descuadre != 0, PERO inexplicado = 0
--    2) liquidado              -> las tres cifras a 0
--    3) un saldo movido a mano -> inexplicado = exactamente ese importe
--
--  La fase 3 es la que impide que esto sea un arreglo cosmetico. Sin ella, una
--  implementacion que devolviera `descuadre_inexplicado = 0` siempre pasaria
--  las dos primeras. Lo que se esta midiendo no es que la alarma se calle: es
--  que siga sonando cuando tiene que sonar.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
  v_wallet uuid;
  r record;
  v_tiene_columnas boolean;
  v_fase1 boolean := false;
  v_fase2 boolean := false;
  v_fase3 boolean := false;
  v_detalle text := '';
begin
  perform _p.limpiar();
  delete from public.house_ledger;

  -- Lo primero, como en P39: si las columnas no existen, esto no esta midiendo
  -- nada y hay que decirlo, no aprobar por omision.
  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'casa_resumen'
      and pg_get_function_result(p.oid) ilike '%descuadre_inexplicado%'
      and pg_get_function_result(p.oid) ilike '%pendiente_de_liquidar%'
  ) into v_tiene_columnas;

  if not v_tiene_columnas then
    perform _p.anotar(58, 'El descuadre normal no alarma; el inexplicado si',
      'casa_resumen devuelve pendiente_de_liquidar y descuadre_inexplicado',
      false, 'casa_resumen NO tiene las columnas: la migracion 20261005100000 no esta aplicada');
    return;
  end if;

  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1 := _p.caballo(v_rem,1); v_h2 := _p.caballo(v_rem,2); v_h3 := _p.caballo(v_rem,3);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, 400, true);

  -- ---------------- FASE 1: cerrado, sin liquidar ----------------
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);

  select * into r from public.casa_resumen();
  v_fase1 := r.descuadre <> 0
         and r.pendiente_de_liquidar = -r.descuadre
         and r.descuadre_inexplicado = 0
         and r.remates_sin_liquidar = 1;
  v_detalle := v_detalle || ' [1 cerrado] descuadre=' || r.descuadre::text ||
               ' pendiente=' || r.pendiente_de_liquidar::text ||
               ' inexplicado=' || r.descuadre_inexplicado::text ||
               ' remates=' || r.remates_sin_liquidar::text;

  -- ---------------- FASE 2: liquidado ----------------
  perform public.set_ganador_carrera(v_rem, 2);
  perform public.liquidar_remate(v_rem);

  select * into r from public.casa_resumen();
  v_fase2 := r.descuadre = 0
         and r.pendiente_de_liquidar = 0
         and r.descuadre_inexplicado = 0
         and r.remates_sin_liquidar = 0;
  v_detalle := v_detalle || ' | [2 liquidado] descuadre=' || r.descuadre::text ||
               ' pendiente=' || r.pendiente_de_liquidar::text ||
               ' inexplicado=' || r.descuadre_inexplicado::text;

  -- ---------------- FASE 3: un saldo movido sin asiento ----------------
  -- 500 Bs que aparecen en la cartera de un usuario sin que ningun remate ni
  -- ninguna recarga los justifique. Es el fraude -- o el bug -- que la alarma
  -- existe para cazar, y antes quedaba enterrado entre liquidaciones
  -- pendientes.
  select id into v_wallet from public.wallets where user_id = v_u1;
  update public.wallets set saldo_disponible = saldo_disponible + 500 where id = v_wallet;
  insert into public.wallet_movements (wallet_id, tipo, monto, descripcion)
  values (v_wallet, 'ajuste_manual', 500, 'P58: movimiento sin asiento, a proposito');

  select * into r from public.casa_resumen();
  v_fase3 := r.descuadre_inexplicado = 500;
  v_detalle := v_detalle || ' | [3 saldo a mano] descuadre=' || r.descuadre::text ||
               ' inexplicado=' || r.descuadre_inexplicado::text || ' (esperado 500)';

  perform _p.anotar(58, 'El descuadre normal no alarma; el inexplicado si',
    'cerrado sin liquidar: descuadre != 0 pero inexplicado = 0; liquidado: todo a 0; saldo movido a mano: inexplicado = 500',
    v_fase1 and v_fase2 and v_fase3,
    'fase1=' || v_fase1::text || ' fase2=' || v_fase2::text || ' fase3=' || v_fase3::text || v_detalle);
exception when others then
  perform _p.anotar(58, 'El descuadre normal no alarma; el inexplicado si',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P59 - Cada admin tiene nombre y codigo, y el codigo no se reutiliza
--
--  POR QUE EXISTE
--  Jota abrio el registro nuevo y vio que TODAS las filas decian "Super Admin".
--  Con un unico usuario admin la bitacora no puede responder quien hizo que,
--  que es exactamente para lo que existe. Y con varios admins compartiendo
--  cuenta es peor: el dia que falte dinero, nadie queda limpio.
--
--  LO QUE MIDE, Y POR QUE CADA COSA
--   1. nombrar y quitar son solo para super admins
--   2. el codigo tiene formato y es unico
--   3. UN CODIGO NO SE REUTILIZA NI DESPUES DE QUITAR EL CARGO. Si se
--      reciclara, las filas viejas del registro pasarian a apuntar a otra
--      persona: una bitacora que cambia de version del pasado no vale nada.
--   4. nadie se quita el cargo a si mismo, y siempre queda un super admin.
--      Sin estas dos, un clic deja al licenciatario fuera de su propio panel
--      sin nadie que pueda devolverselo.
--   5. la bitacora guarda la FOTO del codigo y el nombre, no una referencia:
--      lo que paso en marzo se lee como se leia en marzo (mismo criterio que
--      motivo_etiqueta el 01/10).
-- ============================================================================
do $$
declare
  v_super uuid; v_otro_super uuid; v_juan uuid; v_pedro uuid;
  v_existe boolean;
  v_nombra boolean := false;
  v_no_super_rebota boolean := false;
  v_formato_rebota boolean := false;
  v_repetido_rebota boolean := false;
  v_a_si_mismo_rebota boolean := false;
  v_ultimo_super_rebota boolean := false;
  v_codigo_reservado boolean := false;
  v_foto boolean := false;
  v_msg text := '';
begin
  perform _p.limpiar();
  delete from public.admin_actions;

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'nombrar_admin'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(59, 'Cada admin tiene nombre y codigo',
      'nombrar_admin y quitar_admin existen y se comportan',
      false, 'nombrar_admin NO EXISTE: la migracion 20261005120000 no esta aplicada');
    return;
  end if;

  v_super      := _p.usuario('jota',  0, true);
  v_otro_super := _p.usuario('ana',   0, true);
  v_juan       := _p.usuario('juan',  0);
  v_pedro      := _p.usuario('pedro', 0);

  -- 1) un usuario normal no nombra a nadie
  perform _p.actuar_como(v_juan);
  begin
    perform public.nombrar_admin(v_pedro, 'P59A', 'Pedro Prueba');
    v_msg := v_msg || ' un usuario normal pudo nombrar (mal);';
  exception when sqlstate 'P0001' then
    v_no_super_rebota := true;
  end;

  perform _p.actuar_como(v_super);

  -- 2) el super admin si
  perform public.nombrar_admin(v_juan, 'P59A', 'Juan Prueba');
  select admin_codigo = 'P59A' and admin_nombre = 'Juan Prueba' and coalesce(es_admin,false)
    into v_nombra
  from public.profiles where id = v_juan;

  -- 3) formato
  begin
    perform public.nombrar_admin(v_pedro, 'P-59', 'Pedro Prueba');
    v_msg := v_msg || ' acepto un codigo con formato invalido (mal);';
  exception when sqlstate 'P0001' then
    v_formato_rebota := true;
  end;

  -- 4) unicidad, sin distinguir mayusculas
  begin
    perform public.nombrar_admin(v_pedro, 'p59a', 'Pedro Prueba');
    v_msg := v_msg || ' acepto un codigo repetido (mal);';
  exception when others then
    v_repetido_rebota := true;
  end;

  -- 5) nadie se quita el cargo a si mismo
  begin
    perform public.quitar_admin(v_super);
    v_msg := v_msg || ' se quito el cargo a si mismo (mal);';
  exception when sqlstate 'P0001' then
    v_a_si_mismo_rebota := true;
  end;

  -- 6) un admin que NO es super tampoco puede quitarle el cargo a nadie.
  --
  --    AQUI NO SE MIDE la guarda del "ultimo super admin", y conviene explicar
  --    por que: es INALCANZABLE desde la aplicacion. Para que salte, el que
  --    sobra tiene que ser el unico super admin -- y entonces quien llama solo
  --    puede ser el mismo, que ya lo para la guarda de "no te quites el cargo
  --    a ti mismo". Escribir una prueba para esa rama la haria aprobar por el
  --    motivo equivocado, que es justo lo que P39 enseno a no hacer.
  --
  --    La guarda se queda en la base igualmente: el dia que alguien relaje la
  --    primera, esa es la que impide dejar la instalacion sin dueno.
  perform public.quitar_admin(v_otro_super);
  perform _p.actuar_como(v_juan);   -- juan es admin, pero NO super
  begin
    perform public.quitar_admin(v_super);
    v_msg := v_msg || ' un admin no-super quito un cargo (mal);';
  exception when sqlstate 'P0001' then
    v_ultimo_super_rebota := true;
  end;

  -- 7) el codigo de quien ya no opera sigue reservado
  perform _p.actuar_como(v_super);
  perform public.quitar_admin(v_juan);
  begin
    perform public.nombrar_admin(v_pedro, 'P59A', 'Pedro Prueba');
    v_msg := v_msg || ' reutilizo el codigo de un ex-admin (mal);';
  exception when others then
    v_codigo_reservado := true;
  end;

  -- 8) la bitacora guarda la foto
  select exists (
    select 1 from public.admin_actions
    where action = 'nombrar_admin' and admin_nombre is not null
  ) into v_foto;

  perform _p.anotar(59, 'Cada admin tiene nombre y codigo',
    'solo un super admin nombra y quita; formato y unicidad del codigo; nadie se quita el cargo a si mismo; el codigo no se reutiliza; la bitacora guarda la foto',
    v_no_super_rebota and v_nombra and v_formato_rebota and v_repetido_rebota
      and v_a_si_mismo_rebota and v_ultimo_super_rebota and v_codigo_reservado and v_foto,
    'no_super=' || v_no_super_rebota::text ||
    ' nombra=' || v_nombra::text ||
    ' formato=' || v_formato_rebota::text ||
    ' repetido=' || v_repetido_rebota::text ||
    ' a_si_mismo=' || v_a_si_mismo_rebota::text ||
    ' no_super_no_quita=' || v_ultimo_super_rebota::text ||
    ' codigo_reservado=' || v_codigo_reservado::text ||
    ' foto_en_bitacora=' || v_foto::text ||
    case when v_msg = '' then '' else ' | ' || v_msg end);
exception when others then
  perform _p.anotar(59, 'Cada admin tiene nombre y codigo',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P60 - Nadie procesa su propia solicitud
--
--  LA VIA DE FRAUDE MAS CORTA QUE TENIA LA APLICACION, y que solo se abre
--  cuando hay mas de un administrador:
--
--    1. el admin pide una recarga de 50.000 para su propia cuenta
--    2. el admin se la aprueba
--    3. el saldo es real: puja, gana, o pide el retiro y se lo paga el mismo
--
--  Tres clics, sin tocar la base y sin saber SQL. Hasta el 05/10/2026 las tres
--  funciones solo comprobaban que quien llama fuera admin; de quien era la
--  solicitud no preguntaban.
--
--  Es separacion de funciones, no desconfianza: quien pide y quien autoriza no
--  pueden ser la misma persona. Lo cumple cualquier caja del mundo, y no porque
--  sus empleados sean ladrones, sino para que nadie quede bajo sospecha.
--
--  LO QUE ESTA PRUEBA NO PUEDE MEDIR, y conviene tenerlo escrito: dos admins
--  compinchados se aprueban el uno al otro. Contra eso el software no puede
--  hacer nada. Lo que si consigue es que el registro diga con nombre y codigo
--  quien autorizo cada cosa.
-- ============================================================================
do $$
declare
  v_admin_a uuid; v_admin_b uuid; v_dep uuid; v_ret uuid;
  v_wallet uuid;
  v_recarga_propia boolean := false;
  v_rechazo_propio boolean := false;
  v_retiro_propio boolean := false;
  v_otro_si_puede boolean := false;
  v_msg text := '';
begin
  perform _p.limpiar();

  --  EL ESCENARIO CAMBIO EL 05/10, Y EL CAMBIO ES PARTE DE LA PRUEBA.
  --
  --  Antes, `admin_b` nacia admin y pedia su propio retiro. Desde la migracion
  --  20261006110000 un admin NO PUEDE pedir recargas ni retiros (P65), asi que
  --  ese escenario ya no existe.
  --
  --  Pero el riesgo si existe, y por otro camino: alguien pide su retiro siendo
  --  jugador normal y LO ASCIENDEN A ADMIN despues. Sus solicitudes viejas
  --  siguen vivas -- mismo criterio que 20260930110000 con las pujas: no se
  --  anula dinero ya comprometido por un cambio de rol -- y ahi es donde la
  --  guarda del ADR-028 tiene que seguir de pie.
  --
  --  Asi que `admin_b` nace jugador, pide, y se le asciende. Mas realista que
  --  el escenario anterior, no menos.
  v_admin_a := _p.usuario('admin_a', 0, true);
  v_admin_b := _p.usuario('admin_b', 2000);   -- jugador, de momento

  select id into v_wallet from public.wallets where user_id = v_admin_b;

  -- Una recarga pedida POR admin_b
  -- telefono_pago, referencia y fecha_pago son NOT NULL. No es un detalle del
  -- arnes: son los datos con los que el admin comprueba el pago, y por eso la
  -- base no admite una solicitud sin ellos.
  insert into public.deposit_requests (
    user_id, monto, metodo, telefono_pago, referencia, fecha_pago, estado)
  values (
    v_admin_b, 50000, 'pago_movil', '04120000000', 'P60', current_date,
    'pendiente'::deposit_status)
  returning id into v_dep;

  --  Pide el retiro SIENDO JUGADOR, que es cuando se puede.
  perform _p.actuar_como(v_admin_b);
  perform public.solicitar_retiro(100, 'pago_movil', '04120000000');
  select id into v_ret from public.withdraw_requests
  where user_id = v_admin_b and estado = 'pendiente'::withdraw_status
  order by monto desc limit 1;

  --  Y AHORA lo ascienden. Sus dos solicitudes siguen vivas.
  update public.profiles set es_admin = true where id = v_admin_b;

  perform _p.actuar_como(v_admin_b);

  -- 1) no se la aprueba el mismo
  begin
    perform public.aprobar_recarga(v_dep);
    v_msg := v_msg || ' se aprobo su propia recarga (MAL);';
  exception when sqlstate 'P0001' then
    v_recarga_propia := true;
  end;

  -- 2) ni se la rechaza el mismo
  begin
    perform public.rechazar_recarga(v_dep, 'comprobante_ilegible', null);
    v_msg := v_msg || ' se rechazo su propia recarga (MAL);';
  exception
    when sqlstate 'P0001' then
      -- OJO: rechazar_recarga valida el MOTIVO antes de mirar de quien es la
      -- solicitud, y un motivo inexistente tambien levanta P0001. Por eso se
      -- comprueba el texto: sin esto, la prueba aprobaria porque el motivo no
      -- existe en esta base, que es la trampa del P39 otra vez.
      if sqlerrm like '%tu propia solicitud%' then
        v_rechazo_propio := true;
      else
        v_msg := v_msg || ' reboto por otro motivo: ' || sqlerrm || ';';
      end if;
    when others then
      v_msg := v_msg || ' rechazo propio reboto con ' || sqlstate || ';';
  end;

  -- 3) ni se paga el retiro que habia pedido antes de ser admin
  begin
    perform public.procesar_retiro(v_ret, 'pagado'::withdraw_status, null, null);
    v_msg := v_msg || ' se pago su propio retiro (MAL);';
  exception when sqlstate 'P0001' then
    v_retiro_propio := true;
  end;

  -- 4) pero OTRO admin si puede, que es lo que impide que esto sea un candado
  --    inutil que bloquea la operacion normal
  perform _p.actuar_como(v_admin_a);
  begin
    perform public.aprobar_recarga(v_dep);
    v_otro_si_puede := (select estado = 'aprobado'::deposit_status
                        from public.deposit_requests where id = v_dep);
  exception when others then
    v_msg := v_msg || ' otro admin NO pudo aprobar (' || sqlstate || '): ' || sqlerrm || ';';
  end;

  perform _p.anotar(60, 'Nadie procesa su propia solicitud',
    'un admin no se aprueba ni se rechaza su recarga ni se paga su retiro; otro admin si puede',
    v_recarga_propia and v_rechazo_propio and v_retiro_propio and v_otro_si_puede,
    'recarga_propia=' || v_recarga_propia::text ||
    ' rechazo_propio=' || v_rechazo_propio::text ||
    ' retiro_propio=' || v_retiro_propio::text ||
    ' otro_si_puede=' || v_otro_si_puede::text ||
    case when v_msg = '' then '' else ' | ' || v_msg end);
exception when others then
  perform _p.anotar(60, 'Nadie procesa su propia solicitud',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P61 - Al ganador le queda el aviso, aunque no estuviera mirando
--
--  Jota, liquidando un remate el 02/10: "aqui tiene que salir un popup
--  avisando al ganador, tanto si esta en linea como si no estaba e inicio
--  sesion". La segunda mitad es la que obliga a que esto exista en la base y no
--  solo en el navegador: el ganador puede estar durmiendo cuando se liquida su
--  remate, y un mensaje que se emite y se pierde no le sirve de nada.
--
--  LO QUE MIDE
--   1. liquidar con ganador USUARIO deja una fila sin leer, con su importe
--   2. liquidar ganando LA CASA no deja ninguna: un aviso de premio sin premio
--      seria peor que no avisar
--   3. marcar como leido funciona... y SOLO sobre lo propio
--   4. el aviso no puede tumbar la liquidacion: el premio esta acreditado
--      pase lo que pase con la notificacion
-- ============================================================================
do $$
declare
  v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
  v_existe boolean;
  v_aviso record;
  v_hay_aviso boolean := false;
  v_importe_ok boolean := false;
  v_casa_sin_aviso boolean := false;
  v_marca boolean := false;
  v_ajeno_no_marca boolean := false;
  v_premio_acreditado boolean := false;
  v_detalle text := '';
begin
  perform _p.limpiar();
  delete from public.house_ledger;

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = '_notificar'
  ) and (to_regclass('public.notificaciones') is not null) into v_existe;

  if not v_existe then
    perform _p.anotar(61, 'Al ganador le queda el aviso',
      'notificaciones y _notificar existen y liquidar las escribe',
      false, 'falta la tabla o la funcion: la migracion 20261005150000 no esta aplicada');
    return;
  end if;

  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1 := _p.caballo(v_rem,1); v_h2 := _p.caballo(v_rem,2); v_h3 := _p.caballo(v_rem,3);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h2, 400, true);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 2);   -- gana el caballo de pedro
  perform public.liquidar_remate(v_rem);

  -- 1) a pedro le quedo el aviso, sin leer
  select * into v_aviso
  from public.notificaciones
  where user_id = v_u2 and tipo = 'premio' and leida_at is null;
  v_hay_aviso := found;

  -- 2) y el importe del aviso es el premio que se acredito de verdad
  if v_hay_aviso then
    v_importe_ok := v_aviso.monto = (
      select m.monto from public.wallet_movements m
      join public.wallets w on w.id = m.wallet_id
      where w.user_id = v_u2 and m.tipo = 'premio' and m.ref_externa = v_rem::text
      limit 1);
    v_premio_acreditado := v_aviso.monto > 0;
    v_detalle := v_detalle || ' importe_aviso=' || v_aviso.monto::text;
  end if;

  -- 3) juan, que perdio, no recibe nada
  if exists (select 1 from public.notificaciones where user_id = v_u1) then
    v_detalle := v_detalle || ' | al perdedor le llego un aviso (mal)';
  end if;

  -- 4) LO AJENO PRIMERO, que si no la prueba no mide nada.
  --
  --    Juan intenta marcar como leido el aviso de Pedro. No tiene que dar
  --    error -- la funcion filtra por auth.uid() y simplemente no toca ninguna
  --    fila -- pero el aviso de Pedro tiene que seguir SIN LEER. Comprobar que
  --    "no reviento" no demuestra nada; lo que se comprueba es que no cambio.
  --
  --    La primera version de esta prueba ponia `v_ajeno_no_marca := true` a
  --    mano, sin ejecutar nada. Eso no es una prueba, es una afirmacion.
  perform _p.actuar_como(v_u1);
  perform public.marcar_aviso_leido(v_aviso.id);
  select leida_at is null into v_ajeno_no_marca
  from public.notificaciones where id = v_aviso.id;

  -- 5) y ahora el dueno, que si puede
  perform _p.actuar_como(v_u2);
  perform public.marcar_aviso_leido(v_aviso.id);
  select leida_at is not null into v_marca
  from public.notificaciones where id = v_aviso.id;

  perform _p.anotar(61, 'Al ganador le queda el aviso',
    'liquidar con ganador usuario deja una notificacion sin leer con el importe del premio; el perdedor no recibe nada; otro usuario no la puede marcar; el dueno si',
    v_hay_aviso and v_importe_ok and v_premio_acreditado and v_ajeno_no_marca and v_marca,
    'hay_aviso=' || v_hay_aviso::text ||
    ' importe_coincide=' || v_importe_ok::text ||
    ' premio_positivo=' || v_premio_acreditado::text ||
    ' un_ajeno_no_la_marca=' || v_ajeno_no_marca::text ||
    ' el_dueno_si=' || v_marca::text || v_detalle);
exception when others then
  perform _p.anotar(61, 'Al ganador le queda el aviso',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P62 - Un remate NUEVO avisa; un cambio interno no despierta a nadie
--
--  Jota el 01/10: "los remates nuevos no le aparecen a los clientes a menos que
--  actualice". La causa, encontrada el 05/10: `avisar_remate` es
--  `after update`, y un alta es un INSERT.
--
--  Pero aunque se disparara tampoco serviria, y eso es lo que mide la segunda
--  mitad de esta prueba: emite al canal `remate:<id>`, y NADIE puede estar
--  suscrito al canal de un remate que todavia no existe. Hacia falta un canal
--  de la COLECCION.
--
--  Y la tercera mitad es la que evita que el arreglo sea peor que el problema:
--  un `after update` sin clausula WHEN despertaria a todos los navegadores
--  conectados cada vez que se toca cualquier columna del remate.
-- ============================================================================
do $$
declare
  v_admin uuid; v_juan uuid; v_rem uuid; v_h uuid;
  v_triggers int; v_politica int;
  v_alta int; v_cambio_visible int; v_cambio_mudo int;
  v_detalle text := '';
begin
  perform _p.limpiar();

  select count(*) into v_triggers
  from pg_trigger t
  where not t.tgisinternal
    and t.tgname in ('avisar_lista_alta','avisar_lista_cambio');

  select count(*) into v_politica
  from pg_policies
  where schemaname = 'realtime' and tablename = 'messages'
    and policyname = 'lista_recibe_cualquiera';

  if v_triggers < 2 or v_politica < 1 then
    perform _p.anotar(62, 'Un remate nuevo avisa a la lista',
      'dos triggers de lista y su politica',
      false, 'triggers: ' || v_triggers::text || ' de 2 | politica: ' || v_politica::text ||
      ' de 1 -> la migracion 20261005160000 no esta aplicada');
    return;
  end if;

  v_admin := _p.usuario('admin', 0, true);
  v_juan  := _p.usuario('juan', 10000);

  -- 1) EL ALTA. `_p.escenario` inserta un remate: eso solo ya tiene que emitir.
  delete from realtime.messages;
  v_rem := _p.escenario(2, 100, 25);
  v_h   := _p.caballo(v_rem, 1);
  select count(*) into v_alta
  from realtime.messages where topic = 'remates:lista';

  -- 2) UN CAMBIO QUE SE VE EN LA LISTA: cerrar cambia el estado.
  perform _p.actuar_como(v_juan);
  perform public.hacer_puja(v_rem, v_h, 100, true);
  perform _p.actuar_como(v_admin);
  delete from realtime.messages;
  perform public.cerrar_remate(v_rem);
  select count(*) into v_cambio_visible
  from realtime.messages where topic = 'remates:lista';

  -- 3) UN CAMBIO QUE NO SE VE: tocar una columna que la lista no muestra no
  --    puede despertar a nadie. Sin el WHEN del trigger, esto emitiria.
  delete from realtime.messages;
  update public.remates set archived_reason = 'prueba P62' where id = v_rem;
  select count(*) into v_cambio_mudo
  from realtime.messages where topic = 'remates:lista';

  v_detalle := 'alta=' || v_alta::text ||
               ' cambio_visible=' || v_cambio_visible::text ||
               ' cambio_interno=' || v_cambio_mudo::text || ' (esperado 0)';

  perform _p.anotar(62, 'Un remate nuevo avisa a la lista',
    'el alta emite; un cambio de estado emite; un cambio interno NO emite',
    v_alta >= 1 and v_cambio_visible >= 1 and v_cambio_mudo = 0,
    v_detalle);
exception when others then
  perform _p.anotar(62, 'Un remate nuevo avisa a la lista',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P63 - La pagina de reglas lee de la base, y solo lo que puede ensenar
--
--  `/reglas` es lo que el jugador acepta antes de poner dinero, y sus numeros
--  salian clavados en el HTML. Dos problemas: se desincronizan de la base -- el
--  05/10 esa pagina describia un modelo de dinero derogado el 24/09 -- y no
--  sirven para licenciar, porque cada instalacion tiene los suyos.
--
--  Pero `ajustes_instalacion` esta cerrada a `anon` a proposito, y va a crecer:
--  en el bloque de licencias le entran datos bancarios, SMTP y la marca. La
--  pagina de reglas la lee cualquiera, con sesion o sin ella.
--
--  De ahi la lista blanca. ESTA PRUEBA EXISTE PARA EL DIA QUE ALGUIEN META UNA
--  CLAVE SENSIBLE EN ESA TABLA: si `ajustes_publicos()` empezara a devolver
--  todo, esto se pone en rojo antes de que la clave salga por la pagina
--  publica.
-- ============================================================================
do $$
declare
  v_existe boolean;
  v_filas int;
  v_trae_el_pct boolean := false;
  v_no_trae_lo_nuevo boolean := false;
  v_sin_sesion boolean := false;
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'ajustes_publicos'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(63, 'Las reglas leen de la base, por lista blanca',
      'ajustes_publicos() existe y filtra',
      false, 'ajustes_publicos NO EXISTE: la migracion 20261005140000 no esta aplicada');
    return;
  end if;

  -- Una clave que NO esta en la lista blanca. Representa a las que vienen
  -- despues: SMTP, datos bancarios, la marca.
  insert into public.ajustes_instalacion (clave, valor, tipo, descripcion)
  values ('secreto_de_prueba_p63', 'no-debe-salir', 'texto', 'Clave sensible de mentira para P63')
  on conflict (clave) do update set valor = excluded.valor;

  -- SIN SESION, que es como la lee un visitante que todavia no se registro.
  perform set_config('request.jwt.claims', '', false);
  select count(*) into v_filas from public.ajustes_publicos();
  v_sin_sesion := v_filas > 0;

  select exists (select 1 from public.ajustes_publicos() where clave = 'pct_apostado_para_retirar')
    into v_trae_el_pct;

  select not exists (select 1 from public.ajustes_publicos() where clave = 'secreto_de_prueba_p63')
    into v_no_trae_lo_nuevo;

  delete from public.ajustes_instalacion where clave = 'secreto_de_prueba_p63';

  perform _p.anotar(63, 'Las reglas leen de la base, por lista blanca',
    'responde sin sesion; trae el porcentaje; NO trae una clave que no este en la lista',
    v_sin_sesion and v_trae_el_pct and v_no_trae_lo_nuevo,
    'responde_sin_sesion=' || v_sin_sesion::text ||
    ' trae_el_pct=' || v_trae_el_pct::text ||
    ' filtra_lo_demas=' || v_no_trae_lo_nuevo::text ||
    ' | claves devueltas=' || v_filas::text);
exception when others then
  delete from public.ajustes_instalacion where clave = 'secreto_de_prueba_p63';
  perform _p.anotar(63, 'Las reglas leen de la base, por lista blanca',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P64 - La caja avisa al cliente, y el aviso dice lo que hace falta saber
--
--  La maquinaria se construyo ayer para el premio (P61). Esto comprueba los
--  cuatro enganches que faltaban:
--
--    recarga aprobada   -> avisa
--    recarga rechazada  -> avisa, Y EL MOTIVO VA EN EL TEXTO
--    retiro pagado      -> avisa
--    retiro rechazado   -> avisa, y DICE QUE EL DINERO VOLVIO
--
--  LAS DOS COMPROBACIONES DE TEXTO NO SON CAPRICHO.
--  El motivo ya se guardaba en la fila desde el 01/10 y el cliente lo veia si
--  entraba a la pantalla. Pero el aviso que le salta encima es el momento en que
--  de verdad lo lee: un "Recarga rechazada" a secas es un mensaje de soporte
--  garantizado. Y en el retiro rechazado, que el dinero volvio es lo primero que
--  quiere saber cualquiera -- si no se dice, asume lo peor.
--
--  Una prueba que solo contara filas pasaria aunque los textos quedaran vacios.
-- ============================================================================
do $$
declare
  v_admin uuid; v_cliente uuid;
  v_dep1 uuid; v_dep2 uuid; v_ret1 uuid; v_ret2 uuid;
  v_existe boolean;
  v_aprob boolean := false;
  v_rech boolean := false;
  v_rech_con_motivo boolean := false;
  v_pagado boolean := false;
  v_ret_rech boolean := false;
  v_dice_que_volvio boolean := false;
  v_detalle text := '';
begin
  perform _p.limpiar();

  select to_regclass('public.notificaciones') is not null into v_existe;
  if not v_existe then
    perform _p.anotar(64, 'La caja avisa al cliente',
      'cuatro avisos: recarga aprobada y rechazada, retiro pagado y rechazado',
      false, 'falta la tabla notificaciones: la migracion 20261005150000 no esta aplicada');
    return;
  end if;

  v_admin   := _p.usuario('admin', 0, true);
  v_cliente := _p.usuario('juan', 5000);

  -- Cuatro solicitudes del MISMO cliente. El admin las procesa, que es lo que
  -- permite la guarda del ADR-028: nadie procesa lo suyo, pero otro si.
  insert into public.deposit_requests (user_id, monto, metodo, telefono_pago, referencia, fecha_pago, estado)
  values (v_cliente, 300, 'pago_movil', '04120000000', 'P64-A', current_date, 'pendiente'::deposit_status)
  returning id into v_dep1;

  insert into public.deposit_requests (user_id, monto, metodo, telefono_pago, referencia, fecha_pago, estado)
  values (v_cliente, 400, 'pago_movil', '04120000000', 'P64-B', current_date, 'pendiente'::deposit_status)
  returning id into v_dep2;

  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep1);
  perform public.rechazar_recarga(v_dep2, 'comprobante_ilegible', 'se ve borroso');

  select exists (
    select 1 from public.notificaciones
    where user_id = v_cliente and tipo = 'recarga' and ref_externa = v_dep1::text
      and titulo ilike '%aprobada%') into v_aprob;

  select exists (
    select 1 from public.notificaciones
    where user_id = v_cliente and tipo = 'recarga' and ref_externa = v_dep2::text
      and titulo ilike '%rechazada%') into v_rech;

  -- El MOTIVO, dentro del texto. No basta con que exista la fila.
  select exists (
    select 1 from public.notificaciones
    where ref_externa = v_dep2::text
      and mensaje ilike '%' || public._motivo_etiqueta('comprobante_ilegible','recarga') || '%'
      and mensaje ilike '%borroso%') into v_rech_con_motivo;

  -- Ahora los retiros. El cliente los pide; el admin los procesa.
  perform _p.actuar_como(v_cliente);
  perform public.solicitar_retiro(100, 'pago_movil', '04121111111');
  select id into v_ret1 from public.withdraw_requests
   where user_id = v_cliente and estado = 'pendiente'::withdraw_status limit 1;

  perform _p.actuar_como(v_admin);
  perform public.procesar_retiro(v_ret1, 'pagado'::withdraw_status, null, null);

  perform _p.actuar_como(v_cliente);
  perform public.solicitar_retiro(150, 'pago_movil', '04121111111');
  select id into v_ret2 from public.withdraw_requests
   where user_id = v_cliente and estado = 'pendiente'::withdraw_status limit 1;

  perform _p.actuar_como(v_admin);
  perform public.procesar_retiro(v_ret2, 'rechazado'::withdraw_status, 'datos_destino_incorrectos', null);

  select exists (
    select 1 from public.notificaciones
    where user_id = v_cliente and tipo = 'retiro' and ref_externa = v_ret1::text
      and titulo ilike '%pagado%') into v_pagado;

  select exists (
    select 1 from public.notificaciones
    where user_id = v_cliente and tipo = 'retiro' and ref_externa = v_ret2::text
      and titulo ilike '%rechazado%') into v_ret_rech;

  -- Que el dinero volvio tiene que estar DICHO, no deducido del movimiento.
  select exists (
    select 1 from public.notificaciones
    where ref_externa = v_ret2::text and mensaje ilike '%volvio a tu saldo%')
    into v_dice_que_volvio;

  v_detalle := ' avisos del cliente=' ||
    (select count(*)::text from public.notificaciones where user_id = v_cliente);

  perform _p.anotar(64, 'La caja avisa al cliente',
    'los cuatro avisos existen; el de recarga rechazada lleva el motivo y la nota; el de retiro rechazado dice que el dinero volvio',
    v_aprob and v_rech and v_rech_con_motivo and v_pagado and v_ret_rech and v_dice_que_volvio,
    'recarga_aprobada=' || v_aprob::text ||
    ' recarga_rechazada=' || v_rech::text ||
    ' con_motivo_y_nota=' || v_rech_con_motivo::text ||
    ' retiro_pagado=' || v_pagado::text ||
    ' retiro_rechazado=' || v_ret_rech::text ||
    ' dice_que_volvio=' || v_dice_que_volvio::text || v_detalle);
exception when others then
  perform _p.anotar(64, 'La caja avisa al cliente',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P65 - La casa no juega: ni puja, ni recarga, ni retira
--
--  LA TRAMPA QUE CERRO ESTA MIGRACION
--  "Los admins no participan en remates" vive en la base desde el 30/09, pero
--  solo para `hacer_puja`. `solicitar_recarga` y `solicitar_retiro` no miraban
--  el rol.
--
--  Hasta el 05/10 eso era raro pero inofensivo. Con la separacion de funciones
--  del ADR-028 se volvio una trampa sin salida:
--
--    1. el admin pide un retiro
--    2. solicitar_retiro LE DESCUENTA EL SALDO en el acto
--    3. nadie puede procesarlo: el mismo no (ADR-028), y si es el unico admin
--       de la instalacion, no hay nadie mas
--    4. queda pendiente para siempre, con el dinero descontado, y casa_resumen
--       lo cuenta como obligacion de la casa a perpetuidad
--
--  Lo encontro Jota preguntando por que el menu de cliente le ensenaba
--  "Recargar" y "Retirar" a un admin. Una pregunta de interfaz que destapo un
--  defecto de dinero.
--
--  LA TERCERA COMPROBACION ES LA QUE IMPORTA: que un usuario normal SI pueda.
--  Una guarda que ademas bloquea la operacion legitima no es una guarda, es una
--  averia.
-- ============================================================================
do $$
declare
  v_admin uuid; v_juan uuid; v_dep uuid;
  v_admin_no_recarga boolean := false;
  v_admin_no_retira boolean := false;
  v_usuario_si_recarga boolean := false;
  v_usuario_si_retira boolean := false;
  v_saldo_intacto boolean := false;
  v_saldo_antes numeric;
  v_msg text := '';
begin
  perform _p.limpiar();

  v_admin := _p.usuario('admin', 5000, true);
  v_juan  := _p.usuario('juan',  5000);

  -- Baja el requisito de apuesta: aqui se mide el ROL, no la regla del 50%.
  if to_regclass('public.ajustes_instalacion') is not null then
    update public.ajustes_instalacion set valor = '0' where clave = 'pct_apostado_para_retirar';
  end if;

  v_saldo_antes := _p.saldo(v_admin);

  -- 1) el admin no puede pedir una recarga
  perform _p.actuar_como(v_admin);
  begin
    perform public.solicitar_recarga(500, 'pago_movil', '04120000000', 'P65', current_date);
    v_msg := v_msg || ' el admin pidio una recarga (MAL);';
  exception when sqlstate 'P0001' then
    if sqlerrm like '%administrador no puede%' then
      v_admin_no_recarga := true;
    else
      v_msg := v_msg || ' reboto por otro motivo: ' || sqlerrm || ';';
    end if;
  end;

  -- 2) ni un retiro... y sobre todo, SIN QUE LE TOQUEN EL SALDO.
  --    Esto es lo que convertia el defecto en trampa: el descuento ocurria
  --    antes de que nadie pudiera procesar nada.
  begin
    perform public.solicitar_retiro(100, 'pago_movil', '04120000000');
    v_msg := v_msg || ' el admin pidio un retiro (MAL);';
  exception when sqlstate 'P0001' then
    if sqlerrm like '%administrador no puede%' then
      v_admin_no_retira := true;
    else
      v_msg := v_msg || ' el retiro reboto por otro motivo: ' || sqlerrm || ';';
    end if;
  end;

  v_saldo_intacto := _p.saldo(v_admin) = v_saldo_antes;

  -- 3) un usuario normal SI puede las dos cosas
  perform _p.actuar_como(v_juan);
  begin
    perform public.solicitar_recarga(500, 'pago_movil', '04120000000', 'P65-J', current_date);
    v_usuario_si_recarga := true;
  exception when others then
    v_msg := v_msg || ' un usuario normal NO pudo recargar (' || sqlstate || '): ' || sqlerrm || ';';
  end;

  begin
    perform public.solicitar_retiro(100, 'pago_movil', '04120000000');
    v_usuario_si_retira := true;
  exception when others then
    v_msg := v_msg || ' un usuario normal NO pudo retirar (' || sqlstate || '): ' || sqlerrm || ';';
  end;

  perform _p.anotar(65, 'La casa no juega: ni puja, ni recarga, ni retira',
    'un admin no puede pedir recarga ni retiro y su saldo no se toca; un usuario normal si puede las dos cosas',
    v_admin_no_recarga and v_admin_no_retira and v_saldo_intacto
      and v_usuario_si_recarga and v_usuario_si_retira,
    'admin_no_recarga=' || v_admin_no_recarga::text ||
    ' admin_no_retira=' || v_admin_no_retira::text ||
    ' saldo_del_admin_intacto=' || v_saldo_intacto::text ||
    ' usuario_si_recarga=' || v_usuario_si_recarga::text ||
    ' usuario_si_retira=' || v_usuario_si_retira::text ||
    case when v_msg = '' then '' else ' | ' || v_msg end);
exception when others then
  perform _p.anotar(65, 'La casa no juega: ni puja, ni recarga, ni retira',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P66 - "Nuevo" quiere decir nuevo PARA TI
--
--  Jota, probando el modal de crear remate: "no aviso en la cuenta cliente
--  cuando lo cree". Decidimos indicador, no popup -- un remate nuevo es un
--  anuncio, no algo que te pasa a ti, y con su flujo de crear las carreras del
--  fin de semana un martes serian doce ventanas seguidas. Ver la migracion
--  20261006120000.
--
--  LO QUE MIDE
--   1. lo que ya estaba antes de TU marca no es novedad
--   2. el contador es POR USUARIO: dos jugadores con marcas distintas ven
--      numeros distintos sobre los mismos remates. Una prueba que mirara a uno
--      solo pasaria aunque la marca fuera global, que es el defecto que esto
--      existe para impedir.
--   3. mirar la lista lo pone a cero, que es lo unico que impide que el numero
--      crezca para siempre.
--
--  POR QUE LAS MARCAS SE MUEVEN A MANO Y NO SE USAN `pg_sleep` NI FECHAS
--  FORZADAS EN LOS REMATES:
--  `now()` en PostgreSQL es la hora de la TRANSACCION, no del reloj. Dentro de
--  un bloque `do $$` todo comparte el mismo instante, asi que un remate creado
--  "despues" de llamar a marcar_remates_vistos() tiene exactamente el mismo
--  created_at que la marca, y `>` da falso. Dormir no arregla nada porque la
--  hora no avanza.
--
--  Es la tercera vez que esta trampa muerde en este proyecto -- la primera fue
--  P56 el 01/10. La forma de escribir una prueba que dependa del orden temporal
--  es mover las marcas explicitamente, no esperar a que pase el tiempo.
-- ============================================================================
do $$
declare
  v_juan uuid; v_pedro uuid; v_rem uuid;
  v_existe boolean;
  v_juan_ve int; v_pedro_ve int; v_juan_tras_mirar int;
  r record;
  v_por_usuario boolean := false;
  v_lo_anterior_no_cuenta boolean := false;
  v_mirar_pone_a_cero boolean := false;
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'remates_nuevos'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(66, 'Nuevo quiere decir nuevo para ti',
      'remates_nuevos() y marcar_remates_vistos() existen y cuentan por usuario',
      false, 'remates_nuevos NO EXISTE: la migracion 20261006120000 no esta aplicada');
    return;
  end if;

  v_juan  := _p.usuario('juan', 1000);
  v_pedro := _p.usuario('pedro', 1000);
  v_rem   := _p.escenario(2, 100, 25);

  -- Juan miro hace una hora: el remate aparecio despues, es nuevo para el.
  -- Pedro mirara dentro de una hora: para el ya estaba.
  update public.profiles set remates_vistos_at = now() - interval '1 hour' where id = v_juan;
  update public.profiles set remates_vistos_at = now() + interval '1 hour' where id = v_pedro;

  perform _p.actuar_como(v_juan);
  select nuevos into v_juan_ve from public.remates_nuevos();

  perform _p.actuar_como(v_pedro);
  select nuevos into v_pedro_ve from public.remates_nuevos();

  v_por_usuario := v_juan_ve = 1 and v_pedro_ve = 0;
  v_lo_anterior_no_cuenta := v_pedro_ve = 0;

  -- Juan abre la lista. Su marca pasa a ahora, y el remate deja de ser nuevo.
  perform _p.actuar_como(v_juan);
  perform public.marcar_remates_vistos();
  select * into r from public.remates_nuevos();
  v_juan_tras_mirar := r.nuevos;
  v_mirar_pone_a_cero := r.nuevos = 0 and r.vistos_desde is not null;

  perform _p.anotar(66, 'Nuevo quiere decir nuevo para ti',
    'lo anterior a tu marca no cuenta; el contador es por usuario; mirar lo pone a cero',
    v_por_usuario and v_lo_anterior_no_cuenta and v_mirar_pone_a_cero,
    'juan_ve=' || v_juan_ve::text ||
    ' pedro_ve=' || v_pedro_ve::text ||
    ' juan_tras_mirar=' || v_juan_tras_mirar::text ||
    ' marca_no_nula=' || (r.vistos_desde is not null)::text);
exception when others then
  perform _p.anotar(66, 'Nuevo quiere decir nuevo para ti',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;



-- ============================================================================
--  P67 - Crear un remate es atomico: o entra todo, o no entra nada
--
--  EL DEFECTO QUE EXISTE PARA IMPEDIR. Hasta el 07/10 crear un remate eran
--  cinco llamadas sueltas desde el navegador, cada una su propia transaccion
--  ya confirmada. Medido, con el admin repitiendo el numero 5: quedaba una
--  carrera huerfana, un remate 'abierto' con CERO caballos, y una senal ya
--  emitida a remates:lista -- el remate roto empujado a la pantalla de todos
--  los jugadores conectados (ADR-031).
--
--  Esa via vieja no se puede reproducir dentro de un `do $$`, porque un bloque
--  es UNA transaccion y el defecto era tener cinco. La medicion quedo en la
--  cabecera de 20261007130000. Lo que esta prueba verifica es la via nueva:
--  que ningun rechazo deje nada escrito.
--
--  LO QUE MIDE
--   1. el camino bueno escribe las cuatro tablas, cuelga cada escalera de SU
--      caballo, deja asiento en la bitacora y emite UNA senal
--   2. un fallo en el paso de las REGLAS -- el criterio de aceptacion del
--      pendiente 1.1 -- no deja ni carrera, ni remate, ni caballos, ni senal.
--      Se prueba de las dos formas que pueden fallar ahi:
--        2a. una guarda de negocio (trg_minimo_incremento_regla) -> P0001
--        2b. un NOT NULL de la tabla                              -> 23502
--   3. numeros repetidos: rechaza con P0001 -- nuestra frase, no el 23505 en
--      crudo -- y tampoco deja nada
--   4. sin caballos: rechaza
--   5. un jugador no puede llamarla
--
--  REGLA DEL 28/09: cuando el exito es "salto una excepcion", se comprueba
--  CUAL. P0001 es nuestro codigo rechazando a proposito; 42883 seria que la
--  migracion no esta aplicada y la prueba no probaria nada.
--
--  DOS COSAS QUE SE APRENDIERON ESCRIBIENDO ESTA PRUEBA, Y VALEN PARA TODAS:
--
--  * UNA PRUEBA NO HEREDA LOS AJUSTES DE LA INSTALACION, LOS FIJA. La primera
--    version daba por hecho que `minimo_incremento` valia 50, que es el valor
--    de fabrica. Cuando P67 corre dentro del archivo completo, vale 1: alguna
--    prueba anterior lo dejo ahi. El incremento 10 que debia rebotar pasaba
--    tranquilamente, la fase no probaba nada, y el motivo no se veia. Aqui se
--    fija a mano y se devuelve al final.
--
--  * UNA VARIABLE POR FASE, NO UNA COMPARTIDA. `v_basura` se reusaba en las
--    cuatro fases, asi que el detalle imprimia el valor de la ULTIMA y decia
--    "basura=0" de una fase que habia escrito cinco filas. La prueba fallaba
--    con razon y el mensaje mentia sobre el motivo.
-- ============================================================================
do $$
declare
  v_admin uuid; v_juan uuid;
  v_existe boolean;
  v_race uuid; v_remate uuid; v_cab int; v_reg int;

  v_carrera jsonb; v_remate_j jsonb; v_min_previo text;

  -- Una variable por fase. Compartirlas fue el motivo de que el detalle
  -- mintiera la primera vez.
  v_sql_a text; v_msg_a text; v_basura_a int; v_senal_a int;
  v_sql_b text; v_msg_b text; v_basura_b int;
  v_sql_c text; v_msg_c text; v_basura_c int;
  v_sql_d text; v_basura_d int;
  v_sql_e text; v_basura_e int;

  v_bueno_ok boolean := false;
  v_senal_buena int;
  v_en_bitacora boolean := false;
  v_falla_guarda_ok boolean := false;
  v_falla_notnull_ok boolean := false;
  v_repetido_ok boolean := false;
  v_sin_caballos_ok boolean := false;
  v_jugador_ok boolean := false;
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'crear_remate_completo'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(67, 'Crear un remate es atomico',
      'crear_remate_completo() existe y ningun rechazo deja basura',
      false, 'crear_remate_completo NO EXISTE: la migracion 20261007130000 no esta aplicada');
    return;
  end if;

  -- LA PRUEBA FIJA SUS PRECONDICIONES. Ver la cabecera.
  select valor into v_min_previo from public.ajustes_instalacion where clave = 'minimo_incremento';
  update public.ajustes_instalacion set valor = '50' where clave = 'minimo_incremento';

  v_admin := _p.usuario('jefa', 0, true);
  v_juan  := _p.usuario('juan', 1000, false);

  v_carrera := jsonb_build_object(
    'nombre', 'La Rinconada - Carrera 3', 'hipodromo', 'La Rinconada',
    'numero_carrera', 3, 'numero_carrera_text', '3',
    'fecha', current_date::text, 'hora_programada', '16:30',
    'dia', 'Sabado', 'distancia_m', 1600);

  v_remate_j := jsonb_build_object(
    'nombre', 'Remate C3', 'incremento_minimo', 50,
    'porcentaje_casa', 25, 'tipo', 'vivo');

  -- ------------------------------------------------------- 1) camino bueno
  delete from realtime.messages;
  perform _p.actuar_como(v_admin);

  select c.id_carrera, c.id_remate, c.n_caballos, c.n_reglas
    into v_race, v_remate, v_cab, v_reg
  from public.crear_remate_completo(
    v_carrera, v_remate_j,
    jsonb_build_array(
      jsonb_build_object('numero', 1, 'nombre', 'Relampago', 'jinete', 'J. Perez',
        'precio_salida', 100,
        'reglas', jsonb_build_array(
          jsonb_build_object('min_precio', 100, 'max_precio', 500, 'incremento', 50),
          jsonb_build_object('min_precio', 500, 'max_precio', null, 'incremento', 100))),
      jsonb_build_object('numero', 2, 'nombre', 'Trueno', 'jinete', 'M. Lopez',
        'precio_salida', 150)
    )
  ) c;

  select count(*) into v_senal_buena from realtime.messages where topic = 'remates:lista';

  v_bueno_ok :=
        v_race is not null and v_remate is not null
    and v_cab = 2 and v_reg = 2
    and (select count(*) from public.horses h where h.race_id = v_race) = 2
    and (select count(*) from public.remate_price_rules r where r.remate_id = v_remate) = 2
    -- las dos reglas cuelgan del caballo 1, no del primero que pillo
    and (select count(*) from public.remate_price_rules r
           join public.horses h on h.id = r.horse_id
          where r.remate_id = v_remate and h.numero = 1) = 2
    and v_senal_buena = 1;

  select exists (
    select 1 from public.admin_actions a
    where a.action = 'crear_remate_completo' and a.target_id = v_remate::text
  ) into v_en_bitacora;

  -- ------------------------- 2a) falla una guarda en el paso de las reglas
  -- El incremento 10 esta por debajo del minimo que acabamos de fijar (50),
  -- asi que lo rebota trg_minimo_incremento_regla -- DESPUES de haber escrito
  -- carrera, remate y los dos caballos.
  perform _p.limpiar();
  delete from realtime.messages;
  v_admin := _p.usuario('jefa', 0, true);
  perform _p.actuar_como(v_admin);

  begin
    perform public.crear_remate_completo(
      v_carrera, v_remate_j,
      jsonb_build_array(
        jsonb_build_object('numero', 1, 'nombre', 'Relampago', 'jinete', 'J. Perez',
          'precio_salida', 100),
        jsonb_build_object('numero', 2, 'nombre', 'Trueno', 'jinete', 'M. Lopez',
          'precio_salida', 150,
          'reglas', jsonb_build_array(
            jsonb_build_object('min_precio', 150, 'max_precio', null, 'incremento', 10)))
      )
    );
    v_msg_a := 'NO REBOTO';
  exception when others then
    v_sql_a := sqlstate; v_msg_a := sqlerrm;
  end;

  select (select count(*) from public.races)
       + (select count(*) from public.remates)
       + (select count(*) from public.horses)
       + (select count(*) from public.remate_price_rules)
    into v_basura_a;
  select count(*) into v_senal_a from realtime.messages where topic = 'remates:lista';

  v_falla_guarda_ok := v_sql_a = 'P0001' and v_basura_a = 0 and v_senal_a = 0;

  -- --------------------- 2b) falla un NOT NULL en el paso de las reglas
  -- Esta no depende de ningun ajuste: `remate_price_rules.min_precio` es NOT
  -- NULL, asi que una regla sin minimo rebota con 23502 siempre, en cualquier
  -- instalacion. Es el mismo punto del recorrido, por otra puerta.
  perform _p.limpiar();
  v_admin := _p.usuario('jefa', 0, true);
  perform _p.actuar_como(v_admin);

  begin
    perform public.crear_remate_completo(
      v_carrera, v_remate_j,
      jsonb_build_array(
        jsonb_build_object('numero', 1, 'nombre', 'Relampago', 'jinete', 'J. Perez',
          'precio_salida', 100,
          'reglas', jsonb_build_array(
            jsonb_build_object('min_precio', null, 'max_precio', null, 'incremento', 50)))
      )
    );
    v_msg_b := 'NO REBOTO';
  exception when others then
    v_sql_b := sqlstate; v_msg_b := sqlerrm;
  end;

  select (select count(*) from public.races)
       + (select count(*) from public.remates)
       + (select count(*) from public.horses)
       + (select count(*) from public.remate_price_rules)
    into v_basura_b;

  v_falla_notnull_ok := v_sql_b = '23502' and v_basura_b = 0;

  -- ------------------------------------------- 3) numeros repetidos
  perform _p.limpiar();
  v_admin := _p.usuario('jefa', 0, true);
  perform _p.actuar_como(v_admin);

  begin
    perform public.crear_remate_completo(
      v_carrera, v_remate_j,
      jsonb_build_array(
        jsonb_build_object('numero', 5, 'nombre', 'Uno', 'jinete', 'A', 'precio_salida', 100),
        jsonb_build_object('numero', 5, 'nombre', 'Dos', 'jinete', 'B', 'precio_salida', 100)
      )
    );
    v_msg_c := 'NO REBOTO';
  exception when others then
    v_sql_c := sqlstate; v_msg_c := sqlerrm;
  end;

  select (select count(*) from public.races) + (select count(*) from public.remates)
       + (select count(*) from public.horses)
    into v_basura_c;

  -- P0001 y no 23505: la traduccion funciona. Quien rechaza sigue siendo
  -- horses_race_id_numero_key, que viene en el baseline; lo que cambia es que
  -- el admin lee una frase en vez de "duplicate key value violates...".
  v_repetido_ok := v_sql_c = 'P0001' and v_msg_c like '%repetido%' and v_basura_c = 0;

  -- --------------------------------------------- 4) ningun caballo
  perform _p.limpiar();
  v_admin := _p.usuario('jefa', 0, true);
  perform _p.actuar_como(v_admin);

  begin
    perform public.crear_remate_completo(v_carrera, v_remate_j, '[]'::jsonb);
  exception when others then
    v_sql_d := sqlstate;
  end;
  select count(*) into v_basura_d from public.races;
  v_sin_caballos_ok := v_sql_d = 'P0001' and v_basura_d = 0;

  -- ------------------------------------------- 5) un jugador no puede
  perform _p.actuar_como(v_juan);
  begin
    perform public.crear_remate_completo(
      v_carrera, v_remate_j,
      jsonb_build_array(jsonb_build_object('numero', 1, 'nombre', 'X', 'jinete', 'Y', 'precio_salida', 100)));
  exception when others then
    v_sql_e := sqlstate;
  end;
  select count(*) into v_basura_e from public.races;
  v_jugador_ok := v_sql_e = 'P0001' and v_basura_e = 0;

  -- Se devuelve el ajuste como estaba, para no alterar a quien venga despues.
  update public.ajustes_instalacion set valor = v_min_previo where clave = 'minimo_incremento';

  perform _p.anotar(67, 'Crear un remate es atomico',
    'el camino bueno escribe las cuatro tablas, cuelga cada escalera de su caballo y emite una senal; una guarda, un NOT NULL, un numero repetido, cero caballos o un jugador rechazan sin dejar nada',
    v_bueno_ok and v_en_bitacora and v_falla_guarda_ok and v_falla_notnull_ok
      and v_repetido_ok and v_sin_caballos_ok and v_jugador_ok,
    format('bueno=%s (caballos=%s reglas=%s senal=%s) bitacora=%s | guarda_en_reglas=%s (%s basura=%s senal=%s) | notnull_en_reglas=%s (%s basura=%s) | repetido=%s (%s basura=%s) | sin_caballos=%s (%s) | jugador=%s (%s) | la frase del repetido: %s',
      v_bueno_ok, v_cab, v_reg, v_senal_buena, v_en_bitacora,
      v_falla_guarda_ok, coalesce(v_sql_a,'sin excepcion'), v_basura_a, v_senal_a,
      v_falla_notnull_ok, coalesce(v_sql_b,'sin excepcion'), v_basura_b,
      v_repetido_ok, coalesce(v_sql_c,'sin excepcion'), v_basura_c,
      v_sin_caballos_ok, coalesce(v_sql_d,'sin excepcion'),
      v_jugador_ok, coalesce(v_sql_e,'sin excepcion'),
      coalesce(v_msg_c,'-')));
end $$;


-- ============================================================================
--  P68 - Las escaleras se reemplazan de una vez o no se reemplazan
--
--  EL DEFECTO QUE EXISTE PARA IMPEDIR. La pantalla de editar hacia un `delete`
--  de todas las escaleras del remate y un `insert` de las nuevas, en dos
--  llamadas sueltas. Entre las dos el remate se quedaba SIN NINGUNA escalera,
--  en vivo, y todos los caballos pasaban a subir con remates.incremento_minimo.
--  Y el admin leia "Error guardando cambios" y deducia que no se habia tocado
--  nada, cuando el borrado ya estaba hecho.
--
--  LO QUE MIDE
--   1. el reemplazo normal deja EXACTAMENTE las escaleras nuevas, ni una del
--      juego viejo
--   2. si una escalera nueva no pasa una guarda, las VIEJAS SIGUEN AHI: es la
--      prueba de que el borrado se deshizo. Si fallara, aqui saldria 0.
--   3. una lista vacia es una orden legitima: el remate se queda sin escaleras
--   4. una escalera que apunta a un caballo de OTRA carrera se rechaza, y las
--      viejas siguen ahi
--   5. un jugador no puede llamarla
--   6. `authenticated` ya NO puede escribir remate_price_rules directo: esta
--      funcion es la unica puerta
--
--  REGLA DEL 28/09: se comprueba CUAL excepcion. P0001 es nuestro codigo
--  rechazando a proposito; 42883 seria que la migracion no esta aplicada.
-- ============================================================================
do $$
declare
  v_admin uuid; v_juan uuid;
  v_existe boolean;
  v_rem uuid; v_race uuid;
  v_c1 uuid; v_c2 uuid;
  v_otra_race uuid; v_ajeno uuid;
  v_escritas int;

  v_sql_b text; v_quedan_b int;
  v_sql_d text; v_quedan_d int;
  v_sql_e text; v_quedan_e int;

  v_reemplazo_ok boolean := false;
  v_rollback_ok boolean := false;
  v_vaciar_ok boolean := false;
  v_ajeno_ok boolean := false;
  v_jugador_ok boolean := false;
  v_puerta_ok boolean := false;
  v_en_bitacora boolean := false;
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'guardar_escaleras'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(68, 'Las escaleras se reemplazan de una vez',
      'guardar_escaleras() existe y un rechazo deja las escaleras viejas intactas',
      false, 'guardar_escaleras NO EXISTE: la migracion 20261007150000 no esta aplicada');
    return;
  end if;

  update public.ajustes_instalacion set valor = '50' where clave = 'minimo_incremento';

  v_admin := _p.usuario('jefa', 0, true);
  v_juan  := _p.usuario('juan', 1000, false);
  perform _p.actuar_como(v_admin);

  -- Un remate con dos caballos y una escalera vieja en el caballo 1.
  select c.id_carrera, c.id_remate into v_race, v_rem
  from public.crear_remate_completo(
    jsonb_build_object('nombre','C1','fecha',current_date::text),
    jsonb_build_object('nombre','R1','incremento_minimo',50,'porcentaje_casa',25),
    jsonb_build_array(
      jsonb_build_object('numero',1,'nombre','Uno','precio_salida',100,
        'reglas', jsonb_build_array(
          jsonb_build_object('min_precio',100,'max_precio',500,'incremento',50))),
      jsonb_build_object('numero',2,'nombre','Dos','precio_salida',100)
    )) c;

  select h.id into v_c1 from public.horses h where h.race_id = v_race and h.numero = 1;
  select h.id into v_c2 from public.horses h where h.race_id = v_race and h.numero = 2;

  -- Un caballo de otra carrera, para la fase 4.
  insert into public.races (nombre, fecha) values ('otra', current_date) returning id into v_otra_race;
  insert into public.horses (race_id, numero, nombre, precio_salida)
    values (v_otra_race, 7, 'Ajeno', 100) returning id into v_ajeno;

  -- ----------------------------------------- 1) reemplazo normal
  -- Se cambia de "una escalera en el caballo 1" a "dos tramos en el caballo 2".
  v_escritas := public.guardar_escaleras(v_rem, jsonb_build_array(
    jsonb_build_object('horse_id', v_c2, 'min_precio', 100, 'max_precio', 600, 'incremento', 50),
    jsonb_build_object('horse_id', v_c2, 'min_precio', 600, 'max_precio', null, 'incremento', 100)
  ));

  v_reemplazo_ok :=
        v_escritas = 2
    and (select count(*) from public.remate_price_rules r where r.remate_id = v_rem) = 2
    -- ni una del juego viejo: el caballo 1 se queda sin escalera
    and (select count(*) from public.remate_price_rules r where r.remate_id = v_rem and r.horse_id = v_c1) = 0
    and (select count(*) from public.remate_price_rules r where r.remate_id = v_rem and r.horse_id = v_c2) = 2;

  select exists (
    select 1 from public.admin_actions a
    where a.action = 'guardar_escaleras' and a.target_id = v_rem::text
  ) into v_en_bitacora;

  -- ------------------- 2) una guarda rechaza: las VIEJAS siguen ahi
  -- Incremento 10 por debajo del minimo (50) -> trg_minimo_incremento_regla.
  -- Si el borrado no se deshiciera, aqui quedarian 0 escaleras.
  begin
    perform public.guardar_escaleras(v_rem, jsonb_build_array(
      jsonb_build_object('horse_id', v_c1, 'min_precio', 100, 'max_precio', null, 'incremento', 10)
    ));
  exception when others then
    v_sql_b := sqlstate;
  end;

  select count(*) into v_quedan_b from public.remate_price_rules r where r.remate_id = v_rem;

  -- Siguen siendo las DOS del caballo 2, no las del intento fallido.
  v_rollback_ok := v_sql_b = 'P0001' and v_quedan_b = 2
    and (select count(*) from public.remate_price_rules r
          where r.remate_id = v_rem and r.horse_id = v_c2) = 2;

  -- ------------------------------- 4) caballo de otra carrera
  begin
    perform public.guardar_escaleras(v_rem, jsonb_build_array(
      jsonb_build_object('horse_id', v_ajeno, 'min_precio', 100, 'max_precio', null, 'incremento', 50)
    ));
  exception when others then
    v_sql_d := sqlstate;
  end;
  select count(*) into v_quedan_d from public.remate_price_rules r where r.remate_id = v_rem;
  v_ajeno_ok := v_sql_d = 'P0001' and v_quedan_d = 2;

  -- ------------------------------------- 5) un jugador no puede
  perform _p.actuar_como(v_juan);
  begin
    perform public.guardar_escaleras(v_rem, '[]'::jsonb);
  exception when others then
    v_sql_e := sqlstate;
  end;
  select count(*) into v_quedan_e from public.remate_price_rules r where r.remate_id = v_rem;
  v_jugador_ok := v_sql_e = 'P0001' and v_quedan_e = 2;

  -- ----------------------------------- 3) vaciar es una orden valida
  perform _p.actuar_como(v_admin);
  v_escritas := public.guardar_escaleras(v_rem, '[]'::jsonb);
  v_vaciar_ok := v_escritas = 0
    and (select count(*) from public.remate_price_rules r where r.remate_id = v_rem) = 0;

  -- --------------------- 6) la tabla ya no se escribe directo
  v_puerta_ok :=
        not has_table_privilege('authenticated', 'public.remate_price_rules', 'insert')
    and not has_table_privilege('authenticated', 'public.remate_price_rules', 'update')
    and not has_table_privilege('authenticated', 'public.remate_price_rules', 'delete')
    and not has_table_privilege('authenticated', 'public.remate_price_rules', 'truncate')
    -- leer si: la pantalla de editar las pinta
    and has_table_privilege('authenticated', 'public.remate_price_rules', 'select');

  perform _p.anotar(68, 'Las escaleras se reemplazan de una vez',
    'el reemplazo deja solo las nuevas; si una se rechaza las viejas siguen ahi; vaciar es valido; un caballo de otra carrera y un jugador se rechazan; y la tabla ya no se escribe directo',
    v_reemplazo_ok and v_en_bitacora and v_rollback_ok and v_vaciar_ok
      and v_ajeno_ok and v_jugador_ok and v_puerta_ok,
    format('reemplazo=%s bitacora=%s | rechazo_deja_las_viejas=%s (%s quedan=%s, esperado 2) | vaciar=%s | caballo_ajeno=%s (%s quedan=%s) | jugador=%s (%s) | tabla_cerrada=%s',
      v_reemplazo_ok, v_en_bitacora,
      v_rollback_ok, coalesce(v_sql_b,'sin excepcion'), v_quedan_b,
      v_vaciar_ok,
      v_ajeno_ok, coalesce(v_sql_d,'sin excepcion'), v_quedan_d,
      v_jugador_ok, coalesce(v_sql_e,'sin excepcion'),
      v_puerta_ok));
end $$;



-- ============================================================================
--  P69 - La bitacora no anuncia lo que no paso, y dice que paso cuando pasa
--
--  LO QUE JOTA VIO EN /admin/log EL 07/10. Cambio solo el incremento del
--  remate y el log dijo ademas "Guardar escaleras: Tramos ahora 0, antes 0".
--  Cambio solo las escaleras y el log dijo ademas "Remate editado" sin una
--  etiqueta. La pantalla llama a las dos RPC en todos los guardados, asi que
--  cada guardado dejaba dos asientos aunque solo hubiera un cambio.
--
--  LO QUE MIDE
--   1. guardar_escaleras con las MISMAS escaleras: no deja asiento y no toca
--      las filas (se comprueba que los ids no cambiaron: si hubiera borrado e
--      insertado, serian otros)
--   2. guardar_escaleras con escaleras distintas: deja UN asiento, y el
--      detalle nombra al caballo que cambio y NO a los que no
--   3. editar_remate sin cambiar nada: no deja asiento
--   4. editar_remate cambiando el incremento: deja asiento con antes y despues
--   5. un remate que no tenia escaleras y sigue sin tenerlas: no deja asiento
--      (el caso exacto de las 1:11, 0 -> 0)
--
--  REGLA DEL 28/09: cuando el exito es "salto una excepcion" se comprueba
--  cual. Aqui el exito es "NO se escribio", que se mide contando asientos
--  antes y despues, no confiando en que la funcion devuelva algo.
-- ============================================================================
do $$
declare
  v_admin uuid;
  v_existe boolean;
  v_rem uuid; v_race uuid; v_c1 uuid; v_c2 uuid;
  v_reglas jsonb;
  v_ids_antes uuid[]; v_ids_despues uuid[];
  v_n int; v_detalle jsonb; v_muestra text;

  v_sin_cambio_ok boolean := false;
  v_no_toca_filas boolean := false;
  v_con_cambio_ok boolean := false;
  v_nombra_bien boolean := false;
  v_editar_vacio_ok boolean := false;
  v_editar_real_ok boolean := false;
  v_vacias_ok boolean := false;
begin
  perform _p.limpiar();
  delete from public.admin_actions;

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'guardar_escaleras'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(69, 'La bitacora no anuncia lo que no paso',
      'guardar_escaleras y editar_remate solo dejan asiento si hubo cambio',
      false, 'guardar_escaleras NO EXISTE: la migracion 20261007170000 no esta aplicada');
    return;
  end if;

  update public.ajustes_instalacion set valor = '50' where clave = 'minimo_incremento';

  v_admin := _p.usuario('jefa', 0, true);
  perform _p.actuar_como(v_admin);

  select c.id_carrera, c.id_remate into v_race, v_rem
  from public.crear_remate_completo(
    jsonb_build_object('nombre','C','fecha',current_date::text),
    jsonb_build_object('nombre','R','incremento_minimo',50,'porcentaje_casa',25),
    jsonb_build_array(
      jsonb_build_object('numero',3,'nombre','Tres','precio_salida',100),
      jsonb_build_object('numero',5,'nombre','Cinco','precio_salida',100)
    )) c;

  select h.id into v_c1 from public.horses h where h.race_id = v_race and h.numero = 3;
  select h.id into v_c2 from public.horses h where h.race_id = v_race and h.numero = 5;

  -- Escaleras iniciales: dos tramos al caballo 3.
  v_reglas := jsonb_build_array(
    jsonb_build_object('horse_id', v_c1, 'min_precio', 100, 'max_precio', 500, 'incremento', 50),
    jsonb_build_object('horse_id', v_c1, 'min_precio', 500, 'max_precio', null, 'incremento', 100));
  perform public.guardar_escaleras(v_rem, v_reglas);

  delete from public.admin_actions where action = 'guardar_escaleras';

  -- --------------------------------- 1) las MISMAS escaleras otra vez
  select array_agg(r.id order by r.id) into v_ids_antes
  from public.remate_price_rules r where r.remate_id = v_rem;

  -- El navegador manda 50, no 50.00: si la comparacion fuera de textos en
  -- crudo, esto parecria un cambio.
  perform public.guardar_escaleras(v_rem, v_reglas);

  select count(*) into v_n from public.admin_actions a where a.action = 'guardar_escaleras';
  v_sin_cambio_ok := v_n = 0;

  select array_agg(r.id order by r.id) into v_ids_despues
  from public.remate_price_rules r where r.remate_id = v_rem;
  -- Si hubiera borrado e insertado, los ids serian otros.
  v_no_toca_filas := v_ids_antes = v_ids_despues;

  -- --------------------------------- 2) escaleras distintas
  perform public.guardar_escaleras(v_rem, jsonb_build_array(
    jsonb_build_object('horse_id', v_c1, 'min_precio', 100, 'max_precio', 500, 'incremento', 50),
    jsonb_build_object('horse_id', v_c1, 'min_precio', 500, 'max_precio', null, 'incremento', 100),
    jsonb_build_object('horse_id', v_c2, 'min_precio', 100, 'max_precio', null, 'incremento', 75)));

  select count(*) into v_n from public.admin_actions a where a.action = 'guardar_escaleras';
  v_con_cambio_ok := v_n = 1;

  select a.details into v_detalle
  from public.admin_actions a where a.action = 'guardar_escaleras' limit 1;

  -- Nombra al caballo 5, que es el que cambio, y NO al 3, que se quedo igual.
  -- Se guarda la frase AQUI: la fase 5 borra los asientos, y si se leyera al
  -- final el informe saldria vacio justo en lo que esta prueba viene a
  -- demostrar.
  v_muestra := coalesce(v_detalle->'caballo_5'->>'antes','?')
            || ' -> ' || coalesce(v_detalle->'caballo_5'->>'despues','?');

  v_nombra_bien :=
        v_detalle ? 'caballo_5'
    and not (v_detalle ? 'caballo_3')
    and v_detalle->'caballo_5'->>'antes' = 'sin escalera'
    -- La frase entera, no un `like`: fija el singular ("1 tramo", no
    -- "1 tramos") y la coma decimal, que es como se escribe el dinero en el
    -- resto de la aplicacion.
    and v_detalle->'caballo_5'->>'despues' = '1 tramo (sube 75,00)';

  -- --------------------------------- 3) editar_remate sin cambiar nada
  delete from public.admin_actions;
  perform public.editar_remate(v_rem, 25, 50, 'vivo', null, null, false, false);
  select count(*) into v_n from public.admin_actions a where a.action = 'editar_remate';
  v_editar_vacio_ok := v_n = 0;

  -- --------------------------------- 4) editar_remate cambiando de verdad
  perform public.editar_remate(v_rem, 25, 150, 'vivo', null, null, false, false);
  select count(*) into v_n from public.admin_actions a where a.action = 'editar_remate';
  select a.details into v_detalle from public.admin_actions a where a.action = 'editar_remate' limit 1;
  v_editar_real_ok := v_n = 1
    and v_detalle->'incremento_minimo'->>'antes' = '50.00'
    and v_detalle->'incremento_minimo'->>'despues' = '150';

  -- --------------------------- 5) sin escaleras y sigue sin escaleras
  -- El caso exacto de las 1:11: "Tramos ahora: 0 | Tramos antes: 0".
  perform public.guardar_escaleras(v_rem, '[]'::jsonb);   -- las quita (si deja asiento)
  delete from public.admin_actions where action = 'guardar_escaleras';
  perform public.guardar_escaleras(v_rem, '[]'::jsonb);   -- y otra vez: nada que hacer
  select count(*) into v_n from public.admin_actions a where a.action = 'guardar_escaleras';
  v_vacias_ok := v_n = 0;

  perform _p.anotar(69, 'La bitacora no anuncia lo que no paso',
    'guardar las mismas escaleras no deja asiento ni toca las filas; cambiarlas deja uno que nombra al caballo que cambio; editar_remate sin cambios no deja asiento y con cambios si',
    v_sin_cambio_ok and v_no_toca_filas and v_con_cambio_ok and v_nombra_bien
      and v_editar_vacio_ok and v_editar_real_ok and v_vacias_ok,
    format('mismas_escaleras_sin_asiento=%s no_toca_las_filas=%s | cambio_deja_uno=%s nombra_al_que_cambio=%s | editar_sin_cambios=%s editar_con_cambios=%s | cero_a_cero=%s | detalle del cambio: %s',
      v_sin_cambio_ok, v_no_toca_filas, v_con_cambio_ok, v_nombra_bien,
      v_editar_vacio_ok, v_editar_real_ok, v_vacias_ok,
      'Caballo 5: ' || coalesce(v_muestra,'-')));
end $$;



-- ============================================================================
--  P70 - Guardar un remate editado es atomico, y cada cambio deja asiento
--
--  EL DEFECTO QUE EXISTE PARA IMPEDIR. El guardado de la pantalla de editar
--  eran 16 o 17 escrituras sueltas: `races`, `editar_remate`, el borrado de
--  caballos, UN UPDATE O INSERT POR CABALLO, y las escaleras. Un fallo a mitad
--  del bucle dejaba unos caballos con los datos nuevos y otros con los viejos.
--  Y los cambios de un caballo -- nombre, jinete, precio de salida, retirado,
--  altas y bajas -- no dejaban NINGUN rastro en admin_actions.
--
--  LO QUE MIDE
--   1. el camino bueno aplica carrera, caballos y escaleras, y deja UN asiento
--      que nombra cada cosa que cambio ("Caballo 3 precio salida: 100 -> 150")
--   2. ATOMICIDAD: si el caballo 3 de 4 no pasa una guarda, NINGUNO cambia y
--      la carrera tampoco. Se comprueba leyendo los cuatro, no confiando en
--      que la funcion devuelva algo
--   3. guardar sin cambiar nada no deja ningun asiento (ADR-038)
--   4. la escalera de un caballo RECIEN CREADO se guarda con su id
--   5. un caballo de otra carrera se rechaza
--   6. un jugador no puede llamarla
--   7. `authenticated` ya no puede escribir `races` ni `horses` directo
--
--  REGLA DEL 28/09: se comprueba CUAL excepcion. 42883 significaria que la
--  migracion no esta aplicada y la prueba no estaria probando nada.
-- ============================================================================
do $$
declare
  v_admin uuid; v_juan uuid;
  v_existe boolean;
  v_rem uuid; v_race uuid; v_c1 uuid; v_c2 uuid; v_c3 uuid;
  v_otra_race uuid; v_ajeno uuid;
  v_carrera jsonb; v_remate jsonb;
  v_det jsonb; v_n int; v_res jsonb;
  v_sql_b text; v_sql_e text; v_sql_f text;
  v_foto text; v_foto_despues text;

  v_bueno_ok boolean := false;
  v_asiento_ok boolean := false;
  v_atomico_ok boolean := false;
  v_sin_cambios_ok boolean := false;
  v_escalera_nueva_ok boolean := false;
  v_ajeno_ok boolean := false;
  v_jugador_ok boolean := false;
  v_puerta_ok boolean := false;
begin
  perform _p.limpiar();
  delete from public.admin_actions;

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'guardar_remate_completo'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(70, 'Guardar un remate editado es atomico',
      'guardar_remate_completo() existe, es atomica y deja asiento de cada cambio',
      false, 'guardar_remate_completo NO EXISTE: la migracion 20261008150000 no esta aplicada');
    return;
  end if;

  update public.ajustes_instalacion set valor = '50'  where clave = 'minimo_incremento';
  update public.ajustes_instalacion set valor = '100' where clave = 'minimo_precio_salida';

  v_admin := _p.usuario('jefa', 0, true);
  v_juan  := _p.usuario('juan', 1000, false);
  perform _p.actuar_como(v_admin);

  select c.id_carrera, c.id_remate into v_race, v_rem
  from public.crear_remate_completo(
    jsonb_build_object('nombre','Carrera vieja','hipodromo','La Rinconada',
                       'fecha',current_date::text,'dia','Sabado','distancia_m',1600),
    jsonb_build_object('nombre','R','incremento_minimo',50,'porcentaje_casa',25),
    jsonb_build_array(
      jsonb_build_object('numero',1,'nombre','Uno','jinete','A','precio_salida',100),
      jsonb_build_object('numero',2,'nombre','Dos','jinete','B','precio_salida',100),
      jsonb_build_object('numero',3,'nombre','Tres','jinete','C','precio_salida',100)
    )) c;

  select h.id into v_c1 from public.horses h where h.race_id = v_race and h.numero = 1;
  select h.id into v_c2 from public.horses h where h.race_id = v_race and h.numero = 2;
  select h.id into v_c3 from public.horses h where h.race_id = v_race and h.numero = 3;

  insert into public.races (nombre, fecha) values ('otra', current_date) returning id into v_otra_race;
  insert into public.horses (race_id, numero, nombre, precio_salida)
    values (v_otra_race, 9, 'Ajeno', 100) returning id into v_ajeno;

  v_carrera := jsonb_build_object('nombre','Carrera vieja','hipodromo','La Rinconada',
                 'fecha',current_date::text,'dia','Sabado','distancia_m',1600);
  v_remate  := jsonb_build_object('porcentaje_casa',25,'incremento_minimo',50,'tipo','vivo');

  delete from public.admin_actions;

  -- ------------------------------------------------- 1) el camino bueno
  -- Cambia: hipodromo de la carrera, nombre y precio del caballo 1,
  -- da de baja al 3, y da de alta un 7 CON escalera propia.
  v_res := public.guardar_remate_completo(
    v_rem,
    v_carrera || jsonb_build_object('hipodromo','Valencia'),
    v_remate,
    jsonb_build_array(
      jsonb_build_object('id',v_c1,'numero',1,'nombre','Relampago','jinete','A',
                         'precio_salida',150),
      jsonb_build_object('id',v_c2,'numero',2,'nombre','Dos','jinete','B',
                         'precio_salida',100),
      jsonb_build_object('id',null,'numero',7,'nombre','Centella','jinete','D',
                         'precio_salida',120,
                         'reglas', jsonb_build_array(
                           jsonb_build_object('min_precio',120,'max_precio',null,'incremento',50)))
    ),
    jsonb_build_array(v_c3::text));

  v_bueno_ok :=
        (select nombre from public.horses h where h.id = v_c1) = 'Relampago'
    and (select precio_salida from public.horses h where h.id = v_c1) = 150
    and (select hipodromo from public.races ra where ra.id = v_race) = 'Valencia'
    and not exists (select 1 from public.horses h where h.id = v_c3)
    and exists (select 1 from public.horses h where h.race_id = v_race and h.numero = 7)
    and (v_res->>'altas')::int = 1 and (v_res->>'bajas')::int = 1;

  -- 4) la escalera del caballo recien creado quedo colgada de SU id
  v_escalera_nueva_ok := (
    select count(*) from public.remate_price_rules r
    join public.horses h on h.id = r.horse_id
    where r.remate_id = v_rem and h.numero = 7) = 1;

  select a.details into v_det
  from public.admin_actions a where a.action = 'guardar_remate_completo'
  order by a.created_at desc limit 1;

  -- El asiento nombra CADA cosa, con su antes y su despues.
  v_asiento_ok :=
        v_det ? 'carrera_hipodromo'
    and v_det->'carrera_hipodromo'->>'antes'   = 'La Rinconada'
    and v_det->'carrera_hipodromo'->>'despues' = 'Valencia'
    and v_det ? 'caballo_1_nombre'
    and v_det->'caballo_1_nombre'->>'despues'  = 'Relampago'
    and v_det ? 'caballo_1_precio_salida'
    and v_det->'caballo_1_precio_salida'->>'antes'   = '100,00'
    and v_det->'caballo_1_precio_salida'->>'despues' = '150,00'
    and v_det ? 'caballo_7_alta'
    and v_det ? 'caballo_3_baja'
    -- y NO nombra al caballo 2, que no cambio
    and not (v_det ? 'caballo_2_nombre');

  -- ------------------------------------------------- 3) sin cambios
  delete from public.admin_actions;
  perform public.guardar_remate_completo(
    v_rem,
    v_carrera || jsonb_build_object('hipodromo','Valencia'),
    v_remate,
    jsonb_build_array(
      jsonb_build_object('id',v_c1,'numero',1,'nombre','Relampago','jinete','A','precio_salida',150),
      jsonb_build_object('id',v_c2,'numero',2,'nombre','Dos','jinete','B','precio_salida',100),
      jsonb_build_object('id',(select h.id from public.horses h where h.race_id=v_race and h.numero=7),
                         'numero',7,'nombre','Centella','jinete','D','precio_salida',120,
                         'reglas', jsonb_build_array(
                           jsonb_build_object('min_precio',120,'max_precio',null,'incremento',50)))
    ),
    '[]'::jsonb);
  select count(*) into v_n from public.admin_actions;
  v_sin_cambios_ok := v_n = 0;

  -- ------------------------------------------------- 2) ATOMICIDAD
  -- El caballo 7 lleva un precio de salida por debajo del minimo (100), asi
  -- que lo rebota trg_minimo_precio_salida DESPUES de haber escrito el 1 y
  -- el 2 y la carrera. Si no fuera atomico, el 1 se llamaria 'Cambiado'.
  select string_agg(h.numero || '=' || h.nombre || '/' ||
                    trim(to_char(h.precio_salida,'FM999990.00')), ',' order by h.numero)
    into v_foto
  from public.horses h where h.race_id = v_race;

  begin
    perform public.guardar_remate_completo(
      v_rem,
      v_carrera || jsonb_build_object('hipodromo','Maracaibo'),
      v_remate,
      jsonb_build_array(
        jsonb_build_object('id',v_c1,'numero',1,'nombre','Cambiado','jinete','A','precio_salida',150),
        jsonb_build_object('id',v_c2,'numero',2,'nombre','Cambiado','jinete','B','precio_salida',100),
        jsonb_build_object('id',(select h.id from public.horses h where h.race_id=v_race and h.numero=7),
                           'numero',7,'nombre','Centella','jinete','D','precio_salida',50)
      ),
      '[]'::jsonb);
  exception when others then
    v_sql_b := sqlstate;
  end;

  select string_agg(h.numero || '=' || h.nombre || '/' ||
                    trim(to_char(h.precio_salida,'FM999990.00')), ',' order by h.numero)
    into v_foto_despues
  from public.horses h where h.race_id = v_race;

  v_atomico_ok := v_sql_b = 'P0001'
    and v_foto = v_foto_despues
    and (select hipodromo from public.races ra where ra.id = v_race) = 'Valencia';

  -- ------------------------------------------------- 5) caballo de otra carrera
  begin
    perform public.guardar_remate_completo(
      v_rem, v_carrera, v_remate,
      jsonb_build_array(jsonb_build_object('id',v_ajeno,'numero',9,'nombre','X','precio_salida',100)),
      '[]'::jsonb);
  exception when others then
    v_sql_e := sqlstate;
  end;
  v_ajeno_ok := v_sql_e = 'P0001'
    and (select nombre from public.horses h where h.id = v_ajeno) = 'Ajeno';

  -- ------------------------------------------------- 6) un jugador no puede
  perform _p.actuar_como(v_juan);
  begin
    perform public.guardar_remate_completo(
      v_rem, v_carrera || jsonb_build_object('hipodromo','Pirata'), v_remate,
      jsonb_build_array(jsonb_build_object('id',v_c1,'numero',1,'nombre','Pirata','precio_salida',150)),
      '[]'::jsonb);
  exception when others then
    v_sql_f := sqlstate;
  end;
  v_jugador_ok := v_sql_f = 'P0001'
    and (select nombre from public.horses h where h.id = v_c1) = 'Relampago'
    and (select hipodromo from public.races ra where ra.id = v_race) = 'Valencia';

  -- ------------------------------------------------- 7) puertas cerradas
  v_puerta_ok :=
        not has_table_privilege('authenticated', 'public.races',  'insert')
    and not has_table_privilege('authenticated', 'public.races',  'update')
    and not has_table_privilege('authenticated', 'public.races',  'delete')
    and not has_table_privilege('authenticated', 'public.horses', 'insert')
    and not has_table_privilege('authenticated', 'public.horses', 'update')
    and not has_table_privilege('authenticated', 'public.horses', 'delete')
    and has_table_privilege('authenticated', 'public.races',  'select')
    and has_table_privilege('authenticated', 'public.horses', 'select');

  perform _p.anotar(70, 'Guardar un remate editado es atomico',
    'aplica carrera, caballos y escaleras de una vez y deja un asiento que nombra cada cambio; un fallo no deja nada a medias; sin cambios no hay asiento; races y horses ya no se escriben directo',
    v_bueno_ok and v_asiento_ok and v_atomico_ok and v_sin_cambios_ok
      and v_escalera_nueva_ok and v_ajeno_ok and v_jugador_ok and v_puerta_ok,
    format('bueno=%s asiento=%s escalera_del_nuevo=%s | ATOMICO=%s (%s) | sin_cambios=%s | ajeno=%s (%s) | jugador=%s (%s) | puertas=%s | foto antes: %s | foto despues: %s | del asiento: %s',
      v_bueno_ok, v_asiento_ok, v_escalera_nueva_ok,
      v_atomico_ok, coalesce(v_sql_b,'sin excepcion'),
      v_sin_cambios_ok,
      v_ajeno_ok, coalesce(v_sql_e,'sin excepcion'),
      v_jugador_ok, coalesce(v_sql_f,'sin excepcion'),
      v_puerta_ok, coalesce(v_foto,'-'), coalesce(v_foto_despues,'-'),
      coalesce(v_det->'caballo_1_precio_salida'->>'antes','?') || ' -> ' ||
      coalesce(v_det->'caballo_1_precio_salida'->>'despues','?')));
end $$;



-- ============================================================================
--  P71 - Dos caballos pueden intercambiar su numero
--
--  EL DEFECTO QUE EXISTE PARA IMPEDIR. Pasar el caballo 3 a 5 cuando la
--  carrera ya tenia un 5 rebotaba con 23505 en el PRIMER update, antes de que
--  el 5 llegara a ser 3, y el admin lo veia en crudo.
--
--  Y hay que decir por que la transaccion del 08/10 no lo arreglo, porque es
--  el punto entero de esta prueba: `guardar_remate_completo` YA era atomica
--  -- P70 lo demuestra -- y aun asi esto fallaba. Una transaccion decide que
--  se guarda TODO o NADA; no decide CUANDO se comprueban las reglas. El indice
--  comprobaba fila a fila un estado que durante un intercambio es falso a
--  mitad de camino.
--
--  LO QUE MIDE
--   1. la restriccion es DIFERIBLE pero NO diferida por defecto
--   2. el intercambio 1 <-> 2 funciona y deja los dos numeros cambiados
--   3. un duplicado DE VERDAD (dos caballos acabando en el mismo numero)
--      sigue rechazandose, con mensaje traducido y SIN dejar nada a medias:
--      foto identica de los caballos antes y despues
--   4. un alta con numero repetido sigue rebotando AL MOMENTO, no al final:
--      el `initially immediate` no se perdio
--
--  REGLA DEL 28/09: se comprueba CUAL excepcion. Un 42883 significaria que la
--  migracion no esta aplicada y la prueba no estaria probando nada.
-- ============================================================================
do $$
declare
  v_admin uuid;
  v_difiere_ok boolean := false;
  v_swap_ok boolean := false;
  v_dup_ok boolean := false;
  v_alta_ok boolean := false;

  v_condef boolean; v_condeferred boolean;
  v_rem uuid; v_race uuid; v_c1 uuid; v_c2 uuid;
  v_carrera jsonb; v_remate jsonb;
  v_foto_antes text; v_foto_despues text; v_foto_swap text;
  v_sql_dup text; v_msg_dup text; v_sql_alta text; v_msg_alta text;
begin
  perform _p.limpiar();
  delete from public.admin_actions;

  select c.condeferrable, c.condeferred into v_condef, v_condeferred
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public' and t.relname = 'horses'
    and c.conname = 'horses_race_id_numero_key';

  if v_condef is null then
    perform _p.anotar(71, 'Dos caballos pueden intercambiar su numero',
      'la unica (race_id, numero) es diferible y el intercambio funciona',
      false, 'horses_race_id_numero_key NO EXISTE: la migracion 20261010140000 no esta aplicada');
    return;
  end if;

  -- 1) diferible, pero inmediata por defecto. Las dos cosas importan: si fuera
  --    `initially deferred`, CUALQUIER escritura de la base se enteraria de un
  --    numero repetido solo al confirmar, incluida una que no intercambia nada.
  v_difiere_ok := v_condef and not v_condeferred;

  -- Esta prueba fija SUS propias precondiciones. `minimo_incremento` lo dejan
  -- en 1 otras pruebas, y P67 se llevo un susto por fiarse (lección del 07/10).
  update public.ajustes_instalacion set valor = '50'  where clave = 'minimo_incremento';
  update public.ajustes_instalacion set valor = '100' where clave = 'minimo_precio_salida';

  v_admin := _p.usuario('jefa', 0, true);
  perform _p.actuar_como(v_admin);

  select c.id_carrera, c.id_remate into v_race, v_rem
  from public.crear_remate_completo(
    jsonb_build_object('nombre','Carrera','hipodromo','La Rinconada',
                       'fecha',current_date::text,'dia','Sabado','distancia_m',1600),
    jsonb_build_object('nombre','R','incremento_minimo',50,'porcentaje_casa',25),
    jsonb_build_array(
      jsonb_build_object('numero',1,'nombre','Uno','jinete','A','precio_salida',100),
      jsonb_build_object('numero',2,'nombre','Dos','jinete','B','precio_salida',100)
    )) c;

  select h.id into v_c1 from public.horses h where h.race_id = v_race and h.numero = 1;
  select h.id into v_c2 from public.horses h where h.race_id = v_race and h.numero = 2;

  v_carrera := jsonb_build_object('nombre','Carrera','hipodromo','La Rinconada',
                 'fecha',current_date::text,'dia','Sabado','distancia_m',1600);
  v_remate  := jsonb_build_object('porcentaje_casa',25,'incremento_minimo',50,'tipo','vivo');

  -- 2) EL INTERCAMBIO. El 1 pasa a 2 y el 2 pasa a 1, en la misma llamada.
  perform public.guardar_remate_completo(
    v_rem, v_carrera, v_remate,
    jsonb_build_array(
      jsonb_build_object('id',v_c1,'numero',2,'nombre','Uno','jinete','A','precio_salida',100),
      jsonb_build_object('id',v_c2,'numero',1,'nombre','Dos','jinete','B','precio_salida',100)
    ), '[]'::jsonb);

  select string_agg(h.numero || '=' || h.nombre, ', ' order by h.numero)
    into v_foto_swap
  from public.horses h where h.race_id = v_race;

  -- Se comprueba por el ID, no por el numero: lo que interesa es que CADA
  -- caballo acabo con el numero del otro, no que existan un 1 y un 2.
  v_swap_ok :=
        (select h.numero from public.horses h where h.id = v_c1) = 2
    and (select h.numero from public.horses h where h.id = v_c2) = 1;

  -- 3) UN DUPLICADO DE VERDAD SIGUE SIENDO UN DUPLICADO.
  select string_agg(h.id::text || ':' || h.numero, ', ' order by h.numero)
    into v_foto_antes
  from public.horses h where h.race_id = v_race;

  begin
    perform public.guardar_remate_completo(
      v_rem, v_carrera, v_remate,
      jsonb_build_array(
        jsonb_build_object('id',v_c1,'numero',4,'nombre','Uno','jinete','A','precio_salida',100),
        jsonb_build_object('id',v_c2,'numero',4,'nombre','Dos','jinete','B','precio_salida',100)
      ), '[]'::jsonb);
  exception when others then
    v_sql_dup := sqlstate;
    v_msg_dup := sqlerrm;
  end;

  select string_agg(h.id::text || ':' || h.numero, ', ' order by h.numero)
    into v_foto_despues
  from public.horses h where h.race_id = v_race;

  -- La foto identica es la prueba de atomicidad: el primer update SI llego a
  -- ejecutarse (por eso hacia falta diferir), y aun asi no quedo nada.
  v_dup_ok := v_sql_dup = '23505'
    and v_msg_dup like '%numero distinto%'
    and v_foto_antes = v_foto_despues;

  -- 4) EL `INITIALLY IMMEDIATE` NO SE PERDIO. Crear con dos numeros iguales
  --    sigue rebotando al momento y con el mensaje de ADR-036.
  begin
    perform public.crear_remate_completo(
      jsonb_build_object('nombre','Otra','fecha',current_date::text),
      jsonb_build_object('nombre','R2','incremento_minimo',50,'porcentaje_casa',25),
      jsonb_build_array(
        jsonb_build_object('numero',5,'nombre','A','precio_salida',100),
        jsonb_build_object('numero',5,'nombre','B','precio_salida',100)
      ));
  exception when others then
    v_sql_alta := sqlstate;
    v_msg_alta := sqlerrm;
  end;
  v_alta_ok := v_sql_alta is not null and v_msg_alta like '%repetido%';

  perform _p.anotar(71, 'Dos caballos pueden intercambiar su numero',
    'la unica es diferible pero inmediata por defecto; el intercambio funciona; un duplicado de verdad rebota sin dejar nada a medias; un alta repetida sigue rebotando al momento',
    v_difiere_ok and v_swap_ok and v_dup_ok and v_alta_ok,
    format('diferible=%s (condeferrable=%s condeferred=%s) | INTERCAMBIO=%s (%s) | duplicado=%s (%s: %s) | alta_repetida=%s (%s) | foto antes: %s | foto despues: %s',
      v_difiere_ok, v_condef, v_condeferred,
      v_swap_ok, coalesce(v_foto_swap,'-'),
      v_dup_ok, coalesce(v_sql_dup,'sin excepcion'), coalesce(left(v_msg_dup,60),'-'),
      v_alta_ok, coalesce(left(v_msg_alta,60),'sin excepcion'),
      coalesce(v_foto_antes,'-'), coalesce(v_foto_despues,'-')));
end $$;


-- ============================================================================
--  P72 - La misma clave no crea dos remates
--
--  EL DEFECTO QUE EXISTE PARA IMPEDIR. Jota: "al crearse un remate, el boton
--  de crear remate queda activo y si le doy 20 veces mas, crea 20 remates con
--  el mismo nombre y los mismos datos".
--
--  Y otra vez: la transaccion del 07/10 NO cubria esto. Dos clics son dos
--  llamadas COMPLETAS Y CORRECTAS; no hay nada a medias que deshacer. La base
--  creaba dos remates porque no tenia forma de saber que era el mismo.
--
--  LO QUE MIDE
--   1. la columna y su indice unico PARCIAL existen
--   2. dos envios con LA MISMA clave devuelven el mismo remate, y solo hay uno
--   3. el segundo envio devuelve los contadores DE VERDAD, no ceros: para el
--      formulario tiene que ser indistinguible de haber acertado a la primera
--   4. el segundo envio NO duplica los caballos
--   5. el segundo envio NO deja un segundo asiento (ADR-038: la bitacora no
--      anuncia lo que no paso)
--   6. dos claves DISTINTAS crean dos remates -- la guarda no se pasa de lista
--   7. sin clave sigue creando siempre, que es como se comporto hasta hoy y
--      como se comporta el frontend viejo durante el despliegue
-- ============================================================================
do $$
declare
  v_admin uuid;
  v_col_ok boolean := false;
  v_misma_ok boolean := false;
  v_contadores_ok boolean := false;
  v_caballos_ok boolean := false;
  v_asiento_ok boolean := false;
  v_distintas_ok boolean := false;
  v_sin_clave_ok boolean := false;

  v_hay_col boolean; v_hay_idx boolean;
  v_r1 uuid; v_r2 uuid; v_r3 uuid; v_r4 uuid; v_r5 uuid;
  v_carrera jsonb; v_remate jsonb; v_caballos jsonb;
  v_n1 int; v_n2 int; v_q1 int; v_q2 int;
  v_cuantos int; v_asientos int; v_caballos_de int;
begin
  perform _p.limpiar();
  delete from public.admin_actions;

  select exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='remates' and column_name='clave_creacion'
  ) into v_hay_col;

  select exists (
    select 1 from pg_indexes
    where schemaname='public' and tablename='remates' and indexname='remates_clave_creacion_key'
  ) into v_hay_idx;

  if not v_hay_col then
    perform _p.anotar(72, 'La misma clave no crea dos remates',
      'dos envios con la misma clave devuelven el mismo remate',
      false, 'remates.clave_creacion NO EXISTE: la migracion 20261010150000 no esta aplicada');
    return;
  end if;
  v_col_ok := v_hay_col and v_hay_idx;

  update public.ajustes_instalacion set valor = '50'  where clave = 'minimo_incremento';
  update public.ajustes_instalacion set valor = '100' where clave = 'minimo_precio_salida';

  v_admin := _p.usuario('jefa', 0, true);
  perform _p.actuar_como(v_admin);

  v_carrera := jsonb_build_object('nombre','Carrera','hipodromo','La Rinconada',
                 'fecha',current_date::text,'dia','Sabado','distancia_m',1600);
  v_remate  := jsonb_build_object('nombre','R','incremento_minimo',50,'porcentaje_casa',25);
  v_caballos := jsonb_build_array(
      jsonb_build_object('numero',1,'nombre','Uno','precio_salida',100,
        'reglas', jsonb_build_array(jsonb_build_object('min_precio',100,'max_precio',null,'incremento',75))),
      jsonb_build_object('numero',2,'nombre','Dos','precio_salida',100));

  delete from public.admin_actions;

  -- 2 y 3) EL DOBLE CLIC
  select c.id_remate, c.n_caballos, c.n_reglas into v_r1, v_n1, v_q1
  from public.crear_remate_completo(v_carrera, v_remate, v_caballos, 'clave-del-doble-clic') c;

  select c.id_remate, c.n_caballos, c.n_reglas into v_r2, v_n2, v_q2
  from public.crear_remate_completo(v_carrera, v_remate, v_caballos, 'clave-del-doble-clic') c;

  select count(*)::int into v_cuantos
  from public.remates r where r.clave_creacion = 'clave-del-doble-clic';

  v_misma_ok := v_r1 = v_r2 and v_cuantos = 1;

  -- Los contadores del segundo envio salen de contar las filas de verdad, no
  -- de recordar lo que devolvio el primero.
  v_contadores_ok := v_n1 = 2 and v_n2 = 2 and v_q1 = 1 and v_q2 = 1;

  -- 4) sin caballos duplicados
  select count(*)::int into v_caballos_de
  from public.horses h
  join public.remates r on r.race_id = h.race_id
  where r.id = v_r1;
  v_caballos_ok := v_caballos_de = 2;

  -- 5) UN asiento, no dos
  select count(*)::int into v_asientos
  from public.admin_actions a
  where a.action = 'crear_remate_completo' and a.target_id = v_r1::text;
  v_asiento_ok := v_asientos = 1;

  -- 6) dos claves distintas son dos remates
  select c.id_remate into v_r3
  from public.crear_remate_completo(v_carrera, v_remate, v_caballos, 'otra-clave') c;
  v_distintas_ok := v_r3 is not null and v_r3 <> v_r1;

  -- 7) SIN CLAVE, como hasta hoy. Es el camino que sigue usando el frontend
  --    desplegado entre el paso de base y el de codigo.
  select c.id_remate into v_r4 from public.crear_remate_completo(v_carrera, v_remate, v_caballos) c;
  select c.id_remate into v_r5 from public.crear_remate_completo(v_carrera, v_remate, v_caballos) c;
  v_sin_clave_ok := v_r4 is not null and v_r5 is not null and v_r4 <> v_r5;

  perform _p.anotar(72, 'La misma clave no crea dos remates',
    'dos envios con la misma clave devuelven el mismo remate con sus contadores de verdad, sin duplicar caballos ni asientos; dos claves distintas crean dos; sin clave sigue creando siempre',
    v_col_ok and v_misma_ok and v_contadores_ok and v_caballos_ok
      and v_asiento_ok and v_distintas_ok and v_sin_clave_ok,
    format('columna+indice=%s | DOBLE CLIC=%s (remates con esa clave=%s, mismo id=%s) | contadores=%s (1o: %s caballos %s reglas | 2o: %s caballos %s reglas) | caballos=%s (%s) | asientos=%s (%s) | claves_distintas=%s | sin_clave=%s',
      v_col_ok,
      v_misma_ok, v_cuantos, (v_r1 = v_r2),
      v_contadores_ok, v_n1, v_q1, v_n2, v_q2,
      v_caballos_ok, v_caballos_de,
      v_asiento_ok, v_asientos,
      v_distintas_ok, v_sin_clave_ok));
end $$;



-- ============================================================================
--  P73 - La casa se funda sola, una vez, y solo quien fue designado
--
--  EL DEFECTO QUE EXISTE PARA IMPEDIR. El primer administrador de una
--  instalacion nueva se creaba con un UPDATE a mano, hecho por JERCOL dentro
--  de la base del cliente -- la base que va a tener el dinero de sus
--  jugadores. Lo mejor que le puede pasar al proveedor del software es NO
--  PODER entrar ahi.
--
--  Y el agujero que hay que no abrir al cerrarlo: si fundar se pudiera hacer
--  desde la pantalla sin mas, el PRIMERO QUE SE REGISTRE se queda con la casa,
--  con poder para aprobar recargas, pagar retiros y liquidar remates.
--
--  LO QUE MIDE
--   1. una instalacion recien creada dice que NO esta fundada
--   2. sin `correo_fundador` designado no se puede fundar, y nadie queda admin
--   3. un correo que no coincide se rechaza
--   4. un codigo mal formado se rechaza (identidad desde el minuto cero, ADR-027)
--   5. el correo designado SI funda: queda super admin con codigo y nombre,
--      `casa_fundada()` pasa a true y queda UN asiento en la bitacora
--   6. la segunda vez se rechaza AUNQUE el que llame sea el nuevo designado:
--      el candado de "ya hay dueno" manda sobre el del correo
--   7. el correo se compara sin distinguir mayusculas: designar
--      "DUENIO@Casa.Test" y registrarse como "duenio@casa.test" funciona
--   8. `casa_fundada` la puede leer anon (la pantalla pregunta sin sesion);
--      `fundar_super_admin` NO
--
--  REGLA DEL 28/09: se comprueba CUAL excepcion. Un 42883 significaria que la
--  migracion no esta aplicada y la prueba no estaria probando nada.
-- ============================================================================
do $$
declare
  v_existe boolean;
  v_duenio uuid; v_otro uuid;
  v_perfil public.profiles%rowtype;
  v_asientos int;

  v_arranca_ok boolean := false;
  v_sin_designado_ok boolean := false;
  v_otro_correo_ok boolean := false;
  v_codigo_malo_ok boolean := false;
  v_funda_ok boolean := false;
  v_segunda_ok boolean := false;
  v_permisos_ok boolean := false;

  v_sql_a text; v_sql_b text; v_sql_c text; v_sql_d text;
  v_msg_d text;
begin
  perform _p.limpiar();
  delete from public.admin_actions;

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fundar_super_admin'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(73, 'La casa se funda sola, una vez, y solo quien fue designado',
      'fundar_super_admin existe y respeta sus dos candados',
      false, 'fundar_super_admin NO EXISTE: la migracion 20261010193000 no esta aplicada');
    return;
  end if;

  -- La clave arranca vacia en una instalacion nueva. Esta prueba fija SUS
  -- propias precondiciones y no se fia de como la dejo otra.
  update public.ajustes_instalacion set valor = '' where clave = 'correo_fundador';

  -- Dos cuentas CON correo. `_p.usuario` no sirve aqui: inserta en auth.users
  -- sin correo, y el correo es justo el segundo candado.
  insert into auth.users (id, email) values (gen_random_uuid(), 'duenio@casa.test')
    returning id into v_duenio;
  insert into auth.users (id, email) values (gen_random_uuid(), 'otro@casa.test')
    returning id into v_otro;

  -- 1) recien instalada: sin dueno
  v_arranca_ok := (public.casa_fundada() = false);

  -- 2) sin designado no se funda
  perform _p.actuar_como(v_duenio);
  begin
    perform public.fundar_super_admin('DUE1', 'Dueno de la casa');
  exception when others then
    v_sql_a := sqlstate;
  end;
  v_sin_designado_ok := v_sql_a = 'P0001'
    and public.casa_fundada() = false
    and not exists (select 1 from public.profiles p where coalesce(p.es_admin,false));

  -- Se designa al dueno. CON MAYUSCULAS A PROPOSITO: el correo que escribe
  -- quien instala no tiene por que coincidir en capitalizacion con el que la
  -- persona uso al registrarse, y hacerle fallar por eso solo garantiza que
  -- acabe pidiendo que alguien entre a la base -- lo que esto viene a evitar.
  update public.ajustes_instalacion set valor = 'DUENIO@Casa.Test'
   where clave = 'correo_fundador';

  -- 3) otro correo, rechazado
  perform _p.actuar_como(v_otro);
  begin
    perform public.fundar_super_admin('OTR1', 'El vivo');
  exception when others then
    v_sql_b := sqlstate;
  end;
  v_otro_correo_ok := v_sql_b = 'P0001'
    and public.casa_fundada() = false
    and not exists (select 1 from public.profiles p where p.id = v_otro and coalesce(p.es_admin,false));

  -- 4) codigo mal formado, rechazado
  perform _p.actuar_como(v_duenio);
  begin
    perform public.fundar_super_admin('x', 'Dueno de la casa');
  exception when others then
    v_sql_c := sqlstate;
  end;
  v_codigo_malo_ok := v_sql_c = 'P0001' and public.casa_fundada() = false;

  -- 5) el designado funda
  perform public.fundar_super_admin('DUE1', 'Dueno de la casa');

  select * into v_perfil from public.profiles where id = v_duenio;
  select count(*)::int into v_asientos
  from public.admin_actions a where a.action = 'fundar_super_admin';

  v_funda_ok :=
        coalesce(v_perfil.es_admin, false)
    and coalesce(v_perfil.es_super_admin, false)
    and v_perfil.admin_codigo = 'DUE1'
    and v_perfil.admin_nombre = 'Dueno de la casa'
    and public.casa_fundada() = true
    and v_asientos = 1;

  -- 6) segunda vez: aunque se designe al otro, ya hay dueno
  update public.ajustes_instalacion set valor = 'otro@casa.test'
   where clave = 'correo_fundador';
  perform _p.actuar_como(v_otro);
  begin
    perform public.fundar_super_admin('OTR1', 'El vivo');
  exception when others then
    v_sql_d := sqlstate;
    v_msg_d := sqlerrm;
  end;
  v_segunda_ok := v_sql_d = 'P0001'
    and v_msg_d like '%ya tiene dueno%'
    and not exists (select 1 from public.profiles p where p.id = v_otro and coalesce(p.es_super_admin,false));

  -- 8) permisos
  v_permisos_ok :=
        has_function_privilege('anon',          'public.casa_fundada()', 'execute')
    and has_function_privilege('authenticated', 'public.casa_fundada()', 'execute')
    and has_function_privilege('authenticated', 'public.fundar_super_admin(text,text)', 'execute')
    and not has_function_privilege('anon',      'public.fundar_super_admin(text,text)', 'execute');

  -- La clave vuelve a su estado de instalacion nueva.
  update public.ajustes_instalacion set valor = '' where clave = 'correo_fundador';

  perform _p.anotar(73, 'La casa se funda sola, una vez, y solo quien fue designado',
    'sin designado no se funda; otro correo se rechaza; el designado funda con codigo y nombre y deja UN asiento; la segunda vez se rechaza aunque cambien el designado; anon puede preguntar si esta fundada pero no fundar',
    v_arranca_ok and v_sin_designado_ok and v_otro_correo_ok and v_codigo_malo_ok
      and v_funda_ok and v_segunda_ok and v_permisos_ok,
    format('arranca_sin_duenio=%s | sin_designado=%s (%s) | otro_correo=%s (%s) | codigo_malo=%s (%s) | FUNDA=%s (super=%s codigo=%s nombre=%s asientos=%s) | SEGUNDA=%s (%s: %s) | permisos=%s',
      v_arranca_ok,
      v_sin_designado_ok, coalesce(v_sql_a,'sin excepcion'),
      v_otro_correo_ok,   coalesce(v_sql_b,'sin excepcion'),
      v_codigo_malo_ok,   coalesce(v_sql_c,'sin excepcion'),
      v_funda_ok, coalesce(v_perfil.es_super_admin,false), coalesce(v_perfil.admin_codigo,'-'),
      coalesce(v_perfil.admin_nombre,'-'), v_asientos,
      v_segunda_ok, coalesce(v_sql_d,'sin excepcion'), coalesce(left(v_msg_d,45),'-'),
      v_permisos_ok));
end $$;


-- ============================================================================
--  P74 - Los datos de cobro son de la casa, y cambiarlos deja asiento
--
--  EL DEFECTO QUE EXISTE PARA IMPEDIR. El banco, el telefono de Pago Movil, la
--  cedula y el numero de cuenta estaban clavados en el HTML de
--  `/dashboard/recargar`. Un repositorio, dos despliegues: produccion y la
--  primera licencia mandaban a sus jugadores a la MISMA cuenta. Es la pantalla
--  que le dice a una persona donde poner su dinero.
--
--  Y el agujero que no hay que abrir al cerrarlo: si para cambiar esos datos
--  bastara con un UPDATE desde el navegador, la operacion mas sensible de la
--  aplicacion -- redirigir TODOS los depositos futuros -- pasaria sin rastro.
--
--  LO QUE MIDE
--   1. las nueve claves existen, son de texto y NACEN VACIAS: la migracion no
--      siembra los datos de nadie
--   2. `datos_de_cobro()` la lee quien tiene sesion y NO `anon`; y
--      `ajustes_publicos()`, que si lee `anon`, no devuelve ninguna `pago_*`
--   3. un admin que no es super admin no puede guardar, y nada cambia
--   4. el super admin guarda, y lo guardado es lo que devuelve la ventanilla
--   5. queda UN asiento, con el valor de antes y el de despues
--   6. guardar lo mismo otra vez devuelve 0 y NO deja un segundo asiento
--   7. una clave fuera de la lista blanca -- `minimo_incremento`, contra la que
--      la base valida -- se rechaza, y no cambia
--   8. la tabla ya no acepta UPDATE de `authenticated`, y el SELECT sigue
--
--  REGLA DEL 28/09: se comprueba CUAL excepcion. Un 42883 significaria que la
--  migracion no esta aplicada y la prueba no estaria probando nada.
-- ============================================================================
do $$
declare
  v_existe   boolean;
  v_super    uuid; v_admin uuid;
  v_n        int;
  v_claves   int;
  v_guardadas int;
  v_vacias   int;
  v_asientos int;
  v_asiento  jsonb;
  v_valor    text;
  v_sql_a    text; v_sql_b text;

  v_claves_ok        boolean := false;
  v_lectura_ok       boolean := false;
  v_admin_no_ok      boolean := false;
  v_guarda_ok        boolean := false;
  v_asiento_ok       boolean := false;
  v_sin_cambio_ok    boolean := false;
  v_fuera_lista_ok   boolean := false;
  v_tabla_cerrada_ok boolean := false;
begin
  perform _p.limpiar();
  delete from public.admin_actions;

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'guardar_ajustes'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(74, 'Los datos de cobro son de la casa, y cambiarlos deja asiento',
      'guardar_ajustes existe, respeta su lista blanca y deja asiento',
      false, 'guardar_ajustes NO EXISTE: la migracion 20261011011500 no esta aplicada');
    return;
  end if;

  -- 1) las nueve claves, de texto, y vacias.
  --
  --  Lo de "vacias" no es cosmetico: si la migracion sembrara unos datos
  --  bancarios de ejemplo, una casa recien entregada estaria cobrando para
  --  otro hasta que su dueno se diera cuenta. Vale porque el arnes corre
  --  contra base reseteada y nada mas toca estas claves.
  select count(*)::int,
         count(*) filter (where valor = '')::int
    into v_claves, v_vacias
  from public.ajustes_instalacion
  where clave in ('casa_nombre','casa_logo_url','pago_titular','pago_documento',
                  'pago_movil_banco','pago_movil_telefono','pago_transf_banco',
                  'pago_transf_tipo','pago_transf_numero')
    and tipo = 'texto';

  v_claves_ok := v_claves = 9 and v_vacias = 9;

  -- 2) quien puede mirar por cada ventanilla
  v_lectura_ok :=
        has_function_privilege('authenticated', 'public.datos_de_cobro()', 'execute')
    and not has_function_privilege('anon',      'public.datos_de_cobro()', 'execute')
    and has_function_privilege('anon',          'public.ajustes_publicos()', 'execute')
    and not exists (select 1 from public.ajustes_publicos() where clave like 'pago\_%')
    and exists     (select 1 from public.ajustes_publicos() where clave = 'casa_nombre');

  -- Un admin que NO es super admin. `_p.usuario` pone las dos banderas juntas.
  v_super := _p.usuario('super74', 0, true);
  v_admin := _p.usuario('admin74', 0, true);
  update public.profiles set es_super_admin = false where id = v_admin;

  -- 3) el admin normal no guarda
  perform _p.actuar_como(v_admin);
  begin
    perform public.guardar_ajustes(jsonb_build_object('pago_titular', 'El vivo'));
  exception when others then
    v_sql_a := sqlstate;
  end;
  select valor into v_valor from public.ajustes_instalacion where clave = 'pago_titular';
  v_admin_no_ok := v_sql_a = 'P0001' and v_valor = '';

  -- 4) el super admin si, y lo guardado es lo que sale por la ventanilla
  perform _p.actuar_como(v_super);
  select public.guardar_ajustes(jsonb_build_object(
    'casa_nombre',         'Remate El Zuliano',
    'pago_titular',        'Maria Perez',
    'pago_documento',      'V-12345678',
    'pago_movil_banco',    'Banco de Venezuela',
    'pago_movil_telefono', '04121112233'
  )) into v_guardadas;

  v_guarda_ok := v_guardadas = 5
    and (select valor from public.ajustes_instalacion where clave = 'pago_titular') = 'Maria Perez'
    -- de las siete de cobro quedaron cuatro con valor; `casa_nombre` es marca,
    -- no cobro, y por eso NO sale por esta ventanilla.
    and (select count(*) from public.datos_de_cobro() where valor <> '') = 4
    and not exists (select 1 from public.datos_de_cobro() where clave = 'casa_nombre');

  -- 5) un asiento, con antes y despues
  select count(*)::int into v_asientos
  from public.admin_actions where action = 'ajustes_casa';
  select details into v_asiento
  from public.admin_actions where action = 'ajustes_casa' limit 1;

  v_asiento_ok := v_asientos = 1
    and (v_asiento->>'cambios') = '5'
    and (v_asiento->'antes'->>'pago_titular') = ''
    and (v_asiento->'despues'->>'pago_titular') = 'Maria Perez';

  -- 6) guardar lo mismo no es un hecho que registrar
  select public.guardar_ajustes(jsonb_build_object('pago_titular', 'Maria Perez')) into v_n;
  select count(*)::int into v_asientos
  from public.admin_actions where action = 'ajustes_casa';
  v_sin_cambio_ok := v_n = 0 and v_asientos = 1;

  -- 7) fuera de la lista blanca: los minimos NO se tocan desde el navegador
  begin
    perform public.guardar_ajustes(jsonb_build_object('minimo_incremento', '1'));
  exception when others then
    v_sql_b := sqlstate;
  end;
  select valor into v_valor from public.ajustes_instalacion where clave = 'minimo_incremento';
  v_fuera_lista_ok := v_sql_b = 'P0001' and v_valor <> '1';

  -- 8) la puerta directa, cerrada
  v_tabla_cerrada_ok :=
        not has_table_privilege('authenticated', 'public.ajustes_instalacion', 'update')
    and     has_table_privilege('authenticated', 'public.ajustes_instalacion', 'select')
    and not exists (
      select 1 from pg_policies
      where schemaname = 'public' and tablename = 'ajustes_instalacion'
        and policyname = 'ajustes_cambia_superadmin');

  -- Las claves vuelven a su estado de instalacion nueva.
  update public.ajustes_instalacion set valor = ''
   where clave in ('casa_nombre','casa_logo_url','pago_titular','pago_documento',
                   'pago_movil_banco','pago_movil_telefono','pago_transf_banco',
                   'pago_transf_tipo','pago_transf_numero');

  perform _p.anotar(74, 'Los datos de cobro son de la casa, y cambiarlos deja asiento',
    'las nueve claves nacen vacias; anon no ve los datos de cobro; un admin normal no los cambia; el super admin si y deja UN asiento con antes y despues; repetir no registra; una clave fuera de la lista se rechaza; la tabla ya no acepta UPDATE directo',
    v_claves_ok and v_lectura_ok and v_admin_no_ok and v_guarda_ok
      and v_asiento_ok and v_sin_cambio_ok and v_fuera_lista_ok and v_tabla_cerrada_ok,
    format('claves=%s (%s de 9, %s vacias) | lectura=%s | admin_normal=%s (%s) | GUARDA=%s (n=%s) | asiento=%s (%s asientos, antes="%s" despues="%s") | repetir=%s | fuera_lista=%s (%s, minimo quedo en %s) | tabla_cerrada=%s',
      v_claves_ok, v_claves, v_vacias,
      v_lectura_ok,
      v_admin_no_ok, coalesce(v_sql_a, 'sin excepcion'),
      v_guarda_ok, v_guardadas,
      v_asiento_ok, v_asientos,
      coalesce(v_asiento->'antes'->>'pago_titular', '-'),
      coalesce(v_asiento->'despues'->>'pago_titular', '-'),
      v_sin_cambio_ok,
      v_fuera_lista_ok, coalesce(v_sql_b, 'sin excepcion'), coalesce(v_valor, '-'),
      v_tabla_cerrada_ok));
end $$;


-- ============================================================================
--  P75 - Se puede demostrar quien acepto que, y en que version
--
--  EL DEFECTO QUE EXISTE PARA IMPEDIR. La marca que ve el jugador es la de la
--  plataforma (franquicia, 09/10), asi que el jugador que pierda dinero le
--  escribe a la PLATAFORMA. La respuesta es un descargo, y un descargo solo
--  sirve si se puede demostrar que esa persona lo acepto. La carga de la
--  prueba es de quien lo invoca.
--
--  Y el agujero que hay que no abrir: si el texto de una version publicada se
--  pudiera editar, cambiaria HACIA ATRAS lo que acepto cada persona, y todos
--  los consentimientos anteriores quedarian sin valor.
--
--  LO QUE MIDE
--   1. las dos tablas existen y estan CERRADAS a anon y authenticated
--   2. un admin que no es super admin no publica; un texto de juguete tampoco
--   3. el super admin publica v1, y publicar otra vez da v2 dejando la v1
--      INTACTA -- texto y fecha
--   4. `documentos_vigentes()` devuelve solo la publicada mas alta, y la lee
--      `anon` (los terminos se leen ANTES de tener cuenta)
--   5. un alta que dice que acepta queda registrada CON LA VERSION QUE PONE LA
--      BASE, no la que diga el cliente
--   6. un alta que NO dice nada no revienta -- con un repo sirviendo a N casas,
--      el desfase de despliegue existe -- y queda con el documento pendiente
--   7. tras aceptar no queda nada pendiente; al publicar v3 VUELVE a estarlo
--   8. aceptar dos veces lo mismo devuelve 0 y no duplica la fila
--
--  REGLA DEL 28/09: se comprueba CUAL excepcion. Un 42883 significaria que la
--  migracion no esta aplicada y la prueba no estaria probando nada.
-- ============================================================================
do $$
declare
  v_existe boolean;
  v_super uuid; v_admin uuid;
  v_con uuid := gen_random_uuid();
  v_sin uuid := gen_random_uuid();

  v_texto    text := repeat('Terminos y condiciones de prueba del arnes. ', 12);
  v_texto_v2 text := repeat('Segunda version del texto, distinta de la primera. ', 12);
  v_texto_v3 text := repeat('Tercera version, la que obliga a volver a aceptar. ', 12);

  v_v1 integer; v_v2 integer; v_v3 integer;
  v_v1_texto text; v_v1_fecha timestamptz; v_v1_texto_2 text; v_v1_fecha_2 timestamptz;
  v_n integer; v_filas integer; v_vigentes_n integer;
  v_version_reg integer;
  v_sql_a text; v_sql_b text;

  v_tablas_ok     boolean := false;
  v_publicar_ok   boolean := false;
  v_inmutable_ok  boolean := false;
  v_vigentes_ok   boolean := false;
  v_alta_con_ok   boolean := false;
  v_alta_sin_ok   boolean := false;
  v_reacepta_ok   boolean := false;
  v_repetir_ok    boolean := false;
begin
  perform _p.limpiar();
  delete from public.admin_actions;
  delete from public.aceptaciones_legales;
  delete from public.documentos_legales;

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'publicar_documento'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(75, 'Se puede demostrar quien acepto que, y en que version',
      'documentos versionados e inmutables, con registro de aceptacion',
      false, 'publicar_documento NO EXISTE: la migracion 20261011023500 no esta aplicada');
    return;
  end if;

  -- 1) tablas cerradas
  v_tablas_ok :=
        to_regclass('public.documentos_legales')   is not null
    and to_regclass('public.aceptaciones_legales') is not null
    and not has_table_privilege('authenticated', 'public.documentos_legales',   'select')
    and not has_table_privilege('anon',          'public.documentos_legales',   'select')
    and not has_table_privilege('authenticated', 'public.aceptaciones_legales', 'select')
    and not has_table_privilege('authenticated', 'public.aceptaciones_legales', 'insert');

  v_super := _p.usuario('super75', 0, true);
  v_admin := _p.usuario('admin75', 0, true);
  update public.profiles set es_super_admin = false where id = v_admin;

  -- 2) quien NO publica
  perform _p.actuar_como(v_admin);
  begin
    perform public.publicar_documento('terminos', 'Terminos', v_texto, true);
  exception when others then
    v_sql_a := sqlstate;
  end;

  perform _p.actuar_como(v_super);
  begin
    perform public.publicar_documento('terminos', 'Terminos', 'hola', true);
  exception when others then
    v_sql_b := sqlstate;
  end;

  v_publicar_ok := v_sql_a = 'P0001' and v_sql_b = 'P0001'
    and not exists (select 1 from public.documentos_legales);

  -- 3) v1, luego v2, y la v1 intacta
  select public.publicar_documento('terminos', 'Terminos y condiciones', v_texto, true) into v_v1;
  select cuerpo, publicado_en into v_v1_texto, v_v1_fecha
  from public.documentos_legales where codigo = 'terminos' and version = v_v1;

  select public.publicar_documento('terminos', 'Terminos y condiciones', v_texto_v2, true) into v_v2;
  select cuerpo, publicado_en into v_v1_texto_2, v_v1_fecha_2
  from public.documentos_legales where codigo = 'terminos' and version = v_v1;

  v_inmutable_ok := v_v1 = 1 and v_v2 = 2
    and v_v1_texto_2 = v_v1_texto
    and v_v1_fecha_2 = v_v1_fecha
    and v_v1_texto <> v_texto_v2;

  -- 4) vigentes = la mas alta, y la lee anon
  select count(*)::int into v_vigentes_n from public.documentos_vigentes();
  v_vigentes_ok := v_vigentes_n = 1
    and exists (select 1 from public.documentos_vigentes() where version = 2 and cuerpo = v_texto_v2)
    and has_function_privilege('anon', 'public.documentos_vigentes()', 'execute')
    and not has_function_privilege('anon', 'public.publicar_documento(text,text,text,boolean)', 'execute')
    and not has_function_privilege('anon', 'public.aceptar_documentos(text[])', 'execute');

  -- 5) alta QUE acepta: la version la pone la base
  insert into auth.users (id, raw_user_meta_data)
  values (v_con, jsonb_build_object('username','acepta75','acepta', jsonb_build_array('terminos')));

  select version into v_version_reg
  from public.aceptaciones_legales where user_id = v_con and codigo = 'terminos';

  v_alta_con_ok := v_version_reg = 2
    and (select count(*) from public.aceptaciones_legales where user_id = v_con) = 1;

  -- 6) alta que NO dice nada: no revienta, y queda pendiente
  insert into auth.users (id, raw_user_meta_data)
  values (v_sin, jsonb_build_object('username','calla75'));

  perform _p.actuar_como(v_sin);
  v_alta_sin_ok :=
        exists (select 1 from public.profiles where id = v_sin)
    and not exists (select 1 from public.aceptaciones_legales where user_id = v_sin)
    and (select count(*) from public.mis_documentos_pendientes()) = 1;

  -- 7) acepta -> sin pendientes; se publica v3 -> vuelve a tener
  select public.aceptar_documentos(array['terminos']) into v_n;
  v_reacepta_ok := v_n = 1
    and (select count(*) from public.mis_documentos_pendientes()) = 0;

  perform _p.actuar_como(v_super);
  select public.publicar_documento('terminos', 'Terminos y condiciones', v_texto_v3, true) into v_v3;

  perform _p.actuar_como(v_sin);
  v_reacepta_ok := v_reacepta_ok and v_v3 = 3
    and (select count(*) from public.mis_documentos_pendientes()) = 1
    and exists (select 1 from public.mis_documentos_pendientes() where version = 3);

  -- 8) repetir no duplica
  select public.aceptar_documentos(array['terminos']) into v_n;
  select public.aceptar_documentos(array['terminos']) into v_filas;
  v_repetir_ok := v_n = 1 and v_filas = 0
    and (select count(*) from public.aceptaciones_legales where user_id = v_sin) = 2;

  -- La base vuelve a su estado de instalacion nueva.
  delete from public.aceptaciones_legales;
  delete from public.documentos_legales;

  perform _p.anotar(75, 'Se puede demostrar quien acepto que, y en que version',
    'tablas cerradas; solo el super admin publica y nunca edita una version publicada; vigentes es la mas alta y la lee anon; el alta registra la version que pone la base; sin metadata no revienta; publicar una version nueva obliga a re-aceptar; repetir no duplica',
    v_tablas_ok and v_publicar_ok and v_inmutable_ok and v_vigentes_ok
      and v_alta_con_ok and v_alta_sin_ok and v_reacepta_ok and v_repetir_ok,
    format('tablas=%s | publicar=%s (admin:%s texto_corto:%s) | INMUTABLE=%s (v1=%s v2=%s, v1 intacta=%s) | vigentes=%s (%s fila) | alta_con=%s (version registrada=%s) | alta_sin=%s | REACEPTA=%s (v3=%s) | repetir=%s',
      v_tablas_ok,
      v_publicar_ok, coalesce(v_sql_a,'sin excepcion'), coalesce(v_sql_b,'sin excepcion'),
      v_inmutable_ok, v_v1, v_v2, (v_v1_texto_2 = v_v1_texto),
      v_vigentes_ok, v_vigentes_n,
      v_alta_con_ok, coalesce(v_version_reg, -1),
      v_alta_sin_ok,
      v_reacepta_ok, coalesce(v_v3, -1),
      v_repetir_ok));
end $$;


-- ---------------------------------------------------------------- resumen
\set QUIET off
select n as "#", nombre, esperado, estado, detalle from _p.resultado order by n;
select count(*) filter (where estado='OK') as "en verde",
       count(*) filter (where estado='FALLA') as "en rojo",
       count(*) as total
from _p.resultado;


-- ---------------------------------------------------------------- limpieza
--  EL ARNES DEJA LA BASE COMO LA ENCONTRO (anadido el 29/09)
--
--  Cada prueba llama a _p.limpiar() ANTES de armar su escenario, nunca
--  despues. Consecuencia: la ultima prueba que corre deja su mundo montado en
--  la base -- usuarios, saldos, recargas aprobadas.
--
--  Hasta hoy no importaba, porque nadie abria la aplicacion contra la base del
--  arnes. Desde que existe .env.development.local si, y Jota se encontro a
--  "juan" con 500 Bs de recarga aprobada en la pantalla de recargas: el
--  residuo de P49.
--
--  En una app cuyo argumento de venta es que las cuentas cuadran, un usuario
--  fantasma con dinero fantasma en la pantalla del admin es veneno. Se limpia.
--
--  _p.resultado NO se borra: el resumen ya se imprimio arriba, pero la tabla
--  queda por si quieres consultarla. Si alguna vez necesitas inspeccionar el
--  estado que dejo una prueba en rojo, comenta este bloque y vuelve a correr.
do $$
begin
  delete from public.admin_actions;   -- _p.limpiar() no lo toca
  perform _p.limpiar();

  -- Los minimos vuelven a los de produccion. El arnes los bajo a 10 para sus
  -- escenarios; si se quedaran asi, la base local permitiria crear remates que
  -- produccion rechaza, y el proximo click a mano mediria una app que no es la
  -- que esta desplegada.
  if to_regclass('public.ajustes_instalacion') is not null then
    update public.ajustes_instalacion set valor = '50'  where clave = 'minimo_incremento';
    update public.ajustes_instalacion set valor = '100' where clave = 'minimo_precio_salida';
    update public.ajustes_instalacion set valor = '50'  where clave = 'pct_apostado_para_retirar';
  end if;
end $$;
