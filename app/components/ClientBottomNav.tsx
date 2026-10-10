"use client"

// ===========================================================================
//  components/ClientBottomNav.tsx  -  LA BARRA INFERIOR, SOLO PINTURA
//
//  No decide si se ve ni en que rutas: eso lo hace NavegacionCliente con lo
//  que le dice SesionCliente. Aqui solo se pinta.
//
//  Los enlaces vienen de `enlacesCliente.ts`, compartidos con la cabecera de
//  escritorio. Antes la lista vivia en este archivo; al nacer la cabecera
//  habrian sido dos listas, y la siguiente pantalla habria entrado en una y
//  no en la otra.
//
//  EL ANCHO. `max-w-md` era correcto cuando la barra tambien se pintaba en
//  escritorio: evitaba cinco botones separados por metro y medio. Ahora la
//  barra es solo de movil, asi que el limite no hace nada en la practica y se
//  queda como tope de seguridad para una tablet estrecha en horizontal.
// ===========================================================================

import Link from "next/link"
import { usePathname } from "next/navigation"
import { ENLACES_CLIENTE } from "./enlacesCliente"

export default function ClientBottomNav({ nuevos = 0 }: { nuevos?: number }) {
  const pathname = usePathname()

  return (
    <nav className="fixed inset-x-0 bottom-0 z-40 border-t border-zinc-800 bg-zinc-950/95 backdrop-blur">
      <div className="mx-auto flex max-w-md items-center justify-between px-4 py-2">
        {ENLACES_CLIENTE.map((item) => {
          const activo = item.activo(pathname)
          return (
            <Link
              key={item.href}
              href={item.href}
              aria-current={activo ? "page" : undefined}
              className={`flex-1 rounded-lg px-2 py-2 text-center text-xs font-semibold ${
                activo ? "bg-white text-zinc-950" : "text-zinc-300"
              }`}
            >
              {item.etiqueta}
              {/* El contador va SOLO en Remates, que es donde se resuelve.
                  Un punto en un boton que no lleva a lo nuevo es una pista
                  falsa. Desaparece al entrar en la lista. */}
              {item.href === "/remates" && nuevos > 0 ? (
                <span
                  className={`ml-1 inline-flex min-w-[1.1rem] items-center justify-center rounded-full px-1 text-[10px] font-bold ${
                    activo ? "bg-zinc-900 text-amber-300" : "bg-amber-400 text-zinc-950"
                  }`}
                >
                  {nuevos > 9 ? "9+" : nuevos}
                </span>
              ) : null}
            </Link>
          )
        })}
      </div>
    </nav>
  )
}
