"use client"

// ADMIN/CAJAENVIVO.TSX
//
// EL AVISO DE CAJA, VIVO EN TODO EL PANEL
//
// EL DEFECTO QUE ARREGLA (señalado por Jota el 05/10/2026, y tenía razón):
//
//   "La idea es que cuando alguien solicite recarga o retiro, al admin le
//    aparezca la notificación en tiempo real SIN IMPORTAR LA PANTALLA de la
//    app en la que esté, porque si el realtime funciona solamente dentro de
//    /recargas - /retiros, entonces eso es prácticamente como que no
//    existiera ningún realtime."
//
// Y así estaba. `useSenal(TOPICO_CAJA, ...)` vivía dentro de las dos pantallas
// de gestión, así que la suscripción nacía al abrirlas y moría al salir. El
// panel `/admin` -- que es donde un admin se queda esperando, y donde están
// los contadores de pendientes -- no se suscribía a NADA. Sus dos números solo
// se leían al montar la página.
//
// Yo estuve dos turnos midiendo el realtime parado dentro de /admin/retiros,
// que es justo el único sitio donde funcionaba. La prueba pasaba y el producto
// seguía roto.
//
// LA FORMA: una sola suscripción para todo el panel, en el layout.
//
//   - UN canal `admin:caja` por sesión de navegador, no uno por pantalla. Dos
//     canales con el mismo topico son dos uniones al mismo sitio: ruido en el
//     servidor y una fuente doble de verdad en el cliente.
//   - El contexto expone `version`, que sube con cada señal. Cada pantalla que
//     quiera recargarse pone un efecto sobre `version` y se acabó: no hay que
//     suscribir nada más nunca.
//   - Los contadores viven aquí, así que la barra de aviso y el panel muestran
//     el mismo número por construcción. No puede haber uno en 2 y el otro en 0.
//
// NO HACE NADA SIN SESION DE ADMIN. En `/admin/login` no hay a quien avisar, y
// una consulta sin sesión solo sirve para llenar la consola de errores.

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react"
import Link from "next/link"
import { supabase } from "@/lib/supabaseClient"
import { useSenal, TOPICO_CAJA, EVENTOS_CAJA } from "@/lib/realtime"

type Caja = {
  /** Sube con cada señal recibida. Un efecto sobre esto recarga la pantalla. */
  version: number
  recargasPendientes: number
  retirosPendientes: number
  /** Para que una pantalla pida los contadores de nuevo tras aprobar o pagar. */
  refrescar: () => void
  activo: boolean
}

const CajaContexto = createContext<Caja>({
  version: 0,
  recargasPendientes: 0,
  retirosPendientes: 0,
  refrescar: () => {},
  activo: false,
})

export function useCajaEnVivo() {
  return useContext(CajaContexto)
}

