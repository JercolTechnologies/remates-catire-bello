// ADMIN/LOG/PAGE.TSX
//
// EL REGISTRO DE TRANSACCIONES
//
// Lo pidio Jota asi: "Hay que tener un log de transacciones URGENTE... ahi es
// que se ve en realidad por que las cosas dan lo que dan".
//
// NO HIZO FALTA NINGUNA MIGRACION. Los datos ya estaban los tres sitios, con
// sus politicas de admin puestas desde el 29/09; lo que faltaba era la
// pantalla. `admin_actions` en particular lleva desde el principio guardando
// quien aprobo, quien rechazo, con que motivo y si fallo, y hasta hoy no lo
// leia absolutamente nadie.
//
// TRES PESTANAS, NO UNA LINEA DE TIEMPO MEZCLADA (decidido por Jota el 05/10).
// Cada fuente responde una pregunta distinta y se audita por separado:
//
//   Movimientos -> que le paso al dinero de un JUGADOR     (wallet_movements)
//   Libro       -> que le paso al dinero de la CASA        (house_ledger)
//   Acciones    -> que hizo un ADMIN, y si le salio bien   (admin_actions)
//
// ESTA PANTALLA NO CALCULA NADA. Lee y muestra. Es el ADR-015: si aqui se
// sumara o se dedujera algo, habria una segunda contabilidad escrita en
// TypeScript que podria discrepar de la de la base -- que es exactamente el
// defecto que esta pantalla existe para poder detectar.
//
// ANCHO: `max-w-3xl` en vez del `max-w-md` del resto del panel. Es a
// proposito y es la unica pantalla que se sale: un registro de auditoria con
// fecha, actor, importe, descripcion y referencia no cabe en ancho de telefono
// sin partir cada fila en cuatro lineas. En telefono sigue cayendo a una
// columna.

"use client"

import { useCallback, useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

const POR_PAGINA = 50

type Pestana = "movimientos" | "libro" | "acciones"

function n(v: unknown) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: unknown) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatDT(v: string | null) {
  if (!v) return "-"
  const d = new Date(v)
  return Number.isNaN(d.getTime()) ? "-" : d.toLocaleString("es-VE")
}

// La zona en la que el NAVEGADOR va a pintar esas fechas. Se muestra en
// pantalla a proposito: el resto de la aplicacion tambien formatea en la zona
// del navegador, y en un registro de auditoria una hora sin zona no sirve de
// nada. Aqui no se cambia la convencion, se dice cual es.
function zonaDelNavegador() {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "la de tu equipo"
  } catch {
    return "la de tu equipo"
  }
}

