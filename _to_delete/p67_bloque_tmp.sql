

-- ============================================================================
--  P67 - Crear un remate es atomico: o entra todo, o no entra nada
--
--  EL DEFECTO QUE REPRODUCE. Hasta el 07/10 crear un remate eran cinco
--  llamadas sueltas desde el navegador. Medido: con el admin repitiendo el
--  numero 5, quedaba una carrera huerfana, un remate 'abierto' con CERO
--  caballos, y una senal ya emitida a remates:lista -- o sea, el remate roto
--  empujado a la pantalla de todos los jugadores conectados (ADR-031).
--
--  Esa via vieja no se puede reproducir dentro de un `do $$`, porque un bloque
--  es UNA transaccion y lo que fallaba era tener cinco. La medicion quedo en la
--  cabecera de la migracion 20261007130000. Lo que esta prueba verifica es la
--  via nueva: que ningun rechazo deje nada escrito.
--
--  LO QUE MIDE
--   1. el camino bueno escribe las cuatro tablas y emite UNA senal
--   2. un fallo EN EL PASO DE LAS REGLAS (criterio de aceptacion del pendiente
--      1.1) no deja ni carrera, ni remate, ni caballos, ni senal
--   3. numeros repetidos: rechaza con P0001 -- nuestro mensaje, no el 23505 en
--      crudo -- y tampoco deja nada
--   4. sin caballos: rechaza
--   5. un jugador no puede llamarla
--
--  REGLA DEL 28/09: cuando el exito es "salto una excepcion", se comprueba
--  CUAL. P0001 es nuestro codigo rechazando a proposito; 42883 seria que la
--  migracion no esta aplicada y la prueba no estaria probando nada.
-- ============================================================================
do $$
declare
  v_admin uuid; v_juan uuid;
  v_existe boolean;
  v_race uuid; v_remate uuid; v_cab int; v_reg int;

  v_carrera jsonb; v_remate_j jsonb;

  v_sqlstate text; v_msg text;

  v_bueno_ok boolean := false;
  v_senal_buena int;
  v_reglas_falla_ok boolean := false;
  v_repetido_ok boolean := false;
  v_sin_caballos_ok boolean := false;
  v_jugador_ok boolean := false;
  v_basura int;
  v_senal_mala int;
  v_en_bitacora boolean := false;
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
        v_race is not null
    and v_remate is not null
    and v_cab = 2
    and v_reg = 2
    and (select count(*) from public.horses h where h.race_id = v_race) = 2
    and (select count(*) from public.remate_price_rules r where r.remate_id = v_remate) = 2
    -- la escalera cuelga del caballo correcto, no del primero que pillo
    and (select count(*) from public.remate_price_rules r
           join public.horses h on h.id = r.horse_id
          where r.remate_id = v_remate and h.numero = 1) = 2
    and v_senal_buena = 1;

  select exists (
    select 1 from public.admin_actions a
    where a.action = 'crear_remate_completo' and a.target_id = v_remate::text
  ) into v_en_bitacora;

  -- --------------------------------- 2) falla el paso de las reglas
  -- El criterio de aceptacion del pendiente 1.1, textual. El incremento 10 esta
  -- por debajo del minimo de la instalacion (50), asi que lo rebota
  -- trg_minimo_incremento_regla -- DESPUES de haber escrito carrera, remate y
  -- los dos caballos.
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
    v_msg := 'NO REBOTO';
  exception when others then
    v_sqlstate := sqlstate; v_msg := sqlerrm;
  end;

  select (select count(*) from public.races)
       + (select count(*) from public.remates)
       + (select count(*) from public.horses)
       + (select count(*) from public.remate_price_rules)
    into v_basura;
  select count(*) into v_senal_mala from realtime.messages where topic = 'remates:lista';

  v_reglas_falla_ok := v_sqlstate = 'P0001' and v_basura = 0 and v_senal_mala = 0;

  -- ------------------------------------------- 3) numeros repetidos
  perform _p.limpiar();
  delete from realtime.messages;
  v_admin := _p.usuario('jefa', 0, true);
  perform _p.actuar_como(v_admin);

  v_sqlstate := null; v_msg := null;
  begin
    perform public.crear_remate_completo(
      v_carrera, v_remate_j,
      jsonb_build_array(
        jsonb_build_object('numero', 5, 'nombre', 'Uno', 'jinete', 'A', 'precio_salida', 100),
        jsonb_build_object('numero', 5, 'nombre', 'Dos', 'jinete', 'B', 'precio_salida', 100)
      )
    );
    v_msg := 'NO REBOTO';
  exception when others then
    v_sqlstate := sqlstate; v_msg := sqlerrm;
  end;

  select (select count(*) from public.races) + (select count(*) from public.remates)
       + (select count(*) from public.horses)
    into v_basura;

  -- P0001 y no 23505: la traduccion funciona y el admin lee una frase.
  v_repetido_ok := v_sqlstate = 'P0001' and v_msg like '%repetido%' and v_basura = 0;

  -- --------------------------------------------- 4) ningun caballo
  v_sqlstate := null;
  begin
    perform public.crear_remate_completo(v_carrera, v_remate_j, '[]'::jsonb);
  exception when others then
    v_sqlstate := sqlstate;
  end;
  v_sin_caballos_ok := v_sqlstate = 'P0001'
    and (select count(*) from public.races) = 0;

  -- ------------------------------------------- 5) un jugador no puede
  perform _p.actuar_como(v_juan);
  v_sqlstate := null;
  begin
    perform public.crear_remate_completo(
      v_carrera, v_remate_j,
      jsonb_build_array(jsonb_build_object('numero', 1, 'nombre', 'X', 'jinete', 'Y', 'precio_salida', 100)));
  exception when others then
    v_sqlstate := sqlstate;
  end;
  v_jugador_ok := v_sqlstate = 'P0001' and (select count(*) from public.races) = 0;

  perform _p.anotar(67, 'Crear un remate es atomico',
    'el camino bueno escribe las cuatro tablas y emite una senal; un fallo en las reglas, un numero repetido, cero caballos o un jugador rechazan sin dejar nada',
    v_bueno_ok and v_en_bitacora and v_reglas_falla_ok and v_repetido_ok
      and v_sin_caballos_ok and v_jugador_ok,
    format('bueno=%s (caballos=%s reglas=%s senal=%s) bitacora=%s | falla_en_reglas=%s (basura=%s senal=%s) | repetido=%s | sin_caballos=%s | jugador=%s | mensaje del repetido: %s',
      v_bueno_ok, v_cab, v_reg, v_senal_buena, v_en_bitacora,
      v_reglas_falla_ok, v_basura, v_senal_mala,
      v_repetido_ok, v_sin_caballos_ok, v_jugador_ok, coalesce(v_msg,'-')));
end $$;
