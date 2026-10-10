"use client"

// ===========================================================================
//  components/AvisoFundar.tsx  -  "ESTA CASA TODAVIA NO TIENE DUENO"
//
//  EL DEFECTO QUE ARREGLA (10/10/2026)
//
//  Medido trazando el codigo: quien se registra en una instalacion recien
//  entregada cae en `/dashboard` -- el panel de JUGADOR, con saldo 0 y sin
//  remates. El futuro dueno de la casa aterriza en la pantalla de un
//  apostador vacio, y para llegar a `/admin/login` tiene que saber que esa
//  ruta existe: NO HAY NI UN ENLACE que lleve ahi desde el lado publico.
//
//  O sea: la aplicacion estaba lista para funcionar y no tenia forma de
//  decirle al dueno como empezar.
//
//  VA EN EL LAYOUT, NO EN UNA PANTALLA. Es el ADR-026 otra vez: el licenciatario
//  puede caer en la portada, en /dashboard o en /remates segun por donde entre,
//  y el aviso tiene que encontrarlo en los tres sitios. Ponerlo solo en la
//  portada seria confiar en que entre por ahi.
//
//  SE APAGA SOLO Y PARA SIEMPRE. `casa_fundada()` pasa a true en cuanto
//  alguien funda, y a partir de ese momento esto no pinta nada nunca mas. No
//  hay que acordarse de quitarlo.
//
//  NO PINTA EN /admin. Ahi ya esta la pantalla que hace el trabajo, y un aviso
//  diciendote que vayas donde ya estas es ruido.
// ===========================================================================

import { useEffect, useState } from "react"
import Link from "next/link"
import { usePathname } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

export default function AvisoFundar() {
  const pathname = usePathname()
  const [fundada, setFundada] = useState<boolean | null>(null)

  useEffect(() => {
    let vivo = true
    void (async () => {
      const { data, error } = await supabase.rpc("casa_fundada")
      if (!vivo) return
      if (error) {
        // Una instalacion a medio aplicar todavia no tiene la funcion. No es
        // motivo para romper la pagina: se calla y ya.
        console.warn("[fundar]", error.message)
        setFundada(true)
        return
      }
      setFundada(data === true)
    })()
    return () => {
      vivo = false
    }
  }, [])

  if (fundada !== false) return null
  if (pathname.startsWith("/admin")) return null

  return (
    <div className="border-b border-amber-500/30 bg-amber-500/10">
      <div className="mx-auto flex w-full max-w-7xl flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center sm:justify-between sm:px-6 lg:px-8">
        <div className="min-w-0">
          <div className="text-sm font-semibold text-amber-200">
            Esta casa todavía no tiene dueño
          </div>
          <div className="text-xs leading-snug text-amber-200/70">
            La instalación está lista, pero falta que su administrador la funde. Si eres tú,
            regístrate con el correo designado y entra por aquí.
          </div>
        </div>
        <Link
          href="/admin/login"
          className="shrink-0 rounded-xl bg-amber-400 px-4 py-2 text-center text-sm font-semibold text-zinc-950"
        >
          Fundar la casa
        </Link>
      </div>
    </div>
  )
}
