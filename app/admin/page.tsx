"use client"

// ===========================================================================
//  ADMIN/PAGE.TSX  -  ESTADO DE LA CASA
//
//  QUE ERA ESTO ANTES, Y POR QUE DEJO DE SERVIR (10/10/2026)
//
//  Era el menu. 166 lineas, de las cuales un bloque "Acciones" con OCHO
//  enlaces. Los ocho estan hoy en la barra lateral, asi que al entrar aqui se
//  veia el menu DOS VECES en la misma pantalla: a la izquierda en la barra y
//  otra vez en el medio en forma de botones.
//
//  Y la copia del medio ya estaba desactualizada: la barra lleva 9 destinos y
//  el bloque llevaba 7. Faltaban Usuarios y Soporte, que nacieron despues.
//  Nadie se acuerda de actualizar dos listas de lo mismo -- es el ADR-015 otra
//  vez, en la navegacion.
//
//  Hasta ayer `/admin` ERA el unico sitio donde existia la lista de destinos,
//  asi que el menu aqui estaba justificado. Desde ADR-040 la lista esta en
//  todas las pantallas, y lo que queda por responder aqui es otra pregunta:
//  **como esta la casa ahora mismo**.
//
//  LOS TRES BLOQUES, EN ESTE ORDEN Y POR ESTE MOTIVO
//
//   1. COLA DE TRABAJO. Lo primero, porque es lo unico que exige una accion
//      HOY. Jota: "un retiro pendiente no deberia ser tal cosa por mucho
//      tiempo, de hecho eso deberia ser cuestion de minutos". Si eso es
//      cierto, la cifra importante NO es el monto: es la ANTIGUEDAD del mas
//      viejo. "2 retiros pendientes" no dice nada; "2 retiros, el mas viejo
//      hace 3 horas" dice que la casa esta operando mal, y un jugador que
//      espera un pago tres dias no vuelve y lo cuenta.
//
//   2. BALANCE. Cuanto hay, cuanto se debe y si lo uno cubre lo otro.
//
//   3. RESULTADO. De donde salio lo que hay.
//
//  DE DONDE SALE CADA CIFRA. De la base, siempre. Esta pantalla NO HACE NI UNA
//  SUMA DE DINERO: pinta lo que devuelven `casa_resumen()` y
//  `admin_contabilidad_resumen()`, que son las dos funciones que ya usa
//  /admin/contabilidad. Si esta pantalla calculara, tendriamos dos sitios
//  diciendo cuanto debe la casa y acabarian discrepando (ADR-015), y encima
//  haria aritmetica de dinero en JavaScript, que es el defecto que ADR-035
//  cerro a base de centimos enteros.
//
//  EL "DEBE" DISCRIMINADO, QUE ES LO QUE JOTA PIDIO. Y resulta que no hacia
//  falta tocar la base: `casa_resumen()` da `obligaciones` sumado, pero
//  `admin_contabilidad_resumen()` ya devuelve las DOS mitades por separado y
//  con la misma definicion exacta:
//
//    saldo_usuarios     = sum(saldo_disponible + saldo_bloqueado) de wallets
//    retiros_pendientes = sum(monto) de withdraw_requests pendientes
//
//  Son los mismos dos CTEs que `casa_resumen` suma en `obligaciones`. Las dos
//  naturalezas son distintas y por eso importa verlas aparte: los saldos son
//  FLOTANTE -- dinero del jugador que puede que nunca pida -- y los retiros
//  pendientes son PAGOS QUE HAY QUE HACER YA. Una sola cifra esconde la parte
//  urgente, y con ella el dueno no sabe si puede retirar utilidades o si tiene
//  que dejar dinero quieto para manana.
//
//  LAS RECARGAS PENDIENTES NO ESTAN EN EL BALANCE, Y ES CORRECTO. Una recarga
//  pendiente no es dinero: no esta en caja (`casa_resumen` solo cuenta las
//  'aprobado') ni en obligaciones (la cartera no se acredita hasta aprobar).
//  Es una promesa del jugador. Va en la cola de trabajo, que es lo que es.
//
//  Un retiro pendiente SI es deuda, y la mas urgente: `solicitar_retiro` ya le
//  desconto el saldo al jugador al pedirlo (20261006110000), asi que la casa
//  ya tiene ese dinero fuera de la cuenta del jugador y todavia no lo ha
//  entregado. Por eso entra en `obligaciones` -- y por eso no hay doble conteo
//  con los saldos.
//
//  LO QUE TODAVIA NO SE PUEDE, DICHO AQUI PARA QUE NO SE BUSQUE EN VANO.
//  Las ganancias por remates salen en UNA cifra. Separar la comision de los
//  pozos que gano la casa completa necesita una migracion: el reparto existe
//  dentro de `admin_contabilidad_resumen` (el CTE `calc` ya distingue
//  `ganador_user_id is null` -> pozo entero, si no -> pozo * pct/100) pero sale
//  sumado en `remates_casa_total`. Son dos claves mas en el jsonb, sin cambio
//  de tipo de retorno. Esta en PENDIENTES, bloque post-licenciamiento.
//
//  EL RELOJ. La antiguedad se calcula con el reloj del NAVEGADOR contra
//  `created_at`. Si el admin tiene la hora desajustada, el numero miente. Es
//  el mismo defecto ya anotado para la ventana del remate. Para un indicador
//  de cola es tolerable; para decidir dinero no se usaria.
// ===========================================================================

