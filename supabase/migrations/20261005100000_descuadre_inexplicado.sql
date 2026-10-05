-- ===========================================================================
--  20261005100000_descuadre_inexplicado.sql
--
--  LA ALARMA QUE GRITABA SIN MOTIVO
--
--  /admin/contabilidad mostraba una franja ambar que decia:
--
--      "El libro no cuadra con los saldos. Diferencia de -1.380,00 Bs.
--       Esto no deberia pasar nunca: avisa antes de seguir operando."
--
--  Y pasa SIEMPRE. Por diseno.
--
--  CERRAR le cobra a los lideres (`apuesta_cobro`): el saldo del usuario baja
--  en ese instante. LIQUIDAR escribe el asiento en el libro. Entre una cosa y
--  la otra el libro va por detras de los saldos, y eso no es un defecto: es la
--  secuencia correcta. Un remate cerrado el viernes y liquidado el lunes tiene
--  tres dias de descuadre legitimo.
--
--  El 05/10/2026 se comprobo contra produccion: descuadre -1.380,00 y cobrado
--  sin asentar 1.380,00. Mismo numero al centimo, con 8 remates cerrados sin
--  liquidar. Reconstruidos desde `wallet_movements`, los saldos daban 6.370,00
--  exactos contra los 6.370,00 de `wallets`. No faltaba un centimo en ninguna
--  parte: la contabilidad estaba bien y la alarma estaba mal.
--
--  POR QUE ESTO IMPORTA MAS DE LO QUE PARECE
--  Una alarma roja que se enciende en una situacion normal es una alarma que
--  se aprende a ignorar. El dia que senale una fuga de verdad, nadie le va a
--  creer -- y en una app que se alquila, la mira un licenciatario que no sabe
--  que esa franja es normal los lunes. Una alarma que miente es peor que no
--  tener alarma, porque ademas da confianza falsa en las que si funcionan.
--
--  LA CUENTA NUEVA
--
--    pendiente_de_liquidar = -SUMA(apuesta_cobro + apuesta_devolucion + premio)
--                            de los remates que AUN no tienen su asiento
--
--  Es la misma formula con la que `liquidar_remate` calcula el resultado del
--  remate, aplicada a los que todavia no han pasado por ahi. A proposito: si
--  manana cambia como se calcula el resultado, estas dos cuentas tienen que
--  cambiar juntas o el descuadre deja de significar nada.
--
--    descuadre_inexplicado = descuadre + pendiente_de_liquidar
--
--  Y esto es una IDENTIDAD, no una aproximacion. Desarrollando:
--
--    perdida_usuarios = -SUMA(cobros + devoluciones + premios) de TODOS
--                     = resultados_ya_asentados + pendiente_de_liquidar
--    descuadre        = resultados - perdida_usuarios = -pendiente_de_liquidar
--    inexplicado      = 0
--
--  El desarrollo descansa en un supuesto, y conviene verlo escrito: que
--  `ajuste_manual` solo se usa para devolver un retiro rechazado. Si alguien
--  mueve un saldo a mano por cualquier otro motivo, la identidad se rompe y
--  `descuadre_inexplicado` deja de ser cero. **Eso es exactamente lo que la
--  alarma tiene que cazar.** El instrumento nuevo no es mas permisivo que el
--  viejo: es mas afilado. Deja de sonar cuando no pasa nada y empieza a sonar
--  cuando pasa algo que antes quedaba enterrado entre liquidaciones
--  pendientes.
--
--  POR QUE HAY DROP ANTES DEL CREATE
--  `create or replace function` NO puede cambiar el tipo de retorno, y aqui se
--  le anaden dos columnas a la tabla que devuelve. Sin el drop, error 42P13.
--  No hay riesgo de ambiguedad en PostgREST porque la funcion no lleva
--  argumentos, pero el drop hace falta igual.
--
--  LO QUE NO SE TOCA: `descuadre` se queda y sigue significando lo mismo. La
--  pantalla deja de alarmar con el, no de mostrarlo. Borrar un numero porque
--  ahora hay otro mejor es como se pierde la capacidad de comparar con las
--  capturas de la semana pasada.
-- ===========================================================================

drop function if exists public.casa_resumen();

