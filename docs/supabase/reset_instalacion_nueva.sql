-- -----------------------------------------------------------------------------
--  reset_instalacion_nueva.sql
--
--  QUE HACE
--
--  Deja una instalacion como recien entregada: sin usuarios, sin dinero, sin
--  remates, sin marca y sin correo fundador. El esquema NO se toca: tablas,
--  funciones, policies y permisos quedan como estan, para que el siguiente
--  licenciatario se registre, entre por /admin/login y funde la casa.
--
--  PARA QUE
--
--  Reutilizar un proyecto de Supabase que ya se uso (pruebas, una entrega que
--  se cayo, un correo fundador equivocado) sin crear otro proyecto y volver a
--  empujar todas las migraciones. Para un cliente nuevo de verdad lo correcto
--  sigue siendo un proyecto nuevo: docs/supabase/INSTALACION_LICENCIATARIO.md.
--
--  EN QUE PROYECTO SE CORRE, Y ESTO NO LO PUEDE COMPROBAR EL SCRIPT
--
--  En el de la INSTALACION que se quiere resetear. El SQL Editor ejecuta
--  contra el proyecto que tengas abierto en el panel de Supabase, y no hay
--  forma de saber desde el SQL cual es. Antes de darle a Run, mira el nombre
--  del proyecto: si es el de produccion (el que tiene el dinero de gente
--  real), CIERRA ESTA PESTANA. Esa base no se resetea nunca.
--
--  POR QUE NO SE BORRAN LAS TABLAS NI SE CREA UN PROYECTO VACIO
--
--  Porque las migraciones son la fuente de verdad (ADR-002) y el esquema de
--  esta instalacion ya esta aplicado: borrar y volver a empujar solo agrega
--  formas de dejarla a medias. Lo que se borra son los DATOS.
--
--  QUE NO SE TOCA, Y POR QUE
--
--    - supabase_migrations.schema_migrations. Es el historial de migraciones.
--      Si se borra, `db push` cree que no hay ninguna aplicada y las vuelve a
--      correr contra un esquema que ya las tiene.
--    - Las CLAVES de ajustes_instalacion. Las crean las migraciones y
--      `ajuste_numero()` revienta si desaparecen (un minimo ausente seria un
--      minimo de cero). Lo que se vacia son los VALORES.
--    - motivos_rechazo. Sus codigos los usa la pantalla de rechazo de recargas
--      y retiros; sin ellos no se puede rechazar nada.
--    - Las variables de entorno (SMTP, APP_URL, NEXT_PUBLIC_*): no viven en la
--      base, viven en Vercel. Este script no las cambia.
--
--  LO QUE HAY QUE EDITAR ANTES DE CORRERLO
--
--  El bloque 0, y nada mas. Si se olvida, el script SE NIEGA a borrar: el
--  correo de ejemplo lo detiene.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
--  ANTES DE NADA: ESTE ES EL PROYECTO QUE CREES?
--
--  Selecciona SOLO estas cuatro lineas y ejecutalas, sin el resto del archivo:
--
--    select (select valor from public.ajustes_instalacion where clave = 'casa_nombre')       as casa,
--           (select valor from public.ajustes_instalacion where clave = 'correo_fundador')   as fundador,
--           (select count(*) from auth.users)                                                as usuarios,
--           (select coalesce(sum(saldo_disponible + saldo_bloqueado), 0) from public.wallets) as dinero;
--
--  Si `casa` es la casa de produccion y `dinero` no es 0, has abierto el
--  proyecto equivocado: este archivo no se corre ahi.
-- -----------------------------------------------------------------------------

begin;


