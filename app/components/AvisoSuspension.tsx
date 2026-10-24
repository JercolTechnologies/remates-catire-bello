// ===========================================================================
//  components/AvisoSuspension.tsx  -  "LICENCIA SUSPENDIDA"
//
//  QUE ES ESTO (24/10/2026, ADR-053)
//
//  La pantalla que ve todo el mundo cuando la licencia de la casa no esta
//  pagada: el dueno al intentar entrar a su panel, el cajero a media manana, y
//  el jugador que abria la web a pujar. No es un aviso encima de la aplicacion
//  -- es SUSTITUTO de la aplicacion. Ver `app/layout.tsx`.
//
//  POR QUE EN EL SERVIDOR Y SIN "use client"
//
//  Porque no hay nada que decidir en el navegador: si esta pantalla se pinta,
//  el bloqueo ya ocurrio. Un componente de cliente tendria que montar la sesion
//  de Supabase, el canal de remates y la marca de la casa para acabar tapandolo
//  todo, y con la base caida -- que es el caso en el que esto mas se usa --
//  montaria un esqueleto roto debajo.
//
//  POR QUE HABLA TAMBIEN AL JUGADOR
//
//  Porque es el que no debe nada y el que se queda mirando una puerta cerrada.
//  El bloqueo es contra el dueno, no contra su gente, y el que lee esto tiene
//  que saber dos cosas: que la plataforma no tiene su dinero, y que quien
//  responde por su saldo sigue siendo la casa. Sin ese parrafo, el jugador
//  asume que le estafamos nosotros.
//
//  NO NOMBRA A LA CASA A PROPOSITO. Para pintar su nombre hay que consultar
//  `ajustes_instalacion`, y esta pantalla tiene que salir aunque la base no
//  conteste. La marca de la plataforma es la unica que se puede afirmar sin
//  preguntarle a nadie.
// ===========================================================================

import Image from "next/image"
import { PLATAFORMA, enlaceContacto, pieDePagina } from "@/lib/marca"

export default function AvisoSuspension({ aviso }: { aviso: string }) {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-12">
      <Image
        src={PLATAFORMA.vertical}
        alt={PLATAFORMA.nombre}
        width={PLATAFORMA.tam.vertical.w}
        height={PLATAFORMA.tam.vertical.h}
        priority
        className="h-auto w-[180px] sm:w-[210px]"
      />

      <div className="mt-8 w-full max-w-xl rounded-2xl border border-red-500/30 bg-red-500/5 p-6 sm:p-8">
        <p className="text-xs font-semibold uppercase tracking-[0.2em] text-red-400">
          Servicio suspendido
        </p>
        <h1 className="mt-3 text-2xl font-bold tracking-tight text-zinc-100 sm:text-3xl">
          Licencia suspendida por falta de pago
        </h1>
        <p className="mt-4 text-sm leading-relaxed text-zinc-300">{aviso}</p>

        <div className="mt-6 space-y-2 border-t border-zinc-800 pt-4 text-xs leading-relaxed text-zinc-400">
          <p>
            <span className="font-semibold text-zinc-300">Si eres jugador:</span> la casa es
            quien recibe tus depósitos y responde por tu saldo. {PLATAFORMA.nombre} no
            administra tu dinero y no puede devolvértelo; escríbele a la casa.
          </p>
          <p>
            <span className="font-semibold text-zinc-300">Tus datos no se han borrado.</span>{" "}
            La suspensión cierra el acceso; no toca saldos, remates ni historial.
          </p>
        </div>

        <a
          href={enlaceContacto("licencia")}
          target="_blank"
          rel="noopener noreferrer"
          className="mt-6 inline-flex w-full items-center justify-center rounded-xl bg-zinc-100 px-4 py-3 text-sm font-semibold text-zinc-950 hover:bg-white sm:w-auto"
        >
          Contactar con los administradores de la plataforma
        </a>
      </div>

      <div className="mt-8 text-center text-xs text-zinc-500">{pieDePagina(null).principal}</div>
    </div>
  )
}
