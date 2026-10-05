-- ===========================================================================
--  diagnostico_02oct.sql   -   SOLO LECTURA
--
--  POR QUE ESTA REESCRITO
--  La version anterior usaba `\echo` para los titulos. `\echo` es una metaorden
--  de psql, no SQL: el servidor de Postgres no la conoce. No se si el editor
--  del panel las descarta por su cuenta -tus corridas anteriores de otros
--  snippets si dieron salida-, pero no tengo manera de comprobarlo desde aqui y
--  no es una duda que valga la pena tener en medio de un diagnostico. Ahora es
--  UNA sola consulta de SQL puro que devuelve dos columnas: se pega, se ejecuta
--  y se copia la tabla entera de una vez.
--  Si alguno de los otros snippets de esta carpeta te dio error de sintaxis,
--  tienen el mismo `\echo` y hay que convertirlos igual. Los que te funcionaron
--  no hay que tocarlos.
--
--  DOS PREGUNTAS QUE NO SE PUEDEN RESPONDER SIN MIRAR PRODUCCION:
--    A. De donde sale el descuadre de -1.380 en /admin/contabilidad.
--    B. Por que las recargas y los retiros no le llegan solos al admin.
--
--  No escribe nada. Donde: SQL Editor del panel, contra PRODUCCION.
-- ===========================================================================

with
-- --------------------------------------------------------------------------
-- A0. El descuadre, termino por termino.
--     casa_resumen() no se puede llamar desde aqui porque exige auth.uid(),
--     asi que se repite su aritmetica tal cual esta en la migracion
--     20260924160000. El descuadre es:
--       suma de resultado_remate  -  (recargas - pagados - pendientes - saldos)
-- --------------------------------------------------------------------------
t as (
  select
    (select coalesce(sum(monto),0) from public.deposit_requests  where estado='aprobado')   as recargas,
    (select coalesce(sum(monto),0) from public.withdraw_requests where estado='pagado')     as pagados,
    (select coalesce(sum(monto),0) from public.withdraw_requests where estado='pendiente')  as pendientes,
    (select coalesce(sum(saldo_disponible + saldo_bloqueado),0) from public.wallets)        as saldos,
    (select coalesce(sum(monto) filter (where tipo='resultado_remate'),0) from public.house_ledger) as resultados,
    (select coalesce(sum(monto) filter (where tipo='aporte_capital'),0)   from public.house_ledger) as aportes,
    (select coalesce(sum(monto) filter (where tipo='retiro_utilidad'),0)  from public.house_ledger) as utilidades,
    (select coalesce(sum(monto) filter (where tipo='ajuste'),0)           from public.house_ledger) as ajustes
),
a0 as (
  select 0 as orden, 0 as sub, 'A0 descuadre' as seccion,
         'recargas=' || recargas ||
         ' | pagados=' || pagados ||
         ' | pendientes=' || pendientes ||
         ' | saldos=' || saldos ||
         ' | perdida_usuarios=' || (recargas - pagados - pendientes - saldos) ||
         ' | libro_resultados=' || resultados ||
         ' | aportes=' || aportes || ' | utilidades=' || utilidades || ' | ajustes=' || ajustes ||
         ' | DESCUADRE=' || (resultados - (recargas - pagados - pendientes - saldos)) as dato
  from t
),

-- --------------------------------------------------------------------------
-- A1. Que migraciones estan aplicadas de verdad. Las diez ultimas.
--     Aqui tienen que estar 20261001130000 (motivos) y 20261002100000
--     (horarios opcionales) si ya las empujaste.
-- --------------------------------------------------------------------------
a1 as (
  select 1 as orden, row_number() over (order by version desc) as sub,
         'A1 migraciones' as seccion, version as dato
  from (select version from supabase_migrations.schema_migrations order by version desc limit 10) z
),

-- --------------------------------------------------------------------------
-- A2. Remates cerrados o liquidados y si ya tienen su asiento en el libro.
--     CERRAR le cobra a los lideres; el asiento lo escribe LIQUIDAR. Entre
--     una cosa y otra el libro va por detras de los saldos A PROPOSITO.
--     Si hay cerrados sin liquidar, parte del descuadre es eso y no hay nada
--     roto. Si NO hay ninguno, el descuadre es anterior al libro (tarea 2.18)
--     y lo que falta es un asiento de apertura.
-- --------------------------------------------------------------------------
a2 as (
  select 2 as orden, row_number() over (order by r.closed_at desc nulls last) as sub,
         'A2 remates cerrados' as seccion,
         r.estado || ' | ' || coalesce(r.nombre,'(sin nombre)') ||
         ' | cerrado=' || coalesce(r.closed_at::text,'(nunca)') ||
         ' | en_el_libro=' ||
         (exists (select 1 from public.house_ledger h
                  where h.tipo='resultado_remate' and h.ref_externa = r.id::text))::text ||
         ' | id=' || r.id::text as dato
  from public.remates r
  where r.estado in ('cerrado','liquidado') or r.closed_at is not null
),