import { useCallback, useEffect, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"
import { useCajaEnVivo } from "./CajaEnVivo"

// Cuando una cola deja de ser normal. Jota: "deberia ser cuestion de minutos,
// no de horas ni mucho menos dias". Estos dos numeros son la traduccion de esa
// frase y se cambian AQUI, en un solo sitio.
const AVISO_MIN = 15
const URGENTE_MIN = 60

function n(v: unknown) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function bs(v: unknown) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

/** "hace 14 min", "hace 3 h", "hace 2 d". Null si no hay nada esperando. */
function antiguedad(desde: string | null): { texto: string; minutos: number } | null {
  if (!desde) return null
  const t = new Date(desde).getTime()
  if (Number.isNaN(t)) return null
  const min = Math.max(0, Math.floor((Date.now() - t) / 60000))
  if (min < 60) return { texto: `hace ${min} min`, minutos: min }
  if (min < 60 * 24) return { texto: `hace ${Math.floor(min / 60)} h`, minutos: min }
  return { texto: `hace ${Math.floor(min / 1440)} d`, minutos: min }
}

type Casa = {
  caja_total: number
  obligaciones: number
  patrimonio: number
  capital_aportado: number
  utilidades_retiradas: number
  ajustes: number
  resultado_operativo: number
  pendiente_de_liquidar: number
  descuadre_inexplicado: number
  remates_sin_liquidar: number
  cubierto: boolean
}

type Contab = {
  saldo_usuarios: number
  retiros_pendientes: number
  recargas_pendientes: number
  remates_casa_total: number
  remates_liquidados: number
}

export default function AdminHomePage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState("")
  const [casa, setCasa] = useState<Casa | null>(null)
  const [contab, setContab] = useState<Contab | null>(null)
  const [viejaRecarga, setViejaRecarga] = useState<string | null>(null)
  const [viejoRetiro, setViejoRetiro] = useState<string | null>(null)

  // LOS CONTADORES NO SON ESTADO DE ESTA PANTALLA (05/10/2026).
  //
  // Antes se leian una vez al montar y ahi se quedaban: un admin parado aqui
  // -- que es donde se queda esperando -- no se enteraba de una solicitud
  // nueva hasta recargar. Jota: "si el realtime funciona solamente dentro de
  // /recargas - /retiros, entonces eso es practicamente como que no existiera
  // ningun realtime". Ahora vienen del layout, que mantiene UNA suscripcion
  // viva para todo el panel; `version` sube con cada senal.
  const { recargasPendientes, retirosPendientes, refrescar, version } = useCajaEnVivo()

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

  const load = useCallback(
    async (esRefresco = false) => {
      if (esRefresco) setRefreshing(true)
      else setLoading(true)
      setError("")

      try {
        const adminId = await ensureAdmin()
        if (!adminId) return

        // Contar los pendientes es trabajo del layout, que es quien escucha el
        // canal. Contarlos tambien aqui serian dos fuentes del mismo numero.
        refrescar()

        const { data: cData, error: cErr } = await supabase.rpc("casa_resumen")
        if (cErr) throw new Error(cErr.message)
        const c = Array.isArray(cData) ? cData[0] : cData
        setCasa(
          c
            ? {
                caja_total: n(c.caja_total),
                obligaciones: n(c.obligaciones),
                patrimonio: n(c.patrimonio),
                capital_aportado: n(c.capital_aportado),
                utilidades_retiradas: n(c.utilidades_retiradas),
                ajustes: n(c.ajustes),
                resultado_operativo: n(c.resultado_operativo),
                pendiente_de_liquidar: n(c.pendiente_de_liquidar),
                descuadre_inexplicado: n(c.descuadre_inexplicado),
                remates_sin_liquidar: Number(c.remates_sin_liquidar ?? 0),
                cubierto: !!c.cubierto,
              }
            : null
        )

        // Las dos mitades del "Debe", y los montos de la cola. Esta funcion
        // devuelve jsonb, no tabla.
        const { data: rData, error: rErr } = await supabase.rpc("admin_contabilidad_resumen")
        if (rErr) throw new Error(rErr.message)
        const r = (rData ?? null) as Record<string, unknown> | null
        setContab(
          r
            ? {
                saldo_usuarios: n(r.saldo_usuarios),
                retiros_pendientes: n(r.retiros_pendientes),
                recargas_pendientes: n(r.recargas_pendientes),
                remates_casa_total: n(r.remates_casa_total),
                remates_liquidados: Number(r.remates_liquidados ?? 0),
              }
            : null
        )

        // El mas viejo de cada cola. Una fila cada uno, no la tabla entera.
        const dep = await supabase
          .from("deposit_requests")
          .select("created_at")
          .eq("estado", "pendiente")
          .order("created_at", { ascending: true })
          .limit(1)
          .maybeSingle()
        setViejaRecarga((dep.data?.created_at as string | null) ?? null)

        const wit = await supabase
          .from("withdraw_requests")
          .select("created_at")
          .eq("estado", "pendiente")
          .order("created_at", { ascending: true })
          .limit(1)
          .maybeSingle()
        setViejoRetiro((wit.data?.created_at as string | null) ?? null)
      } catch (e) {
        setError(e instanceof Error ? e.message : "Error cargando el estado de la casa")
      } finally {
        setLoading(false)
        setRefreshing(false)
      }
    },
    [ensureAdmin, refrescar]
  )

  useEffect(() => {
    void load(false)
  }, [load])

  // Llega una recarga o un retiro mientras el admin mira esta pantalla: las
  // cifras se vuelven a pedir. Sin esto, el contador de la barra subiria y el
  // monto de aqui se quedaria viejo.
  useEffect(() => {
    if (version === 0) return
    void load(true)
  }, [version, load])

  if (loading) {
    return <div className="min-h-[60vh] flex items-center justify-center text-zinc-50">Cargando estado de la casa...</div>
  }

  const edadRecarga = antiguedad(viejaRecarga)
  const edadRetiro = antiguedad(viejoRetiro)

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 sm:px-6 lg:px-8 py-6">
      <div className="mx-auto w-full max-w-5xl">
        <h1 className="text-xl font-bold">Estado de la casa</h1>
        <p className="mt-1 text-xs text-zinc-500">
          Todas las cifras las da la base. Esta pantalla no calcula dinero.
        </p>

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}

        {/* ---------------------------------------------------------------
            1 · COLA DE TRABAJO
            --------------------------------------------------------------- */}
        <section className="mt-5">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-semibold text-zinc-300">Cola de trabajo</h2>
            <button
              onClick={() => void load(true)}
              disabled={refreshing}
              className="rounded-lg border border-zinc-800 bg-zinc-900/60 px-3 py-1 text-xs text-zinc-200 disabled:opacity-60"
            >
              {refreshing ? "Actualizando..." : "Actualizar"}
            </button>
          </div>

          <div className="mt-2 grid gap-2 sm:grid-cols-2">
            <ColaCard
              href="/admin/recargas"
              titulo="Recargas por aprobar"
              cuantas={recargasPendientes}
              monto={contab ? contab.recargas_pendientes : null}
              edad={edadRecarga}
              nota="No es dinero de la casa todavia: la cartera no se acredita hasta aprobar."
            />
            <ColaCard
              href="/admin/retiros"
              titulo="Retiros por pagar"
              cuantas={retirosPendientes}
              monto={contab ? contab.retiros_pendientes : null}
              edad={edadRetiro}
              nota="Ya descontado del saldo del jugador. Es deuda en firme."
            />
          </div>
        </section>

        {/* ---------------------------------------------------------------
            2 · BALANCE
            --------------------------------------------------------------- */}
        <section className="mt-6">
          <h2 className="text-sm font-semibold text-zinc-300">Balance</h2>

          <div className="mt-2 grid gap-2 sm:grid-cols-3">
            <Cifra titulo="Caja" valor={casa ? bs(casa.caja_total) : "—"} sufijo="Bs" tono="neutro" />
            <Cifra titulo="Se debe" valor={casa ? bs(casa.obligaciones) : "—"} sufijo="Bs" tono="aviso" />
            <Cifra
              titulo="Patrimonio"
              valor={casa ? bs(casa.patrimonio) : "—"}
              sufijo="Bs"
              tono={casa && casa.patrimonio < 0 ? "malo" : "bueno"}
            />
          </div>

          {/* El desglose del "Debe", que es lo que no se podia ver. Las dos
              cifras salen de la base por separado; aqui no se suma nada. */}
          <div className="mt-2 rounded-2xl border border-zinc-800 bg-zinc-900/60 p-4">
            <div className="text-xs font-semibold text-zinc-400">De qué se compone lo que se debe</div>
            <div className="mt-3 space-y-2">
              <Linea
                etiqueta="Saldos de jugadores"
                valor={contab ? bs(contab.saldo_usuarios) : "—"}
                nota="Flotante: dinero que tienen y puede que nunca pidan."
              />
              <Linea
                etiqueta="Retiros por pagar"
                valor={contab ? bs(contab.retiros_pendientes) : "—"}
                nota="Urgente: pagos ya comprometidos."
                destacar
              />
            </div>
          </div>

          <div
            className={`mt-2 rounded-xl p-3 text-sm ring-1 ${
              casa?.cubierto
                ? "bg-emerald-500/10 text-emerald-200 ring-emerald-500/20"
                : "bg-red-500/10 text-red-200 ring-red-500/20"
            }`}
          >
            {casa?.cubierto
              ? "La caja cubre todo lo que se debe."
              : "La caja NO cubre lo que se debe. Revisa la contabilidad antes de liquidar o pagar."}
          </div>
        </section>

        {/* ---------------------------------------------------------------
            3 · RESULTADO
            --------------------------------------------------------------- */}
        <section className="mt-6">
          <h2 className="text-sm font-semibold text-zinc-300">Resultado</h2>

          <div className="mt-2 rounded-2xl border border-zinc-800 bg-zinc-900/60 p-4">
            <div className="space-y-2">
              <Linea
                etiqueta="Ganancias por remates"
                valor={casa ? bs(casa.resultado_operativo) : "—"}
                nota={
                  contab
                    ? `${contab.remates_liquidados} remates liquidados. Todavia sin separar comisión de pozos ganados por la casa.`
                    : "Todavia sin separar comisión de pozos ganados por la casa."
                }
              />
              <Linea etiqueta="Capital aportado" valor={casa ? bs(casa.capital_aportado) : "—"} />
              <Linea etiqueta="Utilidades retiradas" valor={casa ? bs(casa.utilidades_retiradas) : "—"} />
              {casa && casa.ajustes !== 0 ? (
                <Linea etiqueta="Ajustes" valor={bs(casa.ajustes)} />
              ) : null}
            </div>
          </div>

          {casa && casa.remates_sin_liquidar > 0 ? (
            <Link
              href="/admin/remates"
              className="mt-2 block rounded-xl bg-amber-500/10 p-3 text-sm text-amber-200 ring-1 ring-amber-500/20"
            >
              {casa.remates_sin_liquidar === 1
                ? "1 remate cerrado sin liquidar"
                : `${casa.remates_sin_liquidar} remates cerrados sin liquidar`}
              {casa.pendiente_de_liquidar !== 0 ? ` · ${bs(casa.pendiente_de_liquidar)} Bs sin asiento` : ""}
            </Link>
          ) : null}

          {/* El descuadre solo aparece cuando hay descuadre. Un cero permanente
              en pantalla se vuelve invisible, y el dia que deje de ser cero
              nadie lo va a notar. */}
          {casa && Math.abs(casa.descuadre_inexplicado) >= 0.01 ? (
            <Link
              href="/admin/contabilidad"
              className="mt-2 block rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20"
            >
              Descuadre sin explicar: {bs(casa.descuadre_inexplicado)} Bs. Abrir contabilidad.
            </Link>
          ) : null}
        </section>
      </div>
    </main>
  )
}