-- -----------------------------------------------------------------------------
--  0. LO UNICO QUE SE EDITA
--
--  correo_fundador
--    El correo del licenciatario, tal como se va a registrar en /register. Es
--    el segundo candado de `fundar_super_admin`: si no coincide, la casa no se
--    puede fundar y hay que volver a entrar aqui. Se compara sin mayusculas y
--    sin espacios, asi que da igual como lo escriba despues.
--
--  dinero_de_prueba
--    El script se niega a borrar carteras con saldo. Si el dinero que hay es
--    de tus pruebas y de verdad se quiere ir, pon 'si'. Si es de gente real,
--    no toques esto: este script no es lo que buscas.
--
--  Los tres numeros
--    Vuelven a los valores con los que nace una instalacion (seccion 6 de
--    INSTALACION_LICENCIATARIO.md). Se cambian desde aqui y no desde el panel
--    porque la base valida contra ellos (ADR-047).
-- -----------------------------------------------------------------------------
drop table if exists pg_temp._reset_cfg;
create temporary table _reset_cfg on commit drop as
select
  'CAMBIAME@ejemplo.com'::text as correo_fundador,
  'no'::text                   as dinero_de_prueba,
  '50'::text                   as minimo_incremento,
  '100'::text                  as minimo_precio_salida,
  '50'::text                   as pct_apostado_para_retirar;


-- -----------------------------------------------------------------------------
--  1. LAS GUARDAS
--
--  Las tres abortan antes de borrar una sola fila, y como todo va en una
--  transaccion, un aborto deja la instalacion exactamente como estaba.
-- -----------------------------------------------------------------------------
do $$
declare
  v_correo   text;
  v_flag     text;
  v_dinero   numeric;
  v_usuarios integer;
  v_faltan   text;
begin
  -- Si alguien corre solo el bloque de guardas -- porque selecciono un trozo,
  -- o porque el editor ejecuta desde el cursor -- el error nativo es
  -- `relation "_reset_cfg" does not exist`, que no explica nada. Este si: la
  -- tabla es TEMPORAL y nace y muere con esta transaccion, asi que el bloque 0
  -- tiene que ir en la misma corrida que el resto.
  if to_regclass('pg_temp._reset_cfg') is null then
    raise exception 'No existe _reset_cfg: falta el bloque 0. Corre el archivo COMPLETO (Ctrl+A y Run), no solo una parte: la tabla de configuracion es temporal y solo vive dentro de esta transaccion.';
  end if;

  select correo_fundador, dinero_de_prueba
    into v_correo, v_flag
  from _reset_cfg;

  -- (a) Sin correo valido, el reset dejaria una casa que NADIE puede fundar:
  --     el candado 2 de fundar_super_admin exige un correo designado.
  if coalesce(btrim(v_correo), '') in ('', 'CAMBIAME@ejemplo.com')
     or v_correo !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'Edita _reset_cfg (bloque 0) con el correo del licenciatario. Recibido: "%".', v_correo;
  end if;

  -- (b) Si falta una clave de ajustes, esta instalacion no esta al dia con las
  --     migraciones. Resetearla asi la dejaria con pantallas que revientan, y
  --     el que se entera es el licenciatario.
  select string_agg(k.clave, ', ' order by k.clave)
    into v_faltan
  from (values
    ('minimo_incremento'), ('minimo_precio_salida'), ('pct_apostado_para_retirar'),
    ('correo_fundador'), ('casa_nombre'), ('casa_logo_url'), ('pago_titular'),
    ('pago_documento'), ('pago_movil_banco'), ('pago_movil_telefono'),
    ('pago_transf_banco'), ('pago_transf_tipo'), ('pago_transf_numero')
  ) as k(clave)
  where not exists (
    select 1 from public.ajustes_instalacion a where a.clave = k.clave
  );

  if v_faltan is not null then
    raise exception 'Faltan ajustes de instalacion (%). No estan aplicadas todas las migraciones: enlaza ESTE proyecto y corre pnpm db:push:produccion antes de resetear.', v_faltan;
  end if;

  -- (c) La guarda del dinero. No distingue prueba de real -- eso lo sabe quien
  --     lo metio -- asi que exige que se diga a proposito.
  select coalesce(sum(w.saldo_disponible + w.saldo_bloqueado), 0)
    into v_dinero
  from public.wallets w;

  if v_dinero <> 0 and v_flag <> 'si' then
    raise exception 'Hay % en carteras. Si ese dinero es de prueba, pon dinero_de_prueba = ''si'' en _reset_cfg. Si es de gente real, para aqui.', v_dinero;
  end if;

  select count(*) into v_usuarios from auth.users;

  raise notice 'Se van a borrar % usuarios y % en carteras. correo_fundador quedara en "%".', v_usuarios, v_dinero, v_correo;
