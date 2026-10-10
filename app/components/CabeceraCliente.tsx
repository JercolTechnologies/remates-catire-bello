"use client"

// ===========================================================================
//  components/CabeceraCliente.tsx  -  LA CABECERA DEL JUGADOR
//
//  QUE ES Y DONDE SALE (09/10/2026)
//
//  Jota: "Nombre de usuario y saldo, arriba a la derecha (como en betplay por
//  ejemplo) y tiene que aparecerle en todas las pantallas, menos en la de su
//  dashboard (ahi ya sale nombre, ademas de saldos disponibles, en pujas etc)
//  ni en la de pujar en remate, basicamente por la misma razon".
//
//  Esa excepcion no es un capricho: en esas dos pantallas los tres saldos ya
//  estan en grande y a la vista. Repetir uno de ellos arriba no informa, y
//  ademas INVITA A LA DUDA -- dos cifras del mismo dinero en la misma pantalla
//  hacen que el jugador se pregunte cual es la buena.
//
//  LO QUE SE OCULTA ES EL BLOQUE DE USUARIO Y SALDO, NO LA CABECERA ENTERA.
//  Y hay un motivo duro: en escritorio el menu de navegacion VIVE en esta
//  cabecera (la barra inferior es solo de movil). Si la cabecera desapareciera
//  en el panel y en la pantalla de pujar, un jugador en un portatil se
//  quedaria en esas dos pantallas sin ninguna forma de salir -- justo el
//  problema de los "Volver" que estamos cerrando, reintroducido por la puerta
//  de atras.
//
//  QUE SALDO SE ENSENA, Y POR QUE ESE. `saldo_disponible`: lo que el jugador
//  TIENE. No `disponible_para_retirar`, que es mas pequeno por la regla del
//  50% y veria un numero menor que su dinero sin explicacion. Y no el
//  comprometido, que no es una tercera bolsa sino una parte de la primera.
//
//  En la pantalla de pujar, donde la diferencia entre "tienes" y "te queda
//  libre" SI importa para decidir, estan los tres numeros -- y por eso el
//  bloque de saldo no se pinta ahi.
//
//  ESTE COMPONENTE NO CONSULTA NADA. Lee del contexto de SesionCliente, que
//  es quien pregunta una sola vez para toda la aplicacion. Anadir aqui una
//  segunda consulta de lo mismo seria la tercera copia de la misma pregunta
//  en el arbol (ADR-026).
// ===========================================================================

import Image from "next/image"
import Link from "next/link"
import { usePathname } from "next/navigation"
import { PLATAFORMA, CASA } from "@/lib/marca"
import { ENLACES_CLIENTE } from "./enlacesCliente"
import { useSesionCliente } from "./SesionCliente"

// Las pantallas que ya ensenan el saldo en grande. Aqui, declarado y en un
// solo sitio, para que se pueda discutir la lista sin buscarla.
//
// PENDIENTE DE DECISION DE JOTA: `/dashboard/retirar` ensena "Saldo total: Bs
// X", que es EXACTAMENTE la cifra de esta cabecera. Por el motivo que el dio
// -- no repetir el mismo dinero dos veces en una pantalla -- deberia estar en
// esta lista. No la meto por mi cuenta: el dijo "el dashboard y la de pujar",
// y es una linea cambiarlo.
function yaEnsenaElSaldo(ruta: string) {
  if (ruta === "/dashboard") return true
  // La pantalla de pujar: /remates/<id>, no la lista /remates.
  if (ruta.startsWith("/remates/") && ruta !== "/remates") return true
  return false
}

function bs(v: number) {
  return v.toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

export default function CabeceraCliente() {
  const pathname = usePathname()
  const { visible, usuario, saldo } = useSesionCliente()

  if (!visible) return null

  const conSaldo = !yaEnsenaElSaldo(pathname)

  return (
    <header className="sticky top-0 z-30 border-b border-zinc-800 bg-zinc-950/95 backdrop-blur">
      <div className="mx-auto flex w-full max-w-7xl items-center gap-3 px-4 py-2.5 sm:px-6 lg:px-8">
        {/* La marca de la plataforma manda; la de la casa va debajo y mas
            pequena. Ver lib/marca.ts. */}
        <Link href="/remates" className="flex min-w-0 shrink-0 items-center gap-2.5" aria-label="Ir a remates">
          <Image
            src={PLATAFORMA.isotipo}
            alt={PLATAFORMA.nombre}
            width={36}
            height={36}
            priority
            className="h-8 w-8 shrink-0 object-contain sm:h-9 sm:w-9"
          />
          <span className="hidden min-w-0 sm:block">
            <span className="block truncate text-sm font-semibold leading-tight text-oro">
              {PLATAFORMA.corto}
            </span>
            {CASA ? (
              <span className="block truncate text-[11px] leading-tight text-zinc-500">
                {CASA.nombre}
              </span>
            ) : null}
          </span>
        </Link>

        {/* EL MENU, EN ESCRITORIO. En movil no se pinta aqui: vive en la barra
            inferior, que es donde Jota lo quiere y donde el pulgar llega. */}
        <nav className="ml-4 hidden flex-1 items-center gap-1 lg:flex">
          {ENLACES_CLIENTE.map((e) => {
            const activo = e.activo(pathname)
            return (
              <Link
                key={e.href}
                href={e.href}
                aria-current={activo ? "page" : undefined}
                className={`rounded-lg px-3 py-1.5 text-sm font-semibold transition-colors ${
                  activo ? "bg-white text-zinc-950" : "text-zinc-300 hover:bg-zinc-900 hover:text-white"
                }`}
              >
                {e.etiqueta}
              </Link>
            )
          })}
        </nav>

        {/* El hueco que separa la marca del bloque de la derecha cuando el
            menu no esta (movil). Sin esto, con `conSaldo` en false la marca
            se queda sola y centrada, que parece un error de maquetacion. */}
        <div className="flex-1 lg:hidden" />

        {/* Usuario y saldo. El saldo es un enlace al panel: ver cuanto tienes
            y querer moverlo es el mismo gesto. */}
        {conSaldo ? (
          <Link
            href="/dashboard"
            className="flex min-w-0 shrink-0 items-center gap-3 rounded-xl px-2 py-1 text-right hover:bg-zinc-900"
          >
            <span className="min-w-0">
              <span className="block max-w-[9rem] truncate text-[11px] leading-tight text-zinc-400 sm:max-w-[14rem]">
                {usuario}
              </span>
              <span className="block text-sm font-bold leading-tight tabular-nums text-emerald-300">
                {saldo === null ? "—" : `${bs(saldo)} Bs`}
              </span>
            </span>
          </Link>
        ) : null}
      </div>
    </header>
  )
}
