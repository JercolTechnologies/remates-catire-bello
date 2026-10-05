// ADMIN/PAGE.TSX

"use client"

import { useEffect, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"
import { useCajaEnVivo } from "./CajaEnVivo"

export default function AdminHomePage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState("")

  // LOS CONTADORES YA NO SON ESTADO DE ESTA PANTALLA (05/10/2026).
  //
  // Antes se leian una vez al montar y ahi se quedaban. Un admin parado en
  // este panel -- que es precisamente donde se queda esperando -- no se
  // enteraba de una solicitud nueva hasta recargar la pagina. Jota lo dijo
  // asi: "si el realtime funciona solamente dentro de /recargas - /retiros,
  // entonces eso es practicamente como que no existiera ningun realtime".
  //
  // Ahora vienen del layout de /admin, que mantiene UNA suscripcion viva para
  // todo el panel. El boton "Actualizar" los vuelve a pedir, pero ya no hace
  // falta tocarlo para que se muevan.
  const { recargasPendientes, retirosPendientes, refrescar } = useCajaEnVivo()

  async function ensureAdmin() {
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
  }

  async function load(isRefresh = false) {
    if (isRefresh) setRefreshing(true)
    else setLoading(true)

    setError("")

    try {
      const adminId = await ensureAdmin()
      if (!adminId) return

      // Contar es trabajo del layout, que es quien escucha el canal. Si se
      // contara tambien aqui habria dos fuentes del mismo numero y podrian
      // discrepar -- el mismo defecto de fondo que el ADR-015, en pequeno.
      refrescar()
    } catch (e: any) {
      setError(e?.message || "Error cargando panel admin")
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }

  useEffect(() => {
    void load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando admin...</div>
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-md">
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Panel Admin</h1>
          <Link href="/dashboard" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}

        <div className="mt-4 grid grid-cols-2 gap-2">
          <Link href="/admin/recargas" className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <div className="text-xs text-zinc-500">Recargas pendientes</div>
            <div className="mt-1 text-2xl font-semibold text-amber-300">{recargasPendientes}</div>
            <div className="mt-2 text-xs text-zinc-300 underline underline-offset-4">Abrir</div>
          </Link>

          <Link href="/admin/retiros" className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <div className="text-xs text-zinc-500">Retiros pendientes</div>
            <div className="mt-1 text-2xl font-semibold text-amber-300">{retirosPendientes}</div>
            <div className="mt-2 text-xs text-zinc-300 underline underline-offset-4">Abrir</div>
          </Link>
        </div>

        <button
          onClick={() => void load(true)}
          disabled={refreshing}
          className="mt-3 w-full rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm text-zinc-200 disabled:opacity-60"
        >
          {refreshing ? "Actualizando..." : "Actualizar"}
        </button>

        <div className="mt-6 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="text-sm font-semibold">Acciones</div>

          <div className="mt-3 flex flex-col gap-2">
            <Link href="/admin/crear-remate" className="rounded-xl bg-white text-zinc-950 px-3 py-2 text-sm font-semibold">
              Crear remate rapido
            </Link>

            <Link href="/admin/recargas" className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm">
              Gestionar recargas
            </Link>

            <Link href="/admin/retiros" className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm">
              Gestionar retiros
            </Link>

            <Link href="/admin/remates" className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm">
              Gestionar remates (cerrar / liquidar)
            </Link>

            <Link
              href="/admin/contabilidad"
              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
            >
              Contabilidad
            </Link>

            <Link href="/admin/log" className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm">
              Registro (movimientos, libro y acciones)
            </Link>

            <Link href="/remates" className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm">
              Ir a remates
            </Link>
          </div>

        <div className="mt-3 text-xs text-zinc-500">Gestiona y opera remates desde este panel.</div>
      </div>
      </div>
    </main>
  )
}
