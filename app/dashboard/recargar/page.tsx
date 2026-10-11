// app/dashboard/recargar/page.tsx
"use client"

import { useEffect, useMemo, useState, type FormEvent } from "react"
import Link from "next/link"
import { supabase } from "@/lib/supabaseClient"

type DepositRow = {
  id: string
  monto: string | number
  metodo: string
  telefono_pago: string
  referencia: string
  fecha_pago: string
  estado: string
  motivo_etiqueta: string | null
  motivo_nota: string | null
  created_at: string | null
}

// ===========================================================================
//  DONDE DEPOSITA EL JUGADOR
//
//  EL DEFECTO QUE ARREGLA (11/10/2026, ADR-047). El banco, el telefono de Pago
//  Movil, la cedula y el numero de cuenta estaban escritos aqui abajo, en el
//  HTML. Un repositorio, una rama, dos despliegues: produccion y la primera
//  licencia mandaban a sus jugadores A LA MISMA CUENTA. Es la pantalla que le
//  dice a una persona donde poner su dinero.
//
//  Ahora salen de `datos_de_cobro()`, que es una lista blanca sobre
//  `ajustes_instalacion` y solo responde a quien tiene sesion -- un visitante
//  sin cuenta no deposita.
//
//  Y SI FALTAN, SE DICE. Una casa recien instalada no tiene datos de cobro.
//  Antes se inventaban (los de otro); ahora la pantalla avisa y esconde el
//  formulario. Ensenar un formulario de "ya pague" cuando no hay donde pagar
//  solo produce solicitudes que nadie puede aprobar.
// ===========================================================================
type Cobro = {
  titular: string
  documento: string
  movilBanco: string
  movilTelefono: string
  transfBanco: string
  transfTipo: string
  transfNumero: string
}

const COBRO_VACIO: Cobro = {
  titular: "", documento: "",
  movilBanco: "", movilTelefono: "",
  transfBanco: "", transfTipo: "", transfNumero: "",
}

function hayPagoMovil(c: Cobro) { return !!(c.movilBanco && c.movilTelefono) }
function hayTransferencia(c: Cobro) { return !!(c.transfBanco && c.transfNumero) }

// Se puede depositar si hay titular, documento y AL MENOS un metodo completo.
// Medio metodo no sirve: un banco sin numero de cuenta no es un sitio donde
// poner dinero.
function sePuedeDepositar(c: Cobro) {
  return !!(c.titular && c.documento) && (hayPagoMovil(c) || hayTransferencia(c))
}

