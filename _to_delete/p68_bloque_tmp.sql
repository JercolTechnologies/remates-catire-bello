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
