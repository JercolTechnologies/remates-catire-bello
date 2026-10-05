"use client"

// COMPONENTS/AVISOSDELUSUARIO.TSX
//
// EL AVISO QUE LE LLEGA AL JUGADOR, ESTE DONDE ESTE
//
// Pedido por Jota el 02/10 liquidando un remate: "aqui tiene que salir un popup
// avisando al ganador, tanto si esta en linea como si no estaba e inicio
// sesion". Esas dos mitades decidieron el diseno entero:
//
//   "si esta en linea"  -> una senal en tiempo real
//   "si inicio sesion"  -> una fila que PERSISTE y sabe si ya se leyo
//
// La segunda es la que manda. Un toast que se emite y se pierde no sirve: el
// ganador puede estar durmiendo cuando se liquida su remate.
//
// VA EN EL LAYOUT RAIZ, no dentro de una pantalla. Es la leccion del ADR-026,
// aplicada antes de volver a tropezar: un aviso que solo existe en la pantalla
// que lo muestra no es un aviso, es un detalle de esa pantalla. Aqui cubre la
// aplicacion entera -- remates, dashboard, recargar, reglas -- y sobrevive a la
// navegacion porque el layout no se vuelve a montar.
//
// SIN SESION NO HACE NADA. Ni consulta, ni se suscribe, ni pinta.
//
// Y NO SE INVENTA EL TEXTO: lo trae de la base. La senal solo dice "tienes algo
// nuevo" (ADR-015). Si el texto viajara en el evento, viviria en dos sitios.

import { useCallback, useEffect, useState } from "react"
import { supabase } from "@/lib/supabaseClient"
import { useSenal, topicoUsuario, EVENTOS_USUARIO } from "@/lib/realtime"

type Aviso = {
  id: string
  tipo: string
  titulo: string
  mensaje: string
  monto: string | number | null
  created_at: string
}

function formatMoney(v: unknown) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : NaN
  if (!Number.isFinite(x)) return null
  return x.toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

export default function AvisosDelUsuario() {
  const [userId, setUserId] = useState<string | null>(null)
  const [cola, setCola] = useState<Aviso[]>([])
  const [cerrando, setCerrando] = useState(false)

  // Quien mira. Se vuelve a comprobar en cada cambio de sesion para que al
  // iniciar sesion los avisos pendientes salgan sin recargar la pagina -- que es
  // justamente la mitad del requisito.
  useEffect(() => {
    let vivo = true

    async function mirar() {
      const { data } = await supabase.auth.getUser()
      if (!vivo) return
      setUserId(data?.user?.id ?? null)
      if (!data?.user) setCola([])
    }

    void mirar()
    const { data: sub } = supabase.auth.onAuthStateChange(() => void mirar())
    return () => {
      vivo = false
      sub?.subscription?.unsubscribe()
    }
  }, [])

  const cargar = useCallback(async () => {
    if (!userId) return
    const { data, error } = await supabase
      .from("notificaciones")
      .select("id,tipo,titulo,mensaje,monto,created_at")
      .is("leida_at", null)
      .order("created_at", { ascending: true })
      .limit(20)

    if (error) {
      // Que no se puedan leer los avisos no puede romper la pagina que los
      // aloja: esto va en el layout raiz y lo envuelve todo.
      console.warn("[avisos] no se pudieron leer:", error.message)
      return
    }
    setCola((data ?? []) as Aviso[])
  }, [userId])

  useEffect(() => {
    void cargar()
  }, [cargar])

  // `useSenal` ya reconecta solo y recarga al volver al frente (ADR-025), asi
  // que un aviso emitido con la pestana de fondo aparece al volver a ella.
  useSenal(userId ? topicoUsuario(userId) : null, EVENTOS_USUARIO, () => {
    void cargar()
  })

  const actual = cola[0]
  if (!userId || !actual) return null

  const monto = formatMoney(actual.monto)

  async function entendido() {
    setCerrando(true)
    try {
      const { error } = await supabase.rpc("marcar_aviso_leido", { p_id: actual.id })
      if (error) throw new Error(error.message)
      // Se saca de la cola aqui y no se recarga todo: si quedan tres avisos,
      // el siguiente tiene que salir al instante, no despues de otra consulta.
      setCola((prev) => prev.slice(1))
    } catch (e) {
      // Si no se pudo marcar, el aviso se queda. Preferible verlo dos veces que
      // perderlo: el usuario puede cerrar el navegador creyendo que lo leyo.
      console.warn("[avisos] no se pudo marcar como leido:", e)
      setCola((prev) => prev.slice(1))
    } finally {
      setCerrando(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[100] flex items-end justify-center bg-black/70 p-4 sm:items-center">
      <div className="w-full max-w-sm rounded-2xl border border-zinc-700 bg-zinc-900 p-5 shadow-2xl">
        {actual.tipo === "premio" ? (
          <div className="text-xs font-bold uppercase tracking-wide text-emerald-300">Felicitaciones</div>
        ) : null}

        <div className="mt-1 text-lg font-bold text-zinc-50">{actual.titulo}</div>

        {monto ? (
          <div
            className={`mt-2 text-2xl font-bold tabular-nums ${
              actual.tipo === "premio" ? "text-emerald-300" : "text-zinc-100"
            }`}
          >
            {monto} Bs
          </div>
        ) : null}

        <p className="mt-2 text-sm text-zinc-300">{actual.mensaje}</p>

        {cola.length > 1 ? (
          <div className="mt-3 text-[11px] text-zinc-500">
            Te quedan {cola.length - 1} {cola.length - 1 === 1 ? "aviso" : "avisos"} más.
          </div>
        ) : null}

        <button
          onClick={() => void entendido()}
          disabled={cerrando}
          className="mt-4 w-full rounded-xl bg-white px-3 py-2 text-sm font-semibold text-zinc-950 disabled:opacity-60"
        >
          {cerrando ? "..." : "Entendido"}
        </button>
      </div>
    </div>
  )
}
