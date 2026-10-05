// ADMIN/SUPER/ADMINS/PAGE.TSX
//
// QUIEN PUEDE OPERAR LA CAJA, Y CON QUE NOMBRE
//
// Hasta hoy no habia forma de nombrar un administrador desde la aplicacion:
// `set_admin` existia en la base desde el principio pero estaba revocada y no
// la llamaba ninguna pantalla. Se hacia a mano contra la base, o no se hacia.
//
// COMO NACE UN ADMIN AQUI: la persona se registra como cualquier jugador y un
// super admin la promueve. No hay creacion de usuarios desde esta pantalla, y
// es a proposito: crear un usuario exige la clave `service_role` de Supabase,
// que es acceso total por encima de toda la RLS, y habria que configurarla en
// cada instalacion de licenciatario. Un secreto que se reparte N veces se
// filtra una vez. Ver la migracion 20261005120000.
//
// Solo super admins. La guarda de verdad esta en la base -- las cuatro RPC
// comprueban `es_super_admin` ellas mismas -- y esto solo evita enseñar una
// pantalla que no va a funcionar.

"use client"

import { useCallback, useEffect, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type AdminRow = {
  user_id: string
  username: string | null
  correo: string | null
  admin_codigo: string | null
  admin_nombre: string | null
  es_admin: boolean
  es_super_admin: boolean
  acciones: number
  ultima_accion: string | null
}

type Candidato = {
  user_id: string
  username: string | null
  correo: string | null
  es_admin: boolean
  es_super_admin: boolean
  admin_codigo: string | null
}

function formatDT(v: string | null) {
  if (!v) return "nunca"
  const d = new Date(v)
  return Number.isNaN(d.getTime()) ? "-" : d.toLocaleString("es-VE")
}

export default function AdminsPage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [ok, setOk] = useState("")
  const [admins, setAdmins] = useState<AdminRow[]>([])

  // buscar y promover
  const [busqueda, setBusqueda] = useState("")
  const [buscando, setBuscando] = useState(false)
  const [candidatos, setCandidatos] = useState<Candidato[]>([])
  const [elegido, setElegido] = useState<Candidato | null>(null)
  const [codigo, setCodigo] = useState("")
  const [nombre, setNombre] = useState("")
  const [esSuper, setEsSuper] = useState(false)
  const [guardando, setGuardando] = useState(false)

  // quitar
  const [quitandoId, setQuitandoId] = useState<string | null>(null)

  const cargar = useCallback(async () => {
    setError("")
    try {
      const { data: auth } = await supabase.auth.getUser()
      if (!auth?.user) {
        router.replace("/admin/login")
        return
      }
      const { data, error: e } = await supabase.rpc("listar_admins")
      if (e) throw new Error(e.message)
      setAdmins((data ?? []) as AdminRow[])
    } catch (e: any) {
      setError(e?.message || "No se pudo cargar la lista de administradores")
      setAdmins([])
    } finally {
      setLoading(false)
    }
  }, [router])

  useEffect(() => {
    void cargar()
  }, [cargar])

  async function buscar() {
    setError("")
    setOk("")
    setCandidatos([])
    setElegido(null)
    setBuscando(true)
    try {
      const { data, error: e } = await supabase.rpc("buscar_usuario_para_admin", {
        p_texto: busqueda,
      })
      if (e) throw new Error(e.message)
      const filas = (data ?? []) as Candidato[]
      setCandidatos(filas)
      if (filas.length === 0) {
        setError("Nadie coincide. Recuerda: la persona tiene que haberse registrado primero.")
      }
    } catch (e: any) {
      setError(e?.message || "Error buscando")
    } finally {
      setBuscando(false)
    }
  }

  function elegir(c: Candidato) {
    setElegido(c)
    setCodigo(c.admin_codigo || "")
    setNombre(c.username || "")
    setEsSuper(false)
    setError("")
    setOk("")
  }

  async function nombrar() {
    if (!elegido) return
    setError("")
    setOk("")
    setGuardando(true)
    try {
      const { data, error: e } = await supabase.rpc("nombrar_admin", {
        p_user_id: elegido.user_id,
        p_codigo: codigo,
        p_nombre: nombre,
        p_es_super: esSuper,
      })
      if (e) throw new Error(e.message)
      setOk(String(data ?? "Listo"))
      setElegido(null)
      setCandidatos([])
      setBusqueda("")
      setCodigo("")
      setNombre("")
      setEsSuper(false)
      await cargar()
    } catch (e: any) {
      setError(e?.message || "No se pudo nombrar")
    } finally {
      setGuardando(false)
    }
  }

  async function quitar(fila: AdminRow) {
    setError("")
    setOk("")
    setQuitandoId(fila.user_id)
    try {
      const { data, error: e } = await supabase.rpc("quitar_admin", { p_user_id: fila.user_id })
      if (e) throw new Error(e.message)
      setOk(String(data ?? "Cargo retirado"))
      await cargar()
    } catch (e: any) {
      setError(e?.message || "No se pudo quitar el cargo")
    } finally {
      setQuitandoId(null)
    }
  }

  const sinCodigo = admins.filter((a) => (a.es_admin || a.es_super_admin) && !a.admin_codigo)

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-3xl">
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Administradores</h1>
          <Link href="/admin" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        <p className="mt-1 text-xs text-zinc-500">
          Cada acción sobre el dinero queda firmada con el código y el nombre de quien la hizo. Un
          código no se reutiliza nunca, ni siquiera cuando alguien deja el cargo.
        </p>

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}
        {ok ? (
          <div className="mt-4 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
            {ok}
          </div>
        ) : null}

        {/* AVISO: un admin sin codigo firma el registro con un hueco. Se señala
            arriba porque es el estado en el que esta el super admin original
            hasta que se ponga su propio codigo. */}
        {sinCodigo.length > 0 ? (
          <div className="mt-4 rounded-2xl bg-amber-500/15 p-4 ring-1 ring-amber-500/40">
            <div className="text-sm font-bold text-amber-200">
              {sinCodigo.length === 1
                ? "Hay un administrador sin código"
                : `Hay ${sinCodigo.length} administradores sin código`}
            </div>
            <div className="mt-1 text-sm text-amber-100">
              Sus acciones quedan firmadas sin código. Búscalo abajo y ponle uno: la misma pantalla
              sirve para nombrar y para corregir.
            </div>
          </div>
        ) : null}

        {/* ------------------------------ nombrar ------------------------------ */}
        <section className="mt-5 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="text-sm font-semibold">Nombrar o corregir</div>
          <div className="mt-1 text-[11px] text-zinc-500">
            La persona tiene que haberse registrado antes en la aplicación. Busca por usuario,
            correo o teléfono.
          </div>

          <div className="mt-3 flex gap-2">
            <input
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void buscar()
              }}
              placeholder="al menos 3 caracteres"
              className="flex-1 rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
            />
            <button
              onClick={() => void buscar()}
              disabled={buscando}
              className="rounded-xl bg-white text-zinc-950 px-3 py-2 text-sm font-semibold disabled:opacity-60"
            >
              {buscando ? "Buscando..." : "Buscar"}
            </button>
          </div>

          {candidatos.length > 0 && !elegido ? (
            <div className="mt-3 flex flex-col gap-2">
              {candidatos.map((c) => (
                <button
                  key={c.user_id}
                  onClick={() => elegir(c)}
                  className="rounded-xl border border-zinc-800 bg-zinc-950/60 px-3 py-2 text-left text-sm hover:bg-zinc-900"
                >
                  <div className="font-semibold text-zinc-100">{c.username || "(sin usuario)"}</div>
                  <div className="text-[11px] text-zinc-500">
                    {c.correo}
                    {c.es_super_admin
                      ? " · ya es super admin"
                      : c.es_admin
                        ? " · ya es admin"
                        : ""}
                    {c.admin_codigo ? ` · código ${c.admin_codigo}` : ""}
                  </div>
                </button>
              ))}
            </div>
          ) : null}

          {elegido ? (
            <div className="mt-3 rounded-xl border border-zinc-800 bg-zinc-950/60 p-3">
              <div className="text-sm font-semibold text-zinc-100">
                {elegido.username || "(sin usuario)"}
              </div>
              <div className="text-[11px] text-zinc-500">{elegido.correo}</div>

              <div className="mt-3 grid grid-cols-1 sm:grid-cols-2 gap-2">
                <div>
                  <label className="text-xs text-zinc-500">Código (2 a 6, letras y números)</label>
                  <input
                    value={codigo}
                    onChange={(e) => setCodigo(e.target.value.toUpperCase())}
                    maxLength={6}
                    placeholder="C01"
                    className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm uppercase"
                  />
                </div>
                <div>
                  <label className="text-xs text-zinc-500">Nombre visible</label>
                  <input
                    value={nombre}
                    onChange={(e) => setNombre(e.target.value)}
                    placeholder="María Pérez"
                    className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  />
                </div>
              </div>

              <label className="mt-3 flex items-center gap-2 text-sm text-zinc-300">
                <input
                  type="checkbox"
                  checked={esSuper}
                  onChange={(e) => setEsSuper(e.target.checked)}
                  className="h-4 w-4"
                />
                También super admin (puede nombrar y quitar administradores)
              </label>

              <div className="mt-3 flex gap-2">
                <button
                  onClick={() => void nombrar()}
                  disabled={guardando}
                  className="rounded-xl bg-white text-zinc-950 px-3 py-2 text-sm font-semibold disabled:opacity-60"
                >
                  {guardando ? "Guardando..." : "Nombrar"}
                </button>
                <button
                  onClick={() => setElegido(null)}
                  className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  Cancelar
                </button>
              </div>
            </div>
          ) : null}
        </section>

        {/* ------------------------------ la lista ------------------------------ */}
        <section className="mt-5">
          <div className="text-sm font-semibold">Quién puede operar</div>

          {loading ? (
            <div className="mt-3 text-sm text-zinc-400">Cargando...</div>
          ) : admins.length === 0 ? (
            <div className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-6 text-center text-sm text-zinc-400">
              No hay nadie todavía.
            </div>
          ) : (
            <div className="mt-3 flex flex-col gap-2">
              {admins.map((a) => {
                const activo = a.es_admin || a.es_super_admin
                return (
                  <div
                    key={a.user_id}
                    className={`rounded-2xl border p-3 ${
                      activo ? "bg-zinc-900/60 border-zinc-800" : "bg-zinc-900/30 border-zinc-900"
                    }`}
                  >
                    <div className="flex flex-wrap items-baseline justify-between gap-2">
                      <div className="text-sm font-semibold text-zinc-100">
                        {a.admin_codigo ? (
                          <span className="mr-2 rounded-md bg-zinc-800 px-1.5 py-0.5 text-xs font-mono">
                            {a.admin_codigo}
                          </span>
                        ) : null}
                        {a.admin_nombre || a.username || "(sin nombre)"}
                        {a.es_super_admin ? (
                          <span className="ml-2 text-xs font-bold text-amber-300">SUPER</span>
                        ) : null}
                        {!activo ? (
                          <span className="ml-2 text-xs text-zinc-500">(ya no opera)</span>
                        ) : null}
                      </div>
                      {activo ? (
                        <button
                          onClick={() => void quitar(a)}
                          disabled={quitandoId === a.user_id}
                          className="rounded-lg border border-zinc-700 px-2 py-1 text-xs text-zinc-300 hover:bg-zinc-800 disabled:opacity-60"
                        >
                          {quitandoId === a.user_id ? "Quitando..." : "Quitar cargo"}
                        </button>
                      ) : null}
                    </div>

                    <div className="mt-1 text-xs text-zinc-500">
                      {a.correo} · {a.acciones} {a.acciones === 1 ? "acción" : "acciones"} · última:{" "}
                      {formatDT(a.ultima_accion)}
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </section>

        <div className="mt-6 text-[11px] text-zinc-600">
          Nadie puede quitarse el cargo a sí mismo, y siempre tiene que quedar al menos un super
          admin. Las dos guardas están en la base, no aquí.
        </div>
      </div>
    </main>
  )
}
