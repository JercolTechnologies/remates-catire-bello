"use client"

// COMPONENTS/REMATESENVIVO.TSX
//
// UNA SOLA SUSCRIPCION AL CANAL DE LA COLECCION, PARA TODA LA APLICACION
//
// Tres sitios necesitan enterarse de que la lista de remates cambio:
//
//   /remates          -> recargar la lista
//   el menu inferior  -> el contador de "hay remates nuevos"
//   /admin/remates    -> recargar la suya
//
// Si cada uno se suscribiera por su cuenta serian hasta tres canales con el
// MISMO topico en el mismo navegador: ruido en el servidor y tres fuentes de la
// misma verdad en el cliente. Es exactamente lo que se corrigio para el canal de
// caja (ADR-026), aplicado antes de repetir el error.
//
// El contexto expone `version`, que sube con cada senal. Cualquier pantalla que
// quiera recargarse pone un efecto sobre ella. Nadie vuelve a suscribir nada.
//
// EL CONTADOR DE NOVEDADES, Y POR QUE NO ES UN POPUP.
// Decidido con Jota el 05/10: el popup es para lo que te pasa a TI -- ganaste,
// te aprobaron la recarga -- y un remate nuevo es un anuncio, no algo personal.
// Con su flujo real de crear todas las carreras del fin de semana un martes por
// la noche, un popup por remate serian doce ventanas seguidas, y el jugador que
// aprende a cerrar ventanas sin leerlas cierra tambien la del premio.
// Ver la migracion 20261006120000.

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react"
import { supabase } from "@/lib/supabaseClient"
import { useSenal, TOPICO_LISTA, EVENTOS_LISTA } from "@/lib/realtime"

type Remates = {
  /** Sube con cada senal del canal de la coleccion. */
  version: number
  /** Cuantos remates aparecieron desde la ultima vez que este usuario miro. */
  nuevos: number
  /** La marca ANTERIOR, para pintar "NUEVO" en las filas que toca. */
  vistosDesde: string | null
  /** La llama la pantalla de remates al abrirse. */
  marcarVistos: () => Promise<void>
}

const Contexto = createContext<Remates>({
  version: 0,
  nuevos: 0,
  vistosDesde: null,
  marcarVistos: async () => {},
})

export function useRematesEnVivo() {
  return useContext(Contexto)
}

export function RematesEnVivo({ children }: { children: React.ReactNode }) {
  const [version, setVersion] = useState(0)
  const [nuevos, setNuevos] = useState(0)
  const [vistosDesde, setVistosDesde] = useState<string | null>(null)
  const [haySesion, setHaySesion] = useState(false)

  const contar = useCallback(async () => {
    const { data, error } = await supabase.rpc("remates_nuevos")
    if (error) {
      // Un contador que no se puede leer no puede romper la aplicacion entera:
      // esto envuelve todas las pantallas.
      console.warn("[remates] contador:", error.message)
      return
    }
    const fila = Array.isArray(data) ? data[0] : data
    if (!fila) return
    setNuevos(Number(fila.nuevos) || 0)
    setVistosDesde(fila.vistos_desde ?? null)
  }, [])

  useEffect(() => {
    let vivo = true

    async function mirar() {
      const { data } = await supabase.auth.getUser()
      if (!vivo) return
      const hay = !!data?.user
      setHaySesion(hay)
      if (hay) void contar()
      else {
        setNuevos(0)
        setVistosDesde(null)
      }
    }

    void mirar()
    const { data: sub } = supabase.auth.onAuthStateChange(() => void mirar())
    return () => {
      vivo = false
      sub?.subscription?.unsubscribe()
    }
  }, [contar])

  // La suscripcion es SIEMPRE, con sesion o sin ella: la lista de remates es
  // publica y un visitante sin cuenta tambien tiene que verla moverse.
  // `useSenal` ya reconecta solo y recarga al volver al frente (ADR-025).
  useSenal(TOPICO_LISTA, EVENTOS_LISTA, () => {
    setVersion((v) => v + 1)
    if (haySesion) void contar()
  })

  const marcarVistos = useCallback(async () => {
    if (!haySesion) return
    const { error } = await supabase.rpc("marcar_remates_vistos")
    if (error) {
      console.warn("[remates] no se pudo marcar como vistos:", error.message)
      return
    }
    // `vistosDesde` NO se toca: mientras el jugador siga en la lista, las filas
    // que acaba de descubrir tienen que seguir marcadas. La marca nueva surte
    // efecto la proxima vez que entre.
    setNuevos(0)
  }, [haySesion])

  const valor = useMemo<Remates>(
    () => ({ version, nuevos, vistosDesde, marcarVistos }),
    [version, nuevos, vistosDesde, marcarVistos]
  )

  return <Contexto.Provider value={valor}>{children}</Contexto.Provider>
}