// PostgREST interpreta comas y parentesis como separadores dentro de `or(...)`.
// Un texto de busqueda con una coma rompe la consulta, y con parentesis puede
// cambiar el filtro entero. Se limpian antes de construir el filtro: el usuario
// no escribe sintaxis, escribe palabras.
function limpiarBusqueda(t: string) {
  return t.replace(/[,()*"\\%]/g, " ").trim()
}

// Las fechas del filtro son dias LOCALES, y se convierten a instantes usando la
// zona del navegador -- la misma con la que se pintan. Si el filtro usara una
// zona y la columna se pintara en otra, la primera fila de cada dia parecería
// estar fuera del rango pedido.
function inicioDelDia(d: string) {
  if (!d) return null
  const x = new Date(`${d}T00:00:00`)
  return Number.isNaN(x.getTime()) ? null : x.toISOString()
}
function finDelDia(d: string) {
  if (!d) return null
  const x = new Date(`${d}T23:59:59.999`)
  return Number.isNaN(x.getTime()) ? null : x.toISOString()
}

const ETIQUETA_MOVIMIENTO: Record<string, string> = {
  recarga: "Recarga",
  retiro: "Retiro",
  premio: "Premio",
  ajuste_manual: "Ajuste manual",
  apuesta_bloqueo: "Puja bloqueada",
  apuesta_liberacion: "Puja liberada",
  apuesta_desbloqueo: "Puja desbloqueada",
  apuesta_cobro: "Cobro al cerrar",
  apuesta_devolucion: "Devolucion",
}

const ETIQUETA_LIBRO: Record<string, string> = {
  aporte_capital: "Aporte de capital",
  retiro_utilidad: "Retiro de utilidad",
  ajuste: "Ajuste",
  resultado_remate: "Resultado de remate",
}

// ---------------------------------------------------------------------------
//  DE JSON A CASTELLANO
//
//  La primera version pintaba `details` con un JSON.stringify y ya. Jota lo
//  vio y lo dijo en una linea: "eso no esta como muy complicado?". Lo estaba.
//  Un registro de auditoria que hay que descifrar no se lee, y un registro
//  que no se lee es un registro que no existe -- que es justo el defecto que
//  esta pantalla vino a arreglar.
//
//  El criterio: lo que se busca al abrir una fila es QUE CAMBIO. Eso va
//  primero y en palabras; el JSON completo se queda detras de "ver todo",
//  porque para auditar de verdad a veces hace falta el dato crudo.
//
//  Y todo esto degrada bien: una accion nueva, o una clave que todavia no
//  esta en estas tablas, sale legible igual (guiones bajos por espacios y la
//  primera en mayuscula) en vez de desaparecer o romper la fila.
// ---------------------------------------------------------------------------

const ETIQUETA_ACCION: Record<string, string> = {
  procesar_retiro: "Retiro procesado",
  rechazar_recarga: "Recarga rechazada",
  editar_remate: "Remate editado",
  cancelar_remate: "Remate cancelado",
  auto_cerrar_remates: "Cierre automático",
  retirar_caballo: "Caballo retirado",
  registrar_movimiento_casa: "Asiento en el libro",
}

const ETIQUETA_TABLA: Record<string, string> = {
  withdraw_requests: "Retiro",
  deposit_requests: "Recarga",
  remates: "Remate",
  horses: "Caballo",
  races: "Carrera",
  house_ledger: "Asiento",
  profiles: "Usuario",
  wallets: "Cartera",
}

const ETIQUETA_CLAVE: Record<string, string> = {
  monto: "Monto",
  metodo: "Método",
  estado: "Estado",
  estado_previo: "Estado previo",
  motivo: "Motivo",
  motivo_etiqueta: "Motivo",
  motivo_nota: "Nota",
  devuelto: "Dinero devuelto",
  telefono_destino: "Teléfono",
  incremento_minimo: "Incremento",
  porcentaje_casa: "% casa",
  opens_at: "Apertura",
  closes_at: "Cierre",
  closes_at_vencido: "Cierre vencido",
  tipo: "Tipo",
  numero: "Número",
  habia_pujas: "Había pujas",
  pozo_total: "Pozo",
  premio_pagado: "Premio",
  gano_la_casa: "Ganó la casa",
  es_admin: "Es admin",
  antes: "Antes",
  despues: "Después",
}

// Identificadores internos. No se ocultan por secreto -- siguen en "ver todo" --
// sino porque un UUID en medio de una frase la vuelve ilegible y no responde
// ninguna pregunta que un admin se haga mirando esta pantalla.
const CLAVES_OCULTAS = new Set([
  "id", "user_id", "admin_id", "remate_id", "horse_id", "race_id", "wallet_id",
  "motivo_codigo", "prev", "next",
])

function tituloDeAccion(a: string) {
  if (ETIQUETA_ACCION[a]) return ETIQUETA_ACCION[a]
  const t = a.replace(/_/g, " ")
  return t.charAt(0).toUpperCase() + t.slice(1)
}

function etiquetaDeClave(k: string) {
  if (ETIQUETA_CLAVE[k]) return ETIQUETA_CLAVE[k]
  const t = k.replace(/_/g, " ")
  return t.charAt(0).toUpperCase() + t.slice(1)
}

// Un UUID entero no cabe y no se recuerda. Los primeros ocho caracteres bastan
// para reconocer una fila y para buscarla: el buscador de arriba filtra por
// `target_id` con `ilike`, asi que pegar ese trozo encuentra la misma fila.
function idCorto(id: string | null | undefined) {
  if (!id) return ""
  return id.length > 8 ? id.slice(0, 8) : id
}

function textoDeValor(clave: string, v: unknown): string {
  if (v === null || v === undefined) return "(vacío)"
  if (typeof v === "boolean") return v ? "sí" : "no"
  if (typeof v === "number") {
    if (clave === "monto" || clave === "pozo_total" || clave === "premio_pagado") {
      return `${formatMoney(v)} Bs`
    }
    if (clave === "porcentaje_casa") return `${v}%`
    return String(v)
  }
  if (typeof v === "string") {
    // Una marca de tiempo se lee como fecha, no como cadena ISO.
    if (/^\d{4}-\d{2}-\d{2}T/.test(v)) return formatDT(v)
    return v
  }
  return JSON.stringify(v)
}

function resumirDetalles(d: unknown): string[] {
  if (!d || typeof d !== "object" || Array.isArray(d)) return []
  const obj = d as Record<string, unknown>
  const fuera: string[] = []

  // EL CAMBIO DE ESTADO VA PRIMERO. Es lo que se busca al abrir una fila:
  // "pendiente → pagado" responde la pregunta antes de leer nada mas.
  const prev = obj.prev as Record<string, unknown> | undefined
  const next = obj.next as Record<string, unknown> | undefined
  const antes = prev && typeof prev === "object" ? prev.estado : undefined
  const despues = next && typeof next === "object" ? next.estado : undefined
  if (antes || despues) fuera.push(`${antes ?? "?"} → ${despues ?? "?"}`)

  for (const [k, v] of Object.entries(obj)) {
    if (CLAVES_OCULTAS.has(k)) continue
    if (v === null || v === undefined) continue

    // La forma {antes, despues} la usan las ediciones de remate.
    if (v && typeof v === "object" && !Array.isArray(v) && ("antes" in v || "despues" in v)) {
      const par = v as Record<string, unknown>
      fuera.push(
        `${etiquetaDeClave(k)}: ${textoDeValor(k, par.antes)} → ${textoDeValor(k, par.despues)}`
      )
      continue
    }

    // Cualquier otro objeto se queda para "ver todo": meterlo aqui seria
    // volver a pintar JSON con otra letra.
    if (typeof v === "object") continue

    // Un booleano en false no aporta: "Dinero devuelto: no" ocupa sitio para
    // decir que no paso nada.
    if (typeof v === "boolean" && v === false) continue

    fuera.push(`${etiquetaDeClave(k)}: ${textoDeValor(k, v)}`)
  }

  return fuera
}

type Fila = {
  id: string
  cuando: string | null
  quien: string
  tipo: string
  etiqueta: string
  monto: number | null
  texto: string
  ref: string | null
  ok: boolean
  /** Lo que cambio, ya en castellano. Se pinta como etiquetas. */
  resumen: string[]
  /** El JSON tal cual, detras de "ver todo". Para auditar de verdad. */
  crudo: string | null
}

export default function AdminLogPage() {
  const router = useRouter()

  const [pestana, setPestana] = useState<Pestana>("movimientos")
  const [loading, setLoading] = useState(true)
  const [cargandoMas, setCargandoMas] = useState(false)
  const [error, setError] = useState("")

  const [filas, setFilas] = useState<Fila[]>([])
  const [hayMas, setHayMas] = useState(false)

  // filtros
  const [desde, setDesde] = useState("")
  const [hasta, setHasta] = useState("")
  const [texto, setTexto] = useState("")
  const [tipo, setTipo] = useState("")
  const [soloFallidas, setSoloFallidas] = useState(false)

  // Un contador que se incrementa para forzar una recarga desde cero. Mas
  // honesto que meter los filtros en las dependencias del efecto: asi la
  // consulta sale cuando el usuario lo pide, no mientras escribe.
  const [recarga, setRecarga] = useState(0)

  const zona = useMemo(() => zonaDelNavegador(), [])

  const tiposDisponibles = useMemo(() => {
    if (pestana === "movimientos") return Object.keys(ETIQUETA_MOVIMIENTO)
    if (pestana === "libro") return Object.keys(ETIQUETA_LIBRO)
    return []
  }, [pestana])

  const ensureAdmin = useCallback(async () => {
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/admin/login")
      return null
    }

    const { data: prof, error: profErr } = await supabase
      .from("profiles")
      .select("id,es_admin,es_super_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (profErr) throw new Error(profErr.message)
    if (!prof?.es_admin && !prof?.es_super_admin) {
      router.replace("/dashboard")
      return null
    }
    return auth.user.id
  }, [router])

  // Resuelve id de perfil -> nombre de usuario en UNA consulta para toda la
  // pagina. `admin_actions.admin_id` no tiene clave foranea a `profiles`, asi
  // que PostgREST no puede anidarlo; y haciendolo igual en las tres pestanas no
  // hay un camino que funcione y otro que no.
  async function nombresDe(ids: string[]) {
    const unicos = Array.from(new Set(ids.filter(Boolean)))
    if (unicos.length === 0) return {} as Record<string, string>
    const { data, error: e } = await supabase.from("profiles").select("id,username").in("id", unicos)
    if (e) {
      // Que falte un nombre no puede dejar al admin sin registro. Se sigue, y
      // las filas muestran el id.
      console.warn("[log] no se pudieron leer los nombres:", e.message)
      return {} as Record<string, string>
    }
    const mapa: Record<string, string> = {}
    for (const p of data ?? []) mapa[(p as any).id] = (p as any).username || "(sin nombre)"
    return mapa
  }

  const cargar = useCallback(
    async (pagina: number) => {
      if (pagina === 0) setLoading(true)
      else setCargandoMas(true)
      setError("")

      try {
        const adminId = await ensureAdmin()
        if (!adminId) return

        const ini = inicioDelDia(desde)
        const fin = finDelDia(hasta)
        const t = limpiarBusqueda(texto)
        const from = pagina * POR_PAGINA
        const to = from + POR_PAGINA - 1

        let nuevas: Fila[] = []

        if (pestana === "movimientos") {
          let q = supabase
            .from("wallet_movements")
            .select("id,wallet_id,tipo,monto,descripcion,ref_externa,created_at")
            .order("created_at", { ascending: false })
            .range(from, to)

          if (ini) q = q.gte("created_at", ini)
          if (fin) q = q.lte("created_at", fin)
          if (tipo) q = q.eq("tipo", tipo)
          if (t) q = q.or(`descripcion.ilike.%${t}%,ref_externa.ilike.%${t}%`)

          const { data, error: e } = await q
          if (e) throw new Error(e.message)
          const rows = (data ?? []) as any[]

          // wallet_id -> user_id -> username. Dos saltos, dos consultas, y el
          // registro sigue saliendo aunque alguno falle.
          const walletIds = Array.from(new Set(rows.map((r) => r.wallet_id).filter(Boolean)))
          const duenoDe: Record<string, string> = {}
          if (walletIds.length > 0) {
            const { data: ws, error: we } = await supabase
              .from("wallets")
              .select("id,user_id")
              .in("id", walletIds)
            if (we) console.warn("[log] wallets:", we.message)
            for (const w of ws ?? []) duenoDe[(w as any).id] = (w as any).user_id
          }
          const nombres = await nombresDe(Object.values(duenoDe))

          nuevas = rows.map((r) => ({
            id: r.id,
            cuando: r.created_at,
            quien: nombres[duenoDe[r.wallet_id]] || "(desconocido)",
            tipo: r.tipo,
            etiqueta: ETIQUETA_MOVIMIENTO[r.tipo] || r.tipo,
            monto: n(r.monto),
            texto: r.descripcion || "",
            ref: r.ref_externa,
            ok: true,
            resumen: [],
            crudo: null,
          }))
        } else if (pestana === "libro") {
          let q = supabase
            .from("house_ledger")
            .select("id,tipo,monto,motivo,ref_externa,created_by,created_at")
            .order("created_at", { ascending: false })
            .range(from, to)

          if (ini) q = q.gte("created_at", ini)
          if (fin) q = q.lte("created_at", fin)
          if (tipo) q = q.eq("tipo", tipo)
          if (t) q = q.or(`motivo.ilike.%${t}%,ref_externa.ilike.%${t}%`)

          const { data, error: e } = await q
          if (e) throw new Error(e.message)
          const rows = (data ?? []) as any[]
          const nombres = await nombresDe(rows.map((r) => r.created_by))

          nuevas = rows.map((r) => ({
            id: r.id,
            cuando: r.created_at,
            // created_by nulo no es un fallo: los `resultado_remate` los
            // escribe el sistema al liquidar, no una persona. Ver la migracion
            // 20260924150000.
            quien: r.created_by ? nombres[r.created_by] || "(desconocido)" : "El sistema",
            tipo: r.tipo,
            etiqueta: ETIQUETA_LIBRO[r.tipo] || r.tipo,
            monto: n(r.monto),
            texto: r.motivo || "",
            ref: r.ref_externa,
            ok: true,
            resumen: [],
            crudo: null,
          }))
        } else {
          let q = supabase
            .from("admin_actions")
            .select("id,admin_id,action,target_table,target_id,details,success,error,created_at")
            .order("created_at", { ascending: false })
            .range(from, to)

          if (ini) q = q.gte("created_at", ini)
          if (fin) q = q.lte("created_at", fin)
          if (soloFallidas) q = q.eq("success", false)
          if (t) q = q.or(`action.ilike.%${t}%,target_table.ilike.%${t}%,target_id.ilike.%${t}%`)

          const { data, error: e } = await q
          if (e) throw new Error(e.message)
          const rows = (data ?? []) as any[]
          const nombres = await nombresDe(rows.map((r) => r.admin_id))

          nuevas = rows.map((r) => ({
            id: r.id,
            cuando: r.created_at,
            // admin_id quedo anulable el 23/09 para que el cierre automatico
            // -que no lo dispara nadie- pudiera auditarse igual.
            quien: r.admin_id ? nombres[r.admin_id] || "(desconocido)" : "El sistema",
            tipo: r.action,
            etiqueta: tituloDeAccion(r.action),
            monto: null,
            // "Retiro 62cb1f1b" en vez de
            // "withdraw_requests 62cb1f1b-4f70-4fed-8135-ab78401f9521".
            texto: `${ETIQUETA_TABLA[r.target_table] || r.target_table} ${idCorto(r.target_id)}`,
            ref: null,
            ok: r.success !== false,
            // El error, si lo hubo, es lo primero que hay que leer: se cuela
            // delante del resumen en vez de quedarse en "ver todo".
            resumen: r.error
              ? [`Error: ${String(r.error)}`, ...resumirDetalles(r.details)]
              : resumirDetalles(r.details),
            crudo: r.details ? JSON.stringify(r.details, null, 2) : null,
          }))
        }

        setHayMas(nuevas.length === POR_PAGINA)
        setFilas((prev) => (pagina === 0 ? nuevas : [...prev, ...nuevas]))
      } catch (e: any) {
        setError(e?.message || "Error cargando el registro")
        if (pagina === 0) setFilas([])
      } finally {
        setLoading(false)
        setCargandoMas(false)
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [pestana, desde, hasta, texto, tipo, soloFallidas, ensureAdmin]
  )

  const [pagina, setPagina] = useState(0)

  useEffect(() => {
    setPagina(0)
    void cargar(0)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pestana, recarga])

  function cambiarPestana(p: Pestana) {
    if (p === pestana) return
    setPestana(p)
    setTipo("")
    setSoloFallidas(false)
    setFilas([])
  }

  function aplicar() {
    setRecarga((x) => x + 1)
  }

  function limpiar() {
    setDesde("")
    setHasta("")
    setTexto("")
    setTipo("")
    setSoloFallidas(false)
    setRecarga((x) => x + 1)
  }

  async function masFilas() {
    const siguiente = pagina + 1
    setPagina(siguiente)
    await cargar(siguiente)
  }

  // Exporta lo que esta cargado en pantalla, no lo que hay en la base. Se dice
  // en el boton: un CSV que promete "todo" y trae 50 filas es peor que no
  // tenerlo.
  function descargarCSV() {
    const cab = ["fecha", "quien", "tipo", "monto", "detalle", "resumen", "referencia", "ok", "crudo"]
    const esc = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`
    const cuerpo = filas.map((f) =>
      [
        formatDT(f.cuando),
        f.quien,
        f.etiqueta,
        f.monto === null ? "" : f.monto,
        f.texto,
        f.resumen.join(" | "),
        f.ref ?? "",
        f.ok ? "si" : "NO",
        // El JSON crudo va entero en el CSV aunque en pantalla este plegado:
        // quien se baja el archivo lo hace para auditar, no para ojear.
        f.crudo ?? "",
      ]
        .map(esc)
        .join(";")
    )
    // Punto y coma y BOM: es lo que abre Excel en espanol sin pedir nada.
    const csv = "\uFEFF" + [cab.map(esc).join(";"), ...cuerpo].join("\r\n")
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8;" }))
    const a = document.createElement("a")
    a.href = url
    a.download = `registro-${pestana}-${new Date().toISOString().slice(0, 10)}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-3xl">
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Registro</h1>
          <Link href="/admin" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        <div className="mt-1 text-xs text-zinc-500">
          Horas mostradas en <span className="text-zinc-400">{zona}</span>.
        </div>

        {/* PESTANAS */}
        <div className="mt-4 grid grid-cols-3 gap-2">
          {([
            ["movimientos", "Movimientos", "Dinero de los jugadores"],
            ["libro", "Libro", "Dinero de la casa"],
            ["acciones", "Acciones", "Que hizo cada admin"],
          ] as [Pestana, string, string][]).map(([clave, titulo, sub]) => (
            <button
              key={clave}
              onClick={() => cambiarPestana(clave)}
              className={`rounded-2xl border p-3 text-left ${
                pestana === clave
                  ? "bg-white text-zinc-950 border-white"
                  : "bg-zinc-900/60 text-zinc-200 border-zinc-800"
              }`}
            >
              <div className="text-sm font-semibold">{titulo}</div>
              <div className={`mt-0.5 text-[11px] ${pestana === clave ? "text-zinc-600" : "text-zinc-500"}`}>
                {sub}
              </div>
            </button>
          ))}
        </div>

        {/* FILTROS */}
        <div className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
            <div>
              <label className="text-xs text-zinc-500">Desde</label>
              <input
                type="date"
                value={desde}
                onChange={(e) => setDesde(e.target.value)}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label className="text-xs text-zinc-500">Hasta</label>
              <input
                type="date"
                value={hasta}
                onChange={(e) => setHasta(e.target.value)}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>
          </div>

          <div className="mt-2 grid grid-cols-1 sm:grid-cols-2 gap-2">
            <div>
              <label className="text-xs text-zinc-500">
                {pestana === "acciones" ? "Buscar (accion, tabla, id)" : "Buscar (detalle o referencia)"}
              </label>
              <input
                value={texto}
                onChange={(e) => setTexto(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") aplicar()
                }}
                placeholder="parte del texto"
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            {tiposDisponibles.length > 0 ? (
              <div>
                <label className="text-xs text-zinc-500">Tipo</label>
                <select
                  value={tipo}
                  onChange={(e) => setTipo(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  <option value="">Todos</option>
                  {tiposDisponibles.map((k) => (
                    <option key={k} value={k}>
                      {(pestana === "movimientos" ? ETIQUETA_MOVIMIENTO : ETIQUETA_LIBRO)[k]}
                    </option>
                  ))}
                </select>
              </div>
            ) : (
              <div className="flex items-end">
                <label className="flex items-center gap-2 text-sm text-zinc-300">
                  <input
                    type="checkbox"
                    checked={soloFallidas}
                    onChange={(e) => setSoloFallidas(e.target.checked)}
                    className="h-4 w-4"
                  />
                  Solo las que fallaron
                </label>
              </div>
            )}
          </div>

          <div className="mt-3 flex flex-wrap gap-2">
            <button
              onClick={aplicar}
              className="rounded-xl bg-white text-zinc-950 px-3 py-2 text-sm font-semibold"
            >
              Aplicar
            </button>
            <button
              onClick={limpiar}
              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
            >
              Limpiar
            </button>
            <button
              onClick={descargarCSV}
              disabled={filas.length === 0}
              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm disabled:opacity-50"
            >
              Descargar CSV ({filas.length} filas a la vista)
            </button>
          </div>
        </div>

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}

        {/* FILAS */}
        {loading ? (
          <div className="mt-6 text-sm text-zinc-400">Cargando registro...</div>
        ) : filas.length === 0 ? (
          <div className="mt-6 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-6 text-center text-sm text-zinc-400">
            No hay nada que mostrar con esos filtros.
          </div>
        ) : (
          <div className="mt-4 flex flex-col gap-2">
            {filas.map((f) => (
              <div
                key={f.id}
                className={`rounded-2xl border p-3 ${
                  f.ok ? "bg-zinc-900/60 border-zinc-800" : "bg-red-500/10 border-red-500/30"
                }`}
              >
                <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
                  <div className="text-sm font-semibold text-zinc-100">
                    {f.etiqueta}
                    {!f.ok ? <span className="ml-2 text-xs font-bold text-red-300">FALLO</span> : null}
                  </div>
                  {f.monto !== null ? (
                    <div
                      className={`text-sm font-semibold tabular-nums ${
                        f.monto < 0 ? "text-red-300" : "text-emerald-300"
                      }`}
                    >
                      {formatMoney(f.monto)} Bs
                    </div>
                  ) : null}
                </div>

                <div className="mt-1 text-xs text-zinc-400">
                  {formatDT(f.cuando)} · <span className="text-zinc-300">{f.quien}</span>
                </div>

                {f.texto ? <div className="mt-1 text-sm text-zinc-300 break-words">{f.texto}</div> : null}

                {f.ref ? (
                  <div className="mt-1 text-[11px] text-zinc-500 break-all">ref: {f.ref}</div>
                ) : null}

                {f.resumen.length > 0 ? (
                  <div className="mt-2 flex flex-wrap gap-1.5">
                    {f.resumen.map((r, i) => (
                      <span
                        key={i}
                        className={`rounded-lg border px-2 py-0.5 text-[11px] ${
                          i === 0 && !f.ok
                            ? "border-red-500/40 bg-red-500/10 text-red-200"
                            : i === 0 && r.includes("→")
                              ? "border-zinc-700 bg-zinc-950/80 text-zinc-100 font-semibold"
                              : "border-zinc-800 bg-zinc-950/60 text-zinc-400"
                        }`}
                      >
                        {r}
                      </span>
                    ))}
                  </div>
                ) : null}

                {f.crudo ? (
                  <details className="mt-2">
                    <summary className="cursor-pointer text-[11px] text-zinc-600">ver todo</summary>
                    <pre className="mt-1 whitespace-pre-wrap break-all rounded-lg bg-zinc-950/60 p-2 text-[11px] text-zinc-500">
                      {f.crudo}
                    </pre>
                  </details>
                ) : null}
              </div>
            ))}
          </div>
        )}

        {hayMas && !loading ? (
          <button
            onClick={() => void masFilas()}
            disabled={cargandoMas}
            className="mt-3 w-full rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm text-zinc-200 disabled:opacity-60"
          >
            {cargandoMas ? "Cargando..." : "Cargar mas"}
          </button>
        ) : null}

        <div className="mt-6 text-[11px] text-zinc-600">
          Esta pantalla solo lee. No suma, no deduce y no corrige nada: si alguna vez discrepa de la contabilidad, el
          que tiene razon es el libro.
        </div>
      </div>
    </main>
  )
}
