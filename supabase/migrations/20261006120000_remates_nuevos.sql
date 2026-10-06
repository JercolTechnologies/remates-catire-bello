-- ===========================================================================
--  20261006120000_remates_nuevos.sql
--
--  Escrita el LUNES 5 DE OCTUBRE DE 2026, 23:12 hora de Caracas.
--  (El numero va en UTC, donde ya es dia 6. Es una clave de orden, no una
--  fecha: ver la nota del ADR-033.)
--
--  "NO AVISO EN LA CUENTA CLIENTE CUANDO LO CREE"
--
--  Jota, probando el modal de confirmacion. El remate aparecia solo en la lista
--  -- eso ya funciona desde el canal de la coleccion (ADR-031) -- pero no habia
--  ningun aviso.
--
--  LA DECISION, tomada con el: INDICADOR DISCRETO, NO POPUP.
--
--  El popup es para lo que te pasa A TI: ganaste un premio, te aprobaron la
--  recarga, te rechazaron un retiro. Un remate nuevo no es personal, es un
--  anuncio -- y los anuncios no interrumpen.
--
--  Pero el argumento que decide es el flujo real de Jota, dicho por el mismo el
--  01/10: "un admin deberia ponerse a crear todas las carreras del sabado y
--  domingo el martes noche". Con un popup por remate, eso son DOCE ventanas
--  seguidas. Y el jugador que aprende a cerrar ventanas sin leerlas cierra
--  tambien, sin leer, la que le dice que gano un premio. **Un aviso que se
--  dispara de mas destruye el valor de los que importan.**
--
--  COMO SE SABE QUE ES NUEVO: una marca por usuario, `remates_vistos_at`.
--  Todo remate abierto creado despues de esa marca es nuevo para el. Abrir la
--  lista mueve la marca a ahora.
--
--  Se eligio UNA MARCA y no una tabla `remates_vistos (user_id, remate_id)`.
--  La tabla seria mas fina -- sabria cuales abrio uno por uno -- a cambio de
--  una fila por jugador y por remate, para responder una pregunta que nadie
--  hace. Lo que el jugador quiere saber es "que hay desde la ultima vez que
--  mire", y eso es una fecha.
--
--  Y VA EN LA BASE, no en el navegador. `localStorage` habria salido gratis,
--  pero el jugador que mira en el telefono y luego en la computadora veria los
--  mismos remates marcados como nuevos otra vez. La marca es del usuario, no
--  del aparato.
-- ===========================================================================

--  LA MARCA NACE PUESTA, Y ESO NO ES UN DETALLE.
--
--  La primera version la dejaba nula para quien nunca habia mirado la lista, y
--  eso obligaba a elegir entre dos respuestas y las dos eran malas:
--
--    nulo = todo es nuevo  -> el jugador que entra por primera vez ve VEINTE
--                             etiquetas amarillas. Eso no es informacion, es
--                             ruido, y ensena a ignorar la etiqueta.
--    nulo = nada es nuevo  -> el que se registra y no abre la lista NUNCA
--                             recibe el aviso, justo el que habria que atraer.
--
--  Con `not null default now()` el caso no existe: cada usuario nace con una
--  marca en su momento de alta, lo de antes no le interesa y lo de despues le
--  aparece. Las filas que ya estan reciben la fecha de esta migracion, que es
--  exactamente lo que significa: "desde hoy te aviso".
alter table public.profiles
  add column if not exists remates_vistos_at timestamptz not null default now();

comment on column public.profiles.remates_vistos_at is
  'Ultima vez que el usuario miro la lista de remates. Todo remate abierto creado despues es "nuevo" para el. Nace puesta al dar de alta: nunca es nula, para que no haya que decidir que significa el nulo.';

-- ---------------------------------------------------------------------------
--  Que hay de nuevo
--
--  Devuelve las dos cosas en una sola llamada, y no es por ahorrar un viaje:
--  el contador y la marca ANTERIOR tienen que salir de la misma lectura. Si se
--  pidieran por separado, entre una y otra puede entrar un remate y la lista
--  pintaria como nuevo uno que el contador no conto.
-- ---------------------------------------------------------------------------
create or replace function public.remates_nuevos()
returns table (nuevos integer, vistos_desde timestamptz)
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_yo uuid := auth.uid();
  v_desde timestamptz;
begin
  if v_yo is null then
    -- Sin sesion no hay nada "nuevo": no hay contra que comparar. Se responde
    -- cero en vez de reventar, porque la barra de navegacion se pinta antes de
    -- saber si hay sesion.
    return query select 0, null::timestamptz;
    return;
  end if;


  select pr.remates_vistos_at into v_desde
  from public.profiles pr where pr.id = v_yo;

  return query
  select
    (select count(*)::integer
       from public.remates r
      where r.estado = 'abierto'
        and r.archived_at is null
        and (r.opens_at is null or r.opens_at <= now())
        and (r.closes_at is null or r.closes_at > now())
        and r.created_at > v_desde),
    v_desde;
end;
$fn$;

comment on function public.remates_nuevos() is
  'Cuantos remates abiertos aparecieron desde la ultima vez que este usuario miro la lista, y desde cuando. Las dos cifras salen de la misma lectura a proposito.';

-- ---------------------------------------------------------------------------
--  Mirar la lista
-- ---------------------------------------------------------------------------
create or replace function public.marcar_remates_vistos()
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_yo uuid := auth.uid();
begin
  if v_yo is null then
    return;
  end if;

  update public.profiles
     set remates_vistos_at = now()
   where id = v_yo;
end;
$fn$;

comment on function public.marcar_remates_vistos() is
  'Mueve a ahora la marca de "ya mire la lista" del usuario. Solo la suya: no recibe parametros a proposito.';

revoke all on function public.remates_nuevos()        from public, anon;
revoke all on function public.marcar_remates_vistos() from public, anon;
grant execute on function public.remates_nuevos()        to authenticated;
grant execute on function public.marcar_remates_vistos() to authenticated;
