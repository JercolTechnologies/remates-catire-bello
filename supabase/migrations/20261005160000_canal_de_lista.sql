-- ===========================================================================
--  20261005160000_canal_de_lista.sql
--
--  UN REMATE NUEVO NO LE APARECIA A NADIE
--
--  Jota lo reporto el 01/10: "los remates nuevos no le aparecen a los clientes
--  a menos que actualice". La causa, localizada el 05/10 leyendo el trigger:
--
--      create trigger avisar_remate AFTER UPDATE on public.remates
--
--  Un alta es un INSERT. El trigger no se dispara, y punto.
--
--  Pero aunque se disparara tampoco serviria, y esto es lo que de verdad
--  importa: `avisar_remate` emite al canal `remate:<id>`, y NADIE puede estar
--  suscrito al canal de un remate que todavia no existe. No es un trigger mal
--  puesto: es que faltaba el canal.
--
--  Un canal por objeto sirve para seguir un objeto que ya tienes delante. Para
--  enterarte de que APARECIO uno nuevo hace falta un canal de la coleccion.
--
--  DOS TRIGGERS Y NO UNO, con una sola funcion detras.
--  La clausula WHEN de un trigger no puede mirar OLD en un INSERT ni consultar
--  TG_OP, asi que "siempre al insertar, y al actualizar solo si cambio algo
--  que se ve en la lista" no cabe en un disparador. Dos disparadores que
--  comparten funcion lo dicen exactamente y sin ruido: sin el WHEN, cada
--  `closed_at` o cada marca interna despertaria a todos los navegadores
--  conectados.
--
--  EL CANAL ES PUBLICO. La lista de remates abiertos la ve cualquiera, con
--  sesion o sin ella -- es la portada de la aplicacion. La senal no lleva mas
--  que un id y un estado, y lo que el cliente pueda LEER despues lo sigue
--  decidiendo la RLS de `remates`.
-- ===========================================================================

do $$
begin
  drop policy if exists lista_recibe_cualquiera on realtime.messages;

  create policy lista_recibe_cualquiera on realtime.messages
    for select to anon, authenticated
    using (
      realtime.messages.extension = 'broadcast'
      and realtime.topic() = 'remates:lista'
    );
exception when insufficient_privilege then
  raise exception
    'No se pueden crear politicas sobre realtime.messages con el rol %. Sin ella los remates nuevos se emiten y no los recibe nadie. Crea la politica a mano desde el SQL Editor con el contenido de este archivo.', current_user;
end $$;

create or replace function public.tr_avisar_lista() returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  perform public._avisar(
    'remates:lista',
    'lista',
    jsonb_build_object('remate_id', new.id, 'estado', new.estado));
  return null;
end $fn$;

comment on function public.tr_avisar_lista() is
  'Avisa al canal de la coleccion cuando aparece un remate o cambia algo que se ve en la lista. El canal por objeto (remate:<id>) no sirve para esto: nadie puede suscribirse a un remate que aun no existe.';

drop trigger if exists avisar_lista_alta on public.remates;
create trigger avisar_lista_alta after insert on public.remates
  for each row execute function public.tr_avisar_lista();

drop trigger if exists avisar_lista_cambio on public.remates;
create trigger avisar_lista_cambio after update on public.remates
  for each row
  when (
       new.estado       is distinct from old.estado
    or new.nombre       is distinct from old.nombre
    or new.opens_at     is distinct from old.opens_at
    or new.closes_at    is distinct from old.closes_at
    or new.archived_at  is distinct from old.archived_at
    or new.cancelled_at is distinct from old.cancelled_at
    or new.tipo         is distinct from old.tipo
  )
  execute function public.tr_avisar_lista();

revoke all on function public.tr_avisar_lista() from public, anon, authenticated;