/* -------------------------------------------------------------------------
   Piezas de pintura. Viven aqui y no en components/ porque solo las usa esta
   pantalla; el dia que las use otra, se mudan.
   ------------------------------------------------------------------------- */

function ColaCard({
  href,
  titulo,
  cuantas,
  monto,
  edad,
  nota,
}: {
  href: string
  titulo: string
  cuantas: number
  monto: number | null
  edad: { texto: string; minutos: number } | null
  nota: string
}) {
  const vacia = cuantas === 0
  const urgente = !!edad && edad.minutos >= URGENTE_MIN
  const aviso = !!edad && edad.minutos >= AVISO_MIN && !urgente

  const anillo = vacia
    ? "border-zinc-800 bg-zinc-900/60"
    : urgente
    ? "border-red-500/40 bg-red-500/10"
    : aviso
    ? "border-amber-500/40 bg-amber-500/10"
    : "border-zinc-800 bg-zinc-900/60"

  return (
    <Link href={href} className={`block rounded-2xl border p-4 ${anillo}`}>
      <div className="text-xs text-zinc-400">{titulo}</div>
      <div className="mt-1 flex items-baseline gap-2">
        <span
          className={`text-2xl font-semibold tabular-nums ${
            vacia ? "text-zinc-500" : urgente ? "text-red-300" : "text-amber-300"
          }`}
        >
          {cuantas}
        </span>
        {!vacia && monto !== null ? (
          <span className="text-sm text-zinc-300 tabular-nums">{bs(monto)} Bs</span>
        ) : null}
      </div>
      {/* La antiguedad es la cifra que de verdad dice si la casa va bien. */}
      <div className="mt-1 text-xs">
        {vacia ? (
          <span className="text-zinc-500">Nada esperando</span>
        ) : edad ? (
          <span className={urgente ? "font-semibold text-red-300" : aviso ? "text-amber-300" : "text-zinc-400"}>
            El más viejo, {edad.texto}
          </span>
        ) : (
          <span className="text-zinc-500">&nbsp;</span>
        )}
      </div>
      <div className="mt-2 text-[11px] leading-snug text-zinc-500">{nota}</div>
    </Link>
  )
}