end $$;


-- -----------------------------------------------------------------------------
--  2. LOS DATOS
--
--  TRUNCATE y no DELETE: es una sola operacion, no dispara triggers, reinicia
--  las secuencias (los numeros de caballo vuelven a empezar) y CASCADE se lleva
--  cualquier tabla que en el futuro apunte a estas.
--
--  `profiles` va aqui a proposito: los perfiles se van con sus duenos. Dejarlos
--  seria entregarle al licenciatario nuevo la lista de usuarios del anterior.
--
--  `admin_actions` tambien: es la bitacora de la casa anterior. Es de quien
--  operaba esa casa, no de la siguiente.
-- -----------------------------------------------------------------------------
truncate table
  public.aceptaciones_legales,
  public.admin_actions,
  public.bids,
  public.deposit_requests,
  public.documentos_legales,
  public.horses,
  public.house_ledger,
  public.notificaciones,
  public.profiles,
  public.race_results,
  public.races,
  public.remate_avisos,
  public.remate_price_rules,
  public.remates,
  public.support_settings,
  public.wallet_movements,
  public.wallets,
  public.withdraw_requests
restart identity cascade;


-- -----------------------------------------------------------------------------
--  3. LOS AJUSTES
--
--  Los nueve que pone el dueno nacen vacios (ADR-047: una casa que arranca con
--  la cuenta de otro cobra para otro hasta que alguien se da cuenta).
-- -----------------------------------------------------------------------------
update public.ajustes_instalacion
   set valor = ''
 where clave in (
   'casa_nombre', 'casa_logo_url',
   'pago_titular', 'pago_documento',
   'pago_movil_banco', 'pago_movil_telefono',
   'pago_transf_banco', 'pago_transf_tipo', 'pago_transf_numero'
 );

update public.ajustes_instalacion a
   set valor = c.minimo_incremento
  from _reset_cfg c
 where a.clave = 'minimo_incremento';

update public.ajustes_instalacion a
   set valor = c.minimo_precio_salida
  from _reset_cfg c
 where a.clave = 'minimo_precio_salida';

update public.ajustes_instalacion a
   set valor = c.pct_apostado_para_retirar
  from _reset_cfg c
 where a.clave = 'pct_apostado_para_retirar';

update public.ajustes_instalacion a
   set valor = btrim(c.correo_fundador)
  from _reset_cfg c
 where a.clave = 'correo_fundador';


-- -----------------------------------------------------------------------------
--  4. EL LOGO
--
--  Los bytes del logo anterior se quedan huerfanos en el almacenamiento: sin su
--  fila en storage.objects no hay URL que los sirva, y no cuestan nada. La
--  proxima casa sube el suyo con nombre nuevo (ADR-050).
--
--  El storage de Supabase (v1.x) tiene un disparador que prohibe borrar filas
--  de storage.objects por SQL: "Use the Storage API instead". La variable de
--  abajo es la puerta que ese mismo disparador deja abierta, y se abre SOLO
--  para esta transaccion (tercer argumento true = local). En versiones viejas
--  de storage la variable no existe y el set_config no molesta a nadie.
-- -----------------------------------------------------------------------------
select set_config('storage.allow_delete_query', 'true', true);

delete from storage.objects where bucket_id = 'marca';

select set_config('storage.allow_delete_query', 'false', true);


-- -----------------------------------------------------------------------------
--  5. LOS USUARIOS DE AUTH
--
--  Van despues de `profiles` (que ya se trunco) y no antes: la cadena
--  auth.users -> profiles -> wallets -> wallet_movements tiene eslabones en
--  RESTRICT a proposito (ADR-013). Las identidades, sesiones y tokens caen por
--  CASCADE con el usuario.
-- -----------------------------------------------------------------------------
delete from auth.users;


-- -----------------------------------------------------------------------------
--  6. QUE NO QUEDE NADA, Y QUE SE SEPA SI ESTE SCRIPT SE QUEDO VIEJO
--
--  Recorre TODAS las tablas de public. Si una migracion futura trae una tabla
--  nueva y este script no la borra, esto aborta y la nombra. Un reset que deja
--  datos del cliente anterior en silencio es peor que uno que no corre.
-- -----------------------------------------------------------------------------
do $$
declare
  r        record;
  v_filas  bigint;
  v_sobran text := '';