-- --------------------------------------------------------------------------
-- A3. Cuanto se le cobro a los usuarios por remates que AUN no estan en el
--     libro. Si esta cifra se parece al descuadre, la explicacion es la de A2.
-- --------------------------------------------------------------------------
a3 as (
  select 3 as orden, 0 as sub, 'A3 cobrado sin asiento' as seccion,
         coalesce(sum(-m.monto),0)::text as dato
  from public.wallet_movements m
  where m.tipo = 'apuesta_cobro'
    and not exists (select 1 from public.house_ledger h
                    where h.tipo='resultado_remate' and h.ref_externa = m.ref_externa)
),

-- --------------------------------------------------------------------------
-- A4. El libro, asiento por asiento.
-- --------------------------------------------------------------------------
a4 as (
  select 4 as orden, row_number() over (order by created_at desc) as sub,
         'A4 libro' as seccion,
         tipo || ' | ' || monto || ' | ' || motivo ||
         ' | ref=' || coalesce(ref_externa,'(ninguna)') ||
         ' | ' || created_at::text as dato
  from public.house_ledger
),

-- --------------------------------------------------------------------------
-- A5. Los movimientos de cartera por tipo. Un `ajuste_manual` mueve el saldo
--     de un usuario SIN dejar asiento en el libro: si la suma de los ajustes
--     se parece a lo que falta de A3, ahi esta la otra mitad.
-- --------------------------------------------------------------------------
a5 as (
  select 5 as orden, row_number() over (order by m.tipo::text) as sub,
         'A5 movimientos' as seccion,
         m.tipo::text || ' | cuantos=' || count(*) || ' | suma=' || sum(m.monto) as dato
  from public.wallet_movements m
  group by m.tipo
),

-- --------------------------------------------------------------------------
-- A6. El primer movimiento de cada tipo, con fecha. Si hay cobros o premios
--     ANTERIORES a la migracion del libro (24/09), el descuadre es historico.
-- --------------------------------------------------------------------------
a6 as (
  select 6 as orden, row_number() over (order by m.tipo::text) as sub,
         'A6 primer movimiento' as seccion,
         m.tipo::text || ' | ' || min(m.created_at)::text as dato
  from public.wallet_movements m
  group by m.tipo
),

-- --------------------------------------------------------------------------
-- B1. Los triggers que emiten las senales de realtime: existen y estan
--     habilitados? tgenabled 'O' es habilitado; 'D' es deshabilitado.
-- --------------------------------------------------------------------------
b1 as (
  select 7 as orden, row_number() over (order by c.relname, t.tgname) as sub,
         'B1 triggers realtime' as seccion,
         c.relname || ' | ' || t.tgname || ' | tgenabled=' || t.tgenabled::text as dato
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and not t.tgisinternal
    and (t.tgname like 'avisar%' or t.tgname like '%senal%' or t.tgname like '%realtime%')
),

-- --------------------------------------------------------------------------
-- B2. Las politicas de realtime.messages. Sin ellas los eventos se emiten y
--     no los recibe nadie.
-- --------------------------------------------------------------------------
b2 as (
  select 8 as orden, row_number() over (order by p.polname) as sub,
         'B2 politicas realtime.messages' as seccion,
         p.polname || ' | cmd=' || p.polcmd::text || ' | roles=' ||
         coalesce((select string_agg(r.rolname, ',') from pg_roles r where r.oid = any(p.polroles)), 'PUBLIC') as dato
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'realtime' and c.relname = 'messages'
),

-- --------------------------------------------------------------------------
-- B3. Se emitio algo en las ultimas dos horas? realtime.messages guarda los
--     eventos un rato. Si no hay NADA de admin:caja, el problema es el EMISOR.
--     Si hay, el problema es el OYENTE (la politica, o la suscripcion del
--     navegador). Esta es la que decide; las dos de arriba son contexto.
-- --------------------------------------------------------------------------
b3 as (
  select 9 as orden, row_number() over (order by inserted_at desc) as sub,
         'B3 mensajes emitidos' as seccion,
         topic || ' | ' || coalesce(event,'(sin evento)') || ' | ' || inserted_at::text as dato
  from realtime.messages
  where inserted_at > now() - interval '2 hours'
),
b3v as (
  select 9 as orden, 999 as sub, 'B3 mensajes emitidos' as seccion,
         '(no hay ningun mensaje en las ultimas 2 horas: o no se emitio nada, o la retencion ya los borro)' as dato
  where not exists (select 1 from realtime.messages where inserted_at > now() - interval '2 hours')
)

select seccion, dato
from (
  select * from a0 union all select * from a1 union all select * from a2 union all
  select * from a3 union all select * from a4 union all select * from a5 union all
  select * from a6 union all select * from b1 union all select * from b2 union all
  select * from b3 union all select * from b3v
) todo
order by orden, sub;
