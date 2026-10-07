-- ===========================================================================
--  20261007150000_guardar_escaleras.sql
--
--  LAS ESCALERAS DE UN REMATE SE GUARDAN DE UNA VEZ O NO SE GUARDAN
--
--  EL PROBLEMA, MEDIDO (07/10/2026)
--
--  La pantalla de editar un remate guardaba las escaleras asi:
--
--    app/admin/remates/[id]/page.tsx:878   delete remate_price_rules del remate
--                                          <-- un viaje de red completo
--    app/admin/remates/[id]/page.tsx:882   insert de todas otra vez
--
--  Entre esas dos llamadas el remate NO TIENE NINGUNA ESCALERA. Si algo
--  interrumpe ahi -- se cae la conexion, se duerme el portatil, se cierra la
--  pestana -- el remate se queda asi, EN VIVO, y desde ese instante todos los
--  caballos suben con `remates.incremento_minimo` en vez de la escalera que
--  el organizador configuro.
--
--  Y lo peor no es la perdida: es que el admin ve "Error guardando cambios" y
--  deduce que no se guardo nada, cuando las escaleras ya se borraron. Volver a
--  guardar lo arregla -- pero solo si vuelve a guardar.
--
--  LO QUE ESTO NO ES: no es un problema de dinero. El monto que se cobra es
--  siempre el que la pantalla mostro, porque `remate_minimos()` y `hacer_puja`
--  leen la misma fuente (`_incremento_aplicable`). Nadie paga un numero
--  distinto del que vio y el descuadre sigue en cero. El dano es comercial: la
--  subasta avanza con incrementos que no son los anunciados.
--
--  LO QUE NO SE TOCA. El resto del guardado de esa pantalla sigue siendo una
--  secuencia de 16 o 17 escrituras sueltas (una por caballo). Eso es
--  `guardar_remate_completo`, decidido aparte el 07/10: aqui se cierra la
--  unica ventana que falla EN SILENCIO, no se reescribe la pantalla.
--
--  Y NO SE ANADE NINGUNA REGLA DE NEGOCIO. En particular se conserva lo
--  permisivo que ya era: se pueden reescribir las escaleras de un remate que
--  YA TIENE PUJAS, igual que hoy. Si eso debe prohibirse es otra decision, y
--  no se toma de prestado dentro de una migracion que viene a arreglar una
--  transaccion.
--
--  LAS TRES COSAS QUE SI PONE AQUI, dichas en voz alta:
--
--    1. UNA REGLA SOLO PUEDE SER DE UN CABALLO DE ESTA CARRERA. La columna
--       `horse_id` tiene clave foranea contra `horses`, pero nada la ataba al
--       remate: hoy se puede escribir una regla que apunte a un caballo de
--       OTRA carrera, y lo unico que lo impide es que el frontend no lo hace.
--       Como esta funcion va a ser LA puerta -- abajo se revoca el acceso
--       directo a la tabla -- dejarla sin esa comprobacion seria abrir yo el
--       agujero que vengo a cerrar.
--    2. UN CANDADO POR REMATE. Sin el, dos admins guardando a la vez se
--       interleavan: A borra, B espera, A inserta, B borra lo de A e inserta
--       lo suyo... o peor, quedan las dos escaleras mezcladas. No es una regla
--       de negocio, es que la operacion que estoy creando sea correcta.
--       Espacio 2 con la clave del remate, igual que `editar_remate`.
--    3. ASIENTO EN LA BITACORA. Las escrituras directas no dejaban ninguno:
--       cambiar todas las escaleras de un remate con dinero comprometido no
--       aparecia en `/admin/log`. No es una regla nueva, es la auditoria que
--       la via directa no podia dejar.
--
--  LO QUE SIGUE FALTANDO, apuntado para que no se descubra por sorpresa:
--  cambiar una escalera NO emite senal de realtime. No hay ningun trigger
--  sobre `remate_price_rules`, asi que las pantallas abiertas siguen
--  ensenando el minimo viejo hasta que alguien recargue. Es anterior a esta
--  migracion y no se arregla aqui.
--
--  FORMA DEL PAYLOAD
--
--    p_reglas = [ { horse_id, min_precio, max_precio, incremento } ]
--
--  Vacio ('[]') significa "este remate se queda sin escaleras", que es una
--  orden legitima: todos los caballos pasan a usar el incremento del remate.
-- ===========================================================================

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
  v_regla    jsonb;
  v_horse    uuid;
  v_antes    integer;
  v_escritas integer := 0;
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

  -- Candado por remate. Ver el punto 2 de la cabecera.
  perform pg_advisory_xact_lock(2, hashtext(p_remate_id::text));

  select r.race_id into v_race_id
  from public.remates r
  where r.id = p_remate_id;

  if v_race_id is null then
    raise exception 'Remate no existe';
  end if;

  select count(*) into v_antes
  from public.remate_price_rules rp
  where rp.remate_id = p_remate_id;

  delete from public.remate_price_rules rp
  where rp.remate_id = p_remate_id;

  for v_regla in select value from jsonb_array_elements(p_reglas)
  loop
    v_horse := (v_regla->>'horse_id')::uuid;

    -- Punto 1 de la cabecera: el caballo tiene que ser de ESTA carrera.
    if not exists (
      select 1 from public.horses h
      where h.id = v_horse and h.race_id = v_race_id
    ) then
      raise exception 'Esa escalera no es de un caballo de esta carrera';
    end if;

    insert into public.remate_price_rules (
      remate_id, horse_id, min_precio, max_precio, incremento
    )
    values (
      p_remate_id,
      v_horse,
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
    jsonb_build_object(
      'remate_id', p_remate_id,
      'tramos_antes', v_antes,
      'tramos_ahora', v_escritas
    )
  );

  return v_escritas;
end
$fn$;

comment on function public.guardar_escaleras(uuid, jsonb) is
  'Reemplaza TODAS las escaleras de un remate en UNA transaccion. Antes eran un delete y un insert sueltos, y entre los dos el remate se quedaba sin escaleras (07/10/2026).';

revoke all on function public.guardar_escaleras(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.guardar_escaleras(uuid, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------------
--  Y SE CIERRA LA PUERTA DE ATRAS.
--
--  `remate_price_rules` tenia insert, update y delete para `authenticated`
--  porque la pantalla de admin los usaba. Ya no: crear pasa por
--  crear_remate_completo() y editar por guardar_escaleras(), las dos SECURITY
--  DEFINER. Nadie mas escribe esta tabla directo -- comprobado recorriendo
--  `app/` y `lib/` el 07/10.
--
--  Es la primera de las cuatro tablas del catalogo que baja a solo lectura.
--  Las otras tres (`races`, `horses`, `support_settings`) siguen abiertas
--  porque la pantalla de editar todavia las escribe.
--
--  `select` se conserva para los dos roles: la pantalla de editar lee las
--  escaleras para pintarlas.
-- ---------------------------------------------------------------------------
revoke insert, update, delete, truncate on public.remate_price_rules from authenticated;
revoke insert, update, delete, truncate on public.remate_price_rules from anon;
grant select on public.remate_price_rules to authenticated, anon;