begin
  for r in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relname not in ('ajustes_instalacion', 'motivos_rechazo')
    order by c.relname
  loop
    execute format('select count(*) from public.%I', r.relname) into v_filas;

    if v_filas > 0 then
      v_sobran := v_sobran || format('%s (%s filas) ', r.relname, v_filas);
    end if;
  end loop;

  if v_sobran <> '' then
    raise exception 'Quedaron datos en tablas que este script no conoce: %. Una migracion nueva trajo una tabla: anadela al TRUNCATE del bloque 2.', v_sobran;
  end if;
end $$;


-- -----------------------------------------------------------------------------
--  7. EL COMPROBANTE
--
--  Se lee antes del commit, y viaja con el. Si algo de esto no sale como se
--  espera, no se hace commit y la instalacion queda intacta.
-- -----------------------------------------------------------------------------
select 'usuarios en auth.users' as que,
       (select count(*)::text from auth.users) as valor
union all
select 'dinero en carteras',
       (select round(coalesce(sum(saldo_disponible + saldo_bloqueado), 0), 2)::text
          from public.wallets)
union all
select 'casa_fundada()',
       public.casa_fundada()::text
union all
select 'correo_fundador',
       (select valor from public.ajustes_instalacion where clave = 'correo_fundador')
union all
select 'nombre de la casa',
       coalesce(
         (select nullif(btrim(valor), '') from public.ajustes_instalacion where clave = 'casa_nombre'),
         '(vacio: se pinta la marca de la plataforma)')
union all
select 'minimos (incremento / salida / % retiro)',
       (select string_agg(valor, ' / ' order by clave)
          from public.ajustes_instalacion
         where clave in ('minimo_incremento', 'minimo_precio_salida', 'pct_apostado_para_retirar'))
union all
select 'documentos legales publicados',
       (select count(*)::text from public.documentos_legales where publicado_en is not null)
union all
select 'objetos del bucket marca',
       (select count(*)::text from storage.objects where bucket_id = 'marca')
union all
select 'motivos de rechazo (se conservan)',
       (select count(*)::text from public.motivos_rechazo)
union all
select 'claves de ajustes (se conservan)',
       (select count(*)::text from public.ajustes_instalacion);


commit;

-- -----------------------------------------------------------------------------
--  DESPUES DE CORRERLO
--
--  1. El licenciatario se registra en /register con el correo de _reset_cfg.
--     Si "Confirm email" esta activo en Authentication, tiene que abrir el
--     enlace del correo antes de entrar (y el SMTP tiene que estar bien
--     configurado, o el correo no llega: INSTALACION_LICENCIATARIO.md, 3.1).
--  2. Entra por /admin/login. Como casa_fundada() es false, la pantalla le
--     ofrece fundar: pone su codigo y su nombre y queda super admin.
--  3. Lo primero que tiene que hacer, ya dentro, es /admin/super/ajustes:
--     el nombre de su casa, su logo y sus datos de cobro. Mientras
--     `casa_nombre` este vacio el sitio pinta la marca de la plataforma
--     (lib/marca.ts: sin casa, se ensena PLATAFORMA.nombre), y mientras los
--     datos de cobro esten vacios sus jugadores no pueden recargar.
--  4. Los textos legales quedan sin publicar (esta instalacion no tenia
--     ninguno, o los del anterior). Hoy no hay pantalla que los publique: se
--     cargan como super admin con
--       select public.publicar_documento('terminos', 'Terminos y condiciones', '<texto>', true);
--     y lo mismo con 'privacidad' y 'aviso_legal'. No bloquean nada, pero una
--     casa entregada sin ellos no tiene nada que pedirle aceptar a nadie.
--
--  Si el proyecto se queda para otro cliente, cambia tambien en SU despliegue
--  de Vercel el NEXT_PUBLIC_SUPABASE_URL / ANON_KEY, el SMTP y el APP_URL.
--  Este script no toca nada de eso: no vive en la base.
-- -----------------------------------------------------------------------------