function Cifra({
  titulo,
  valor,
  sufijo,
  tono,
}: {
  titulo: string
  valor: string
  sufijo?: string
  tono: "neutro" | "bueno" | "malo" | "aviso"
}) {
  const color =
    tono === "bueno"
      ? "text-emerald-300"
      : tono === "malo"
      ? "text-red-300"
      : tono === "aviso"
      ? "text-amber-300"
      : "text-zinc-100"

  return (
    <div className="rounded-2xl border border-zinc-800 bg-zinc-900/60 p-4">
      <div className="text-xs text-zinc-400">{titulo}</div>
      <div className={`mt-1 text-xl font-semibold tabular-nums ${color}`}>
        {valor}
        {sufijo ? <span className="ml-1 text-xs font-normal text-zinc-500">{sufijo}</span> : null}
      </div>
    </div>
  )
}

function Linea({
  etiqueta,
  valor,
  nota,
  destacar = false,
}: {
  etiqueta: string
  valor: string
  nota?: string
  destacar?: boolean
}) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div className="min-w-0">
        <div className={`text-sm ${destacar ? "font-semibold text-amber-200" : "text-zinc-200"}`}>{etiqueta}</div>
        {nota ? <div className="text-[11px] leading-snug text-zinc-500">{nota}</div> : null}
      </div>
      <div className={`shrink-0 text-sm tabular-nums ${destacar ? "font-semibold text-amber-200" : "text-zinc-100"}`}>
        {valor} <span className="text-xs font-normal text-zinc-500">Bs</span>
      </div>
    </div>
  )
}