export function CajaEnVivo({ children }: { children: React.ReactNode }) {
  const [esAdmin, setEsAdmin] = useState(false)
  const [version, setVersion] = useState(0)
  const [recargas, setRecargas] = useState(0)
  const [retiros, setRetiros] = useState(0)
  const [destacar, setDestacar] = useState(false)

  // Los últimos contadores vistos, para saber si lo que llegó es NUEVO. Va en
  // una referencia y no en estado: solo sirve para comparar, y meterlo en el
  // estado provocaría un render de más por cada consulta.
  const previos = useRef({ recargas: 0, retiros: 0 })
  const primeraVez = useRef(true)

  const contar = useCallback(async () => {
    const dep = await supabase
      .from("deposit_requests")
      .select("id", { count: "exact", head: true })
      .eq("estado", "pendiente")

    const wit = await supabase
      .from("withdraw_requests")
      .select("id", { count: "exact", head: true })
      .eq("estado", "pendiente")

    if (dep.error || wit.error) {
      // Un contador que no se puede leer no puede tumbar el panel entero. Se
      // deja escrito y se sigue.
      console.warn("[caja] contadores:", dep.error?.message || wit.error?.message)
      return
    }

    const r = dep.count ?? 0
    const w = wit.count ?? 0

    // Solo se destaca cuando SUBE, y nunca en la primera lectura: al abrir el
    // panel con tres pendientes de ayer no hay ninguna novedad que señalar.
    const subio = r > previos.current.recargas || w > previos.current.retiros
    if (subio && !primeraVez.current) {
      setDestacar(true)
      window.setTimeout(() => setDestacar(false), 6000)
    }
    primeraVez.current = false
    previos.current = { recargas: r, retiros: w }

    setRecargas(r)
    setRetiros(w)
  }, [])

  // Quien mira. Se vuelve a comprobar en cada cambio de sesión para que al
  // iniciar sesión el aviso se encienda sin recargar la página.
  useEffect(() => {
    let vivo = true

    async function mirar() {
      const { data: auth } = await supabase.auth.getUser()
      if (!vivo) return
      if (!auth?.user) {
        setEsAdmin(false)
        return
      }
      const { data: prof } = await supabase
        .from("profiles")
        .select("es_admin,es_super_admin")
        .eq("id", auth.user.id)
        .maybeSingle()
      if (!vivo) return
      setEsAdmin(!!(prof?.es_admin || prof?.es_super_admin))
    }

    void mirar()
    const { data: sub } = supabase.auth.onAuthStateChange(() => {
      primeraVez.current = true
      void mirar()
    })

    return () => {
      vivo = false
      sub?.subscription?.unsubscribe()
    }
  }, [])

  useEffect(() => {
    if (!esAdmin) return
    void contar()
  }, [esAdmin, contar])

  // LA UNICA SUSCRIPCION A admin:caja DE TODO EL PANEL.
  // `useSenal` ya se encarga de reconectar si el canal se cae y de recargar al
  // volver al frente (ADR-025). Aquí solo hay que decirle qué hacer al recibir.
  useSenal(esAdmin ? TOPICO_CAJA : null, EVENTOS_CAJA, () => {
    void contar()
    setVersion((v) => v + 1)
  })

  const valor = useMemo<Caja>(
    () => ({
      version,
      recargasPendientes: recargas,
      retirosPendientes: retiros,
      refrescar: () => void contar(),
      activo: esAdmin,
    }),
    [version, recargas, retiros, contar, esAdmin]
  )

  const hayAlgo = recargas > 0 || retiros > 0

  return (
    <CajaContexto.Provider value={valor}>
      {esAdmin && hayAlgo ? (
        <div
          className={`sticky top-0 z-50 border-b px-4 py-2 transition-colors ${
            destacar
              ? "bg-amber-500/25 border-amber-400/60"
              : "bg-zinc-900/95 border-zinc-800 backdrop-blur"
          }`}
        >
          <div className="mx-auto flex w-full max-w-3xl flex-wrap items-center justify-between gap-2">
            <div className="text-sm text-zinc-100">
              {destacar ? <span className="mr-2 font-bold text-amber-200">NUEVO</span> : null}
              <span className="font-semibold">Caja pendiente:</span>{" "}
              {recargas > 0 ? (
                <Link href="/admin/recargas" className="underline underline-offset-4">
                  {recargas} {recargas === 1 ? "recarga" : "recargas"}
                </Link>
              ) : null}
              {recargas > 0 && retiros > 0 ? <span className="text-zinc-500"> · </span> : null}
              {retiros > 0 ? (
                <Link href="/admin/retiros" className="underline underline-offset-4">
                  {retiros} {retiros === 1 ? "retiro" : "retiros"}
                </Link>
              ) : null}
            </div>
            <button
              onClick={() => void contar()}
              className="rounded-lg border border-zinc-700 px-2 py-1 text-xs text-zinc-300"
            >
              Comprobar
            </button>
          </div>
        </div>
      ) : null}
      {children}
    </CajaContexto.Provider>
  )
}
