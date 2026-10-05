-- ===========================================================================
--  20261005140000_ajustes_publicos.sql
--
--  QUE LA PAGINA DE REGLAS NO MIENTA, EN NINGUNA INSTALACION
--
--  `/reglas` es lo que el jugador acepta antes de poner dinero. Hoy tiene
--  numeros clavados en el HTML, y eso tiene dos problemas:
--
--   1. Se desincroniza. El 05/10 se comprobo que esa pagina describe un modelo
--      de dinero que la base dejo de implementar el 24/09: dice que pujar
--      bloquea saldo (ya no), que el minimo manual es el automatico mas 10 Bs
--      (se quito el 23/09) y que la casa retiene siempre el 25% (es
--      configurable por remate). Y no menciona la regla del 50%, que la base SI
--      aplica -- asi que el jugador se entera al intentar retirar, que es el
--      peor momento posible.
--
--   2. No sirve para licenciar. Un licenciatario que ponga el porcentaje en 30
--      tendria una pagina de reglas prometiendole al jugador otra cosa. Una
--      regla que no coincide con lo que dice la pantalla es una reclamacion.
--
--  POR QUE UNA FUNCION Y NO UN `GRANT ... TO anon`
--  `ajustes_instalacion` esta cerrada a `anon` a proposito, y va a ir
--  creciendo: en el bloque de licencias le entran datos bancarios, SMTP y la
--  marca. Abrir la tabla entera para que la pagina publica lea un porcentaje
--  seria dejar la puerta abierta para todo lo que llegue despues.
--
--  Esta funcion devuelve una LISTA BLANCA. Lo que no este nombrado aqui no
--  sale, aunque alguien lo anada a la tabla manana. Es la diferencia entre una
--  puerta y una ventanilla.
-- ===========================================================================

create or replace function public.ajustes_publicos()
returns table (clave text, valor text)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select a.clave, a.valor
  from public.ajustes_instalacion a
  where a.clave in (
    -- Lo que el JUGADOR necesita saber para decidir si juega. Nada mas.
    'pct_apostado_para_retirar',
    'minimo_incremento',
    'minimo_precio_salida'
  );
$fn$;

comment on function public.ajustes_publicos() is
  'Los ajustes que la pagina de reglas puede ensenar a cualquiera, con o sin sesion. Lista blanca: lo que no este nombrado dentro no sale. Ver la migracion 20261005140000.';

-- La lee cualquiera, incluido quien todavia no se ha registrado: las reglas se
-- leen ANTES de abrir la cuenta, no despues.
revoke all on function public.ajustes_publicos() from public;
grant execute on function public.ajustes_publicos() to anon, authenticated;
