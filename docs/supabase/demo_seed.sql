-- ============================================================================
--  demo_seed.sql  -  MONTAR UNA DEMO CREIBLE DE UN GOLPE
--
--  POR QUE EXISTE (10/10/2026)
--
--  Una instalacion recien creada esta VACIA, y una aplicacion vacia no ensena
--  nada: `/remates` sin remates, `/admin` con todo en cero y la bitacora en
--  blanco no es el producto, es un formulario. Lo que vende es una carrera con
--  sus caballos y sus escaleras, jugadores con saldo pujando encima, y el
--  panel de la casa ensenando numeros que CUADRAN.
--
--  ESTE GUION NO INVENTA DINERO, Y ESA ES SU REGLA PRINCIPAL
--
--  Seria mas corto poner `update wallets set saldo_disponible = 5000`. Y
--  arruinaria la demo: `casa_resumen()` calcula la caja desde
--  `deposit_requests` aprobadas, asi que ese saldo saldria de la nada y
--  `/admin/contabilidad` ensenaria un descuadre en la primera pantalla que se
--  abre. El argumento de venta de esta aplicacion es que las cuentas cuadran;
--  un seed que las descuadra se dispara en el pie.
--
--  Asi que el dinero entra POR LA PUERTA: una solicitud de recarga del
--  jugador y un `aprobar_recarga()` del admin, igual que en la vida real. De
--  paso, la bitacora de `/admin/log` queda con contenido de verdad.
--
--  LOS JUGADORES TIENEN QUE EXISTIR ANTES
--
--  Este guion NO crea cuentas. Las cuentas se crean en `/register`, como
--  cualquier jugador, porque si las inventara aqui no podrias INICIAR SESION
--  con ellas para ensenar la mitad de jugador de la aplicacion.
--
--  Los busca por correo y ABORTA diciendo cual falta. No se inventan `id` a
--  mano -- misma regla que el paso 5 de INSTALACION_LICENCIATARIO.md.
--
--  SOLO PARA UNA INSTALACION DE DEMO
--
--  Hay una guarda al principio: si ya hay remates o recargas aprobadas, el
--  guion se niega a correr. Una instalacion que ya opero no es una demo, y
--  este guion mueve dinero.
--
--  COMO SE USA
--
--    1. Registra en `/register` el correo del admin y los tres jugadores.
--    2. Funda el super admin (paso 5 de INSTALACION_LICENCIATARIO.md).
--    3. Cambia los cuatro correos de aqui abajo.
--    4. Pegalo entero en el SQL Editor del proyecto de la DEMO.
--
--  DEJA MONTADO, medido tras correrlo contra una base limpia:
--
--    3 remates    (uno abierto en vivo, uno adelantado, uno ya liquidado)
--    14 caballos  (escalera propia en dos de ellos, 3 tramos en total)
--    11 pujas     repartidas, con lideres y con historial de subidas
--    3 jugadores  con 8.000 / 6.000 / 4.000 Bs entrados por la puerta
--
--  Y la contabilidad asi:
--
--    caja 18.000 · se debe 17.700 · patrimonio 300 · descuadre 0,00 · cubierto
--
--  Esos 300 son EXACTAMENTE la comision del remate liquidado. Si al abrir
--  /admin/contabilidad te sale otra cosa, o aparece franja de descuadre, el
--  defecto es de este guion: no ensenes la demo y avisa.
--
--  NOTA SOBRE LA REGLA DEL 50%. La instalacion arranca con
--  `pct_apostado_para_retirar = 50`, asi que los jugadores no pueden retirar
--  todo lo que recargaron hasta haber apostado la mitad. Es a proposito: la
--  pantalla de retirar lo explica, y es una de las cosas que conviene ensenar.
-- ============================================================================

begin;