function formatMoney(v: string | number) {
  const n = typeof v === "string" ? Number(v) : v
  if (!Number.isFinite(n)) return String(v)
  return n.toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

export default function RecargarPage() {
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string>("")
  const [ok, setOk] = useState<string>("")
  const [userId, setUserId] = useState<string | null>(null)

  const [monto, setMonto] = useState("")
  const [metodo, setMetodo] = useState("pago_movil")
  const [telefonoPago, setTelefonoPago] = useState("")
  const [referencia, setReferencia] = useState("")
  const [fechaPago, setFechaPago] = useState(() => {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, "0")
    const dd = String(d.getDate()).padStart(2, "0")
    return `${yyyy}-${mm}-${dd}`
  })

  const [items, setItems] = useState<DepositRow[]>([])
  const [cobro, setCobro] = useState<Cobro>(COBRO_VACIO)

  const metodoLabel = useMemo(() => {
    if (metodo === "pago_movil") return "Pago Móvil"
    return metodo
  }, [metodo])

  async function load() {
    setLoading(true)
    setError("")
    setOk("")
    setUserId(null)
    setItems([])

    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr || !auth?.user) {
      setLoading(false)
      return
    }
    setUserId(auth.user.id)

    const { data, error: listErr } = await supabase
      .from("deposit_requests")
      .select(
        // motivo_* los escribe rechazar_recarga. Ver 20261001130000.
        "id,monto,metodo,telefono_pago,referencia,fecha_pago,estado,created_at,motivo_etiqueta,motivo_nota"
      )
      .eq("user_id", auth.user.id)
      .order("created_at", { ascending: false })
      .limit(10)

    if (listErr) setError(listErr.message)
    setItems((data ?? []) as DepositRow[])

    // Los datos de cobro de ESTA casa. Si la llamada falla no se rompe la
    // pantalla: se queda vacia y el aviso de "todavia no hay donde depositar"
    // dice la verdad -- el jugador no tiene los datos, sea por lo que sea.
    const { data: aj, error: cobroErr } = await supabase.rpc("datos_de_cobro")
    if (cobroErr) {
      console.warn("[cobro]", cobroErr.message)
      setCobro(COBRO_VACIO)
    } else {
      const m: Record<string, string> = {}
      for (const fila of (aj ?? []) as { clave: string; valor: string }[]) {
        m[fila.clave] = (fila.valor ?? "").trim()
      }
      setCobro({
        titular:       m.pago_titular        ?? "",
        documento:     m.pago_documento      ?? "",
        movilBanco:    m.pago_movil_banco    ?? "",
        movilTelefono: m.pago_movil_telefono ?? "",
        transfBanco:   m.pago_transf_banco   ?? "",
        transfTipo:    m.pago_transf_tipo    ?? "",
        transfNumero:  m.pago_transf_numero  ?? "",
      })
    }

    setLoading(false)
  }

  useEffect(() => {
    // `load()` escribe varios estados a la vez (sesion, lista de recargas y
    // datos de cobro) y es una carga inicial, no una sincronizacion con un
    // sistema externo. La alternativa limpia -- sacar cada consulta a una
    // funcion pura que devuelva su valor, como en SesionCliente.tsx -- aqui
    // serian cinco, y no compensa por una carga que corre una sola vez.
    //
    // La supresion anterior nombraba `exhaustive-deps`, que ya no salta: la
    // regla que de verdad se dispara es esta. Una supresion que apunta a la
    // regla equivocada no protege de nada y entrena a ignorarlas.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void load()
  }, [])

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError("")
    setOk("")

    const n = Number(monto)
    if (!Number.isFinite(n) || n <= 0) return setError("Monto inválido.")
    if (!telefonoPago.trim()) return setError("Teléfono de pago requerido.")
    if (!referencia.trim()) return setError("Referencia requerida.")
    if (!fechaPago) return setError("Fecha de pago requerida.")

    setSaving(true)

    const { error: rpcErr } = await supabase.rpc("solicitar_recarga", {
      p_monto: n,
      p_metodo: metodo,
      p_telefono_pago: telefonoPago.trim(),
      p_referencia: referencia.trim(),
      p_fecha_pago: fechaPago,
    })

    setSaving(false)

    if (rpcErr) return setError(rpcErr.message)

    setOk("Solicitud enviada. Queda en estado pendiente.")
    setMonto("")
    setTelefonoPago("")
    setReferencia("")
    await load()
  }

  if (loading) {
    return <div className="min-h-dvh bg-gray-950 text-gray-50 flex items-center justify-center">Cargando...</div>
  }

  if (!userId) {
    return (
      <div className="min-h-dvh bg-gray-950 text-gray-50">
        <div className="mx-auto w-full max-w-md px-4 sm:px-6 lg:px-8 py-6">
          <div className="flex items-center justify-between">
            <h1 className="text-xl font-semibold">Recargar saldo</h1>
            <Link href="/remates" className="text-sm text-gray-300 underline underline-offset-4">
              Ver remates
            </Link>
          </div>
          <div className="mt-4 rounded-2xl bg-gray-900/60 p-4 ring-1 ring-white/10 text-sm text-gray-200">
            Inicia sesión para recargar saldo.
          </div>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <Link href="/remates" className="rounded-xl bg-white text-gray-950 font-semibold py-2 text-sm text-center">
              Ver remates
            </Link>
            <Link
              href="/login"
              className="rounded-xl bg-gray-900/60 border border-gray-800 py-2 text-sm text-center text-gray-200"
            >
              Iniciar sesión
            </Link>
          </div>
          <div className="mt-2 text-center">
            <Link href="/register" className="text-xs text-gray-300 underline underline-offset-4">
              Crear cuenta
            </Link>
          </div>
        </div>
      </div>
    )
  }

  return (
    <>
      <div className="min-h-dvh bg-gray-950 text-gray-50">
        <div className="mx-auto w-full max-w-md px-4 sm:px-6 lg:px-8 py-6">
          <div className="flex items-center justify-between">
            <h1 className="text-xl font-semibold">Recargar saldo</h1>
        </div>

        <p className="mt-2 text-sm text-gray-300">
          Para recargar saldo, primero realiza el pago y luego notifícalo llenando el formulario. Un admin aprobará la
          recarga si todo está correcto.
        </p>

        {sePuedeDepositar(cobro) ? (
          <div className="mt-4 rounded-2xl bg-gray-900/60 p-4 ring-1 ring-white/10 text-sm text-gray-200 space-y-3">
            {hayPagoMovil(cobro) ? (
              <div>
                <div className="font-semibold">Pago Móvil</div>
                <div className="text-gray-300">Banco: {cobro.movilBanco}</div>
                <div className="text-gray-300">Teléfono: {cobro.movilTelefono}</div>
                <div className="text-gray-300">Cédula: {cobro.documento}</div>
              </div>
            ) : null}
            {hayTransferencia(cobro) ? (
              <div>
                <div className="font-semibold">Transferencia bancaria</div>
                <div className="text-gray-300">Banco: {cobro.transfBanco}</div>
                {cobro.transfTipo ? (
                  <div className="text-gray-300">Cuenta: {cobro.transfTipo}</div>
                ) : null}
                <div className="text-gray-300">N° de cuenta: {cobro.transfNumero}</div>
                <div className="text-gray-300">Cédula: {cobro.documento}</div>
              </div>
            ) : null}
            <div className="border-t border-white/10 pt-3 text-gray-300">
              A nombre de: <span className="text-gray-100">{cobro.titular}</span>
            </div>
          </div>
        ) : (
          <div className="mt-4 rounded-2xl bg-amber-500/10 p-4 text-sm leading-snug text-amber-200 ring-1 ring-amber-500/20">
            <div className="font-semibold">Esta casa todavía no tiene datos de cobro</div>
            <div className="mt-1 text-amber-200/80">
              No hay dónde depositar, así que no tiene sentido que envíes una solicitud. Avisa al
              administrador de la casa: los pone él, desde su panel, en un minuto.
            </div>
          </div>
        )}

        {/* Sin datos de cobro no se ensena el formulario. Un "ya pague" sin
            sitio donde pagar solo produce solicitudes que nadie puede aprobar,
            y una discusion despues. */}
        {sePuedeDepositar(cobro) ? (
        <form onSubmit={onSubmit} className="mt-5 space-y-3 rounded-2xl bg-gray-900/60 p-4 ring-1 ring-white/10">
          <div>
            <label className="text-sm text-gray-200">Monto (Bs)</label>
            <input
              inputMode="decimal"
              value={monto}
              onChange={(e) => setMonto(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
              placeholder="Ej: 200"
            />
          </div>

          <div>
            <label className="text-sm text-gray-200">Método</label>
            <select
              value={metodo}
              onChange={(e) => setMetodo(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
            >
              <option value="pago_movil">Pago Móvil</option>
              <option value="otro">Otro</option>
            </select>
            <p className="mt-1 text-xs text-gray-400">Actual: {metodoLabel}</p>
          </div>

          <div>
            <label className="text-sm text-gray-200">Teléfono desde donde pagaste</label>
            <input
              value={telefonoPago}
              onChange={(e) => setTelefonoPago(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
              placeholder="Ej: 0412xxxxxxx"
            />
          </div>

          <div>
            <label className="text-sm text-gray-200">Referencia</label>
            <input
              value={referencia}
              onChange={(e) => setReferencia(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
              placeholder="Ej: 123456"
            />
          </div>

          <div>
            <label className="text-sm text-gray-200">Fecha del pago</label>
            <input
              type="date"
              value={fechaPago}
              onChange={(e) => setFechaPago(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
            />
          </div>

          {error ? (
            <div className="rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">{error}</div>
          ) : null}
          {ok ? (
            <div className="rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
              {ok}
            </div>
          ) : null}

          <button
            type="submit"
            disabled={saving}
            className="w-full rounded-xl bg-white px-4 py-2 text-base font-semibold text-gray-950 disabled:opacity-60"
          >
            {saving ? "Enviando..." : "Enviar solicitud"}
          </button>
        </form>
        ) : null}

        <div className="mt-6">
          <h2 className="text-base font-semibold">Tus últimas solicitudes</h2>

          {loading ? (
            <p className="mt-2 text-sm text-gray-400">Cargando...</p>
          ) : items.length === 0 ? (
            <p className="mt-2 text-sm text-gray-400">Aún no tienes solicitudes.</p>
          ) : (
            <div className="mt-3 space-y-2">
              {items.map((it) => (
                <div key={it.id} className="rounded-2xl bg-gray-900/50 p-3 ring-1 ring-white/10">
                  <div className="flex items-center justify-between">
                    <div className="text-sm font-semibold">Bs {formatMoney(it.monto)}</div>
                    <div className="text-xs text-gray-300">{it.estado}</div>
                    {String(it.estado).toLowerCase().includes("rech") && it.motivo_etiqueta ? (
                      <div className="mt-2 rounded-xl bg-red-500/10 p-2 ring-1 ring-red-500/20">
                        <div className="text-[11px] font-semibold text-red-100">
                          {it.motivo_etiqueta}
                        </div>
                        {it.motivo_nota ? (
                          <div className="mt-0.5 text-[11px] text-red-100/80">{it.motivo_nota}</div>
                        ) : null}
                      </div>
                    ) : null}
                  </div>
                  <div className="mt-1 text-xs text-gray-400">
                    Ref: {it.referencia} - Fecha: {it.fecha_pago}
                  </div>
                  {it.created_at ? (
                    <div className="mt-1 text-[11px] text-gray-500">
                      Creado: {new Date(it.created_at).toLocaleString("es-VE")}
                    </div>
                  ) : null}
                </div>
              ))}
            </div>
          )}
        </div>
        </div>
      </div>
    </>
  )
}