create or replace function public.casa_resumen()
returns table(
  caja_total            numeric,
  obligaciones          numeric,
  patrimonio            numeric,
  capital_aportado      numeric,
  utilidades_retiradas  numeric,
  ajustes               numeric,
  resultado_operativo   numeric,
  perdida_usuarios      numeric,
  descuadre             numeric,
  pendiente_de_liquidar numeric,
  descuadre_inexplicado numeric,
  remates_sin_liquidar  integer,
  cubierto              boolean
)
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_user_id uuid := auth.uid();
  v_is_admin boolean;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  select (coalesce(es_admin, false) or coalesce(es_super_admin, false))
    into v_is_admin
  from public.profiles
  where id = v_user_id;

  if coalesce(v_is_admin, false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  return query
  with d as (
    select coalesce(sum(monto),0) as recargas from public.deposit_requests where estado='aprobado'
  ),
  wp as (
    select coalesce(sum(monto),0) as pagados from public.withdraw_requests where estado='pagado'
  ),
  wq as (
    select coalesce(sum(monto),0) as pendientes from public.withdraw_requests where estado='pendiente'
  ),
  s as (
    select coalesce(sum(saldo_disponible + saldo_bloqueado),0) as saldos from public.wallets
  ),
  l as (
    select
      coalesce(sum(monto) filter (where tipo='aporte_capital'),0)   as aportes,
      coalesce(sum(monto) filter (where tipo='retiro_utilidad'),0)  as utilidades,
      coalesce(sum(monto) filter (where tipo='ajuste'),0)           as ajustes,
      coalesce(sum(monto) filter (where tipo='resultado_remate'),0) as resultados
    from public.house_ledger
  ),
  -- Lo cobrado (y devuelto, y premiado) por remates que todavia no tienen su
  -- asiento. Mismo criterio que `liquidar_remate`, aplicado a los pendientes.
  p as (
    select coalesce(sum(-m.monto),0) as pendiente
    from public.wallet_movements m
    where m.tipo in ('apuesta_cobro','apuesta_devolucion','premio')
      and m.ref_externa is not null
      and not exists (
        select 1 from public.house_ledger h
        where h.tipo = 'resultado_remate' and h.ref_externa = m.ref_externa)
  ),
  -- Cuantos remates son. Un numero suelto no dice nada; "8 remates" si.
  rp as (
    select count(*)::integer as cuantos
    from public.remates r
    where r.closed_at is not null
      and not exists (
        select 1 from public.house_ledger h
        where h.tipo = 'resultado_remate' and h.ref_externa = r.id::text)
  )
  select
    (d.recargas - wp.pagados + l.aportes + l.utilidades + l.ajustes)            as caja_total,
    (s.saldos + wq.pendientes)                                                  as obligaciones,
    (d.recargas - wp.pagados + l.aportes + l.utilidades + l.ajustes)
      - (s.saldos + wq.pendientes)                                              as patrimonio,
    l.aportes                                                                   as capital_aportado,
    l.utilidades                                                                as utilidades_retiradas,
    l.ajustes                                                                   as ajustes,
    l.resultados                                                                as resultado_operativo,
    (d.recargas - wp.pagados - wq.pendientes - s.saldos)                        as perdida_usuarios,
    l.resultados - (d.recargas - wp.pagados - wq.pendientes - s.saldos)         as descuadre,
    p.pendiente                                                                 as pendiente_de_liquidar,
    (l.resultados - (d.recargas - wp.pagados - wq.pendientes - s.saldos))
      + p.pendiente                                                             as descuadre_inexplicado,
    rp.cuantos                                                                  as remates_sin_liquidar,
    ((d.recargas - wp.pagados + l.aportes + l.utilidades + l.ajustes)
      - (s.saldos + wq.pendientes)) >= 0                                        as cubierto
  from d, wp, wq, s, l, p, rp;
end;
$fn$;

comment on function public.casa_resumen() is
  'Foto contable de la casa. Solo admin. `descuadre` incluye lo normal (remates cerrados sin liquidar); el que hay que mirar es `descuadre_inexplicado`: distinto de cero significa que alguien movio un saldo sin dejar asiento. `cubierto` false significa que se estan pagando premios con dinero de los usuarios.';

revoke all on function public.casa_resumen() from public, anon;
grant execute on function public.casa_resumen() to authenticated;