do $demo$
declare
  -- ------------------------------------------------------------------ CAMBIA
  -- Los cuatro correos, tal como se registraron.
  c_admin    text := 'duenio@ejemplo.com';
  c_jugador1 text := 'jugador1@ejemplo.com';
  c_jugador2 text := 'jugador2@ejemplo.com';
  c_jugador3 text := 'jugador3@ejemplo.com';
  -- ---------------------------------------------------------------------------

  v_admin uuid; v_j1 uuid; v_j2 uuid; v_j3 uuid;
  v_faltan text := '';
  v_es_super boolean;
  v_remates int; v_recargas int;

  v_vivo uuid; v_vivo_race uuid;
  v_ade uuid;
  v_liq uuid; v_liq_race uuid;

  v_dep uuid;
  v_h record;
  v_msg text;

begin
  -- ---------------------------------------------------------------- guardas
  select count(*) into v_remates  from public.remates;
  select count(*) into v_recargas from public.deposit_requests where estado = 'aprobado';

  if v_remates > 0 or v_recargas > 0 then
    raise exception
      'Esta instalacion YA OPERO (% remates, % recargas aprobadas). Este guion es solo para una demo recien instalada y mueve dinero: no se corre encima de datos que ya existen.',
      v_remates, v_recargas;
  end if;

  -- ------------------------------------------------------------------ gente
  select id into v_admin from auth.users where email = c_admin;
  select id into v_j1    from auth.users where email = c_jugador1;
  select id into v_j2    from auth.users where email = c_jugador2;
  select id into v_j3    from auth.users where email = c_jugador3;

  if v_admin is null then v_faltan := v_faltan || ' ' || c_admin;    end if;
  if v_j1    is null then v_faltan := v_faltan || ' ' || c_jugador1; end if;
  if v_j2    is null then v_faltan := v_faltan || ' ' || c_jugador2; end if;
  if v_j3    is null then v_faltan := v_faltan || ' ' || c_jugador3; end if;

  if v_faltan <> '' then
    raise exception
      'Estas cuentas no estan registradas:%. Registralas en /register antes de correr esto. No se inventan ids a mano.',
      v_faltan;
  end if;

  select (coalesce(es_admin,false) and coalesce(es_super_admin,false))
    into v_es_super from public.profiles where id = v_admin;

  if not coalesce(v_es_super, false) then
    raise exception
      'La cuenta % todavia no es super admin. Funda el super admin primero (paso 5 de INSTALACION_LICENCIATARIO.md): sin eso, crear remates desde aqui no refleja lo que hara el cliente.',
      c_admin;
  end if;

  -- ------------------------------------------------------------- las caras
  -- Nombres visibles, para que la demo no ensene correos.
  update public.profiles set username = 'Carlos M.'  where id = v_j1 and (username is null or username = '');
  update public.profiles set username = 'Andrea R.'  where id = v_j2 and (username is null or username = '');
  update public.profiles set username = 'Luis P.'    where id = v_j3 and (username is null or username = '');

  -- ------------------------------------------------------------- el dinero
  -- Por la puerta: el jugador pide, el admin aprueba. Tres recargas, tres
  -- asientos en la bitacora, y la caja de la casa sube de verdad.
  foreach v_msg in array array[v_j1::text, v_j2::text, v_j3::text]
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_msg)::text, false);

    insert into public.deposit_requests
      (user_id, monto, metodo, telefono_pago, referencia, fecha_pago, estado)
    values
      (v_msg::uuid,
       case v_msg when v_j1::text then 8000 when v_j2::text then 6000 else 4000 end,
       'pago_movil', '04121234567', 'DEMO-' || left(v_msg, 8), current_date, 'pendiente')
    returning id into v_dep;

    perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, false);
    perform public.aprobar_recarga(v_dep);
  end loop;

  -- A partir de aqui manda la casa.
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, false);

  -- ------------------------------------------------- 1) EL REMATE EN VIVO
  -- Seis caballos, dos con escalera propia. Es el que se abre para ensenar la
  -- pantalla de pujar: queda ABIERTO y sin hora de cierre.
  select c.id_remate, c.id_carrera into v_vivo, v_vivo_race
  from public.crear_remate_completo(
    jsonb_build_object(
      'nombre','Clasico Simon Bolivar',
      'hipodromo','La Rinconada',
      'numero_carrera', 5,
      'numero_carrera_text','5',
      'fecha', current_date::text,
      'dia', 'Domingo',
      'distancia_m', 1600),
    jsonb_build_object(
      'nombre','Clasico Simon Bolivar - Carrera 5',
      'incremento_minimo', 50,
      'porcentaje_casa', 25,
      'tipo','vivo'),
    jsonb_build_array(
      jsonb_build_object('numero',1,'nombre','Relampago del Sur','jinete','J. Hernandez','precio_salida',500,
        'reglas', jsonb_build_array(
          jsonb_build_object('min_precio',500,'max_precio',1500,'incremento',50),
          jsonb_build_object('min_precio',1500,'max_precio',null,'incremento',100))),
      jsonb_build_object('numero',2,'nombre','Dama de Hierro','jinete','R. Blanco','precio_salida',400),
      jsonb_build_object('numero',3,'nombre','Viento Llanero','jinete','A. Castillo','precio_salida',350,
        'reglas', jsonb_build_array(
          jsonb_build_object('min_precio',350,'max_precio',null,'incremento',75))),
      jsonb_build_object('numero',4,'nombre','Centella','jinete','M. Peraza','precio_salida',300),
      jsonb_build_object('numero',5,'nombre','Tambor Mayor','jinete','L. Goncalves','precio_salida',250),
      jsonb_build_object('numero',6,'nombre','Caracas Star','jinete','E. Mendoza','precio_salida',200)
    ),
    'demo-seed-vivo') c;

  -- ------------------------------------------------------- 2) ADELANTADO
  -- Cuatro caballos, para que la lista no tenga una sola tarjeta y se vea la
  -- separacion "En vivo" / "Adelantados".
  select c.id_remate into v_ade
  from public.crear_remate_completo(
    jsonb_build_object(
      'nombre','Handicap Nacional',
      'hipodromo','Valencia',
      'numero_carrera', 3,
      'numero_carrera_text','3',
      'fecha', (current_date + 7)::text,
      'dia','Sabado',
      'distancia_m', 1400),
    jsonb_build_object(
      'nombre','Handicap Nacional - Carrera 3',
      'incremento_minimo', 50,
      'porcentaje_casa', 25,
      'tipo','adelantado'),
    jsonb_build_array(
      jsonb_build_object('numero',1,'nombre','Sol de Oriente','jinete','P. Rivas','precio_salida',300),
      jsonb_build_object('numero',2,'nombre','Alma Guaira','jinete','C. Sanz','precio_salida',250),
      jsonb_build_object('numero',3,'nombre','Rey Zamorano','jinete','D. Ortega','precio_salida',250),
      jsonb_build_object('numero',4,'nombre','Brisa de Abril','jinete','N. Falcon','precio_salida',200)
    ),
    'demo-seed-adelantado') c;

  -- ------------------------------------------------- 3) EL YA LIQUIDADO
  -- Este es el que hace que la contabilidad tenga algo que ensenar. Sin un
  -- remate liquidado, `/admin/contabilidad` sale en cero y el argumento de
  -- "las cuentas cuadran" no se puede demostrar: no hay cuentas.
  select c.id_remate, c.id_carrera into v_liq, v_liq_race
  from public.crear_remate_completo(
    jsonb_build_object(
      'nombre','Premio Aniversario',
      'hipodromo','La Rinconada',
      'numero_carrera', 8,
      'numero_carrera_text','8',
      'fecha', (current_date - 7)::text,
      'dia','Domingo',
      'distancia_m', 1800),
    jsonb_build_object(
      'nombre','Premio Aniversario - Carrera 8',
      'incremento_minimo', 50,
      'porcentaje_casa', 25,
      'tipo','vivo'),
    jsonb_build_array(
      jsonb_build_object('numero',1,'nombre','Potro Negro','jinete','J. Hernandez','precio_salida',300),
      jsonb_build_object('numero',2,'nombre','Luna Clara','jinete','R. Blanco','precio_salida',300),
      jsonb_build_object('numero',3,'nombre','El Catire','jinete','A. Castillo','precio_salida',300),
      jsonb_build_object('numero',4,'nombre','Tormenta','jinete','M. Peraza','precio_salida',300)
    ),
    'demo-seed-liquidado') c;

  -- ---------------------------------------------------------------- pujas
  -- En el remate EN VIVO: tres jugadores, cuatro caballos, un lider por
  -- caballo y una subida encima para que se vea el historial.
  for v_h in
    select h.id, h.numero from public.horses h where h.race_id = v_vivo_race order by h.numero
  loop
    if v_h.numero = 1 then
      perform set_config('request.jwt.claims', json_build_object('sub', v_j1)::text, false);
      perform public.hacer_puja(v_vivo, v_h.id, 500);
      perform set_config('request.jwt.claims', json_build_object('sub', v_j2)::text, false);
      perform public.hacer_puja(v_vivo, v_h.id, 550);
      -- Y el primero recupera el liderato. Tres pujas sobre el caballo que
      -- lleva escalera: es el que se abre para ensenar el aviso de incremento,
      -- y conviene que tenga historial, no una puja suelta.
      perform set_config('request.jwt.claims', json_build_object('sub', v_j1)::text, false);
      perform public.hacer_puja(v_vivo, v_h.id, 600);
    elsif v_h.numero = 2 then
      perform set_config('request.jwt.claims', json_build_object('sub', v_j3)::text, false);
      perform public.hacer_puja(v_vivo, v_h.id, 400);
    elsif v_h.numero = 3 then
      perform set_config('request.jwt.claims', json_build_object('sub', v_j1)::text, false);
      perform public.hacer_puja(v_vivo, v_h.id, 350);
      perform set_config('request.jwt.claims', json_build_object('sub', v_j3)::text, false);
      perform public.hacer_puja(v_vivo, v_h.id, 425);
    elsif v_h.numero = 5 then
      perform set_config('request.jwt.claims', json_build_object('sub', v_j2)::text, false);
      perform public.hacer_puja(v_vivo, v_h.id, 250);
    end if;
  end loop;

  -- En el que se va a liquidar: los cuatro caballos pujados, para que el pozo
  -- sea real y la comision de la casa tambien.
  for v_h in
    select h.id, h.numero from public.horses h where h.race_id = v_liq_race order by h.numero
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', case v_h.numero when 1 then v_j1 when 2 then v_j2 when 3 then v_j3 else v_j1 end)::text,
      false);
    perform public.hacer_puja(v_liq, v_h.id, 300 + (v_h.numero * 50));
  end loop;

  -- ------------------------------------------------- cerrar y liquidar
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, false);
  perform public.cerrar_remate(v_liq);
  perform public.set_ganador_carrera(v_liq, 3);   -- gana "El Catire", del jugador 3
  perform public.liquidar_remate(v_liq);

  -- ------------------------------------------------------------- limpieza
  -- La sesion deja de hacerse pasar por nadie. Sin esto, cualquier consulta
  -- que se corra despues en el mismo editor seguiria actuando como el admin.
  perform set_config('request.jwt.claims', '', false);

  raise notice '--------------------------------------------------------';
  raise notice 'DEMO MONTADA';
  raise notice '  remate en vivo    : %', v_vivo;
  raise notice '  remate adelantado : %', v_ade;
  raise notice '  remate liquidado  : %', v_liq;
  raise notice '  jugadores         : Carlos M. (8000), Andrea R. (6000), Luis P. (4000)';
  raise notice '--------------------------------------------------------';
  raise notice 'Comprueba en /admin/contabilidad que NO hay descuadre.';
  raise notice 'Si lo hay, este guion tiene un defecto: no lo ensenes, avisa.';
end
$demo$;

commit;
