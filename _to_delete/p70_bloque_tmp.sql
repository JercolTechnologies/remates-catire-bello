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
