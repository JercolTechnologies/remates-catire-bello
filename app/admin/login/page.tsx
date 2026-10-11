// app/admin/login/page.tsx
"use client"

// ===========================================================================
//  DOS FASES: ENTRAR, Y -- SOLO LA PRIMERA VEZ DE UNA INSTALACION -- FUNDAR
//
//  QUE CAMBIO (10/10/2026, pendiente 5.3)
//
//  Hasta hoy el primer administrador de una instalacion nueva se creaba con un
//  UPDATE a mano que hacia JERCOL dentro de la base del cliente. La base que
//  va a tener el dinero de sus jugadores. Lo mejor que le puede pasar al
//  proveedor del software es NO PODER entrar ahi.
//
//  Ahora lo hace el dueno, desde aqui, y la base pone los dos candados:
//  solo si no hay ningun super admin todavia, y solo si su correo coincide con
//  el que quedo designado al instalar. Ver 20261010193000 y P73.
//
//  EL DETALLE QUE IMPORTA: AQUI NO SE CIERRA LA SESION.
//
//  El flujo de siempre, si entras y no eres admin, hace `signOut()` y te
//  echa. Eso es correcto cuando la casa ya tiene dueno -- y es exactamente lo
//  que NO puede pasar cuando no lo tiene, porque `fundar_super_admin()` actua
//  sobre QUIEN LA LLAMA y necesita la sesion viva. Si cerraramos sesion antes
//  de ofrecer fundar, el formulario de fundacion no podria funcionar nunca.
//
//  POR QUE SE PREGUNTA ANTES DE QUE NADIE ESCRIBA NADA. `casa_fundada()` la
//  lee `anon` justamente para esto: la pantalla tiene que saber que ofrecer
//  ANTES de pedir credenciales. Lo unico que revela es si hay dueno o no --
//  nunca el correo designado, que es lo que hay que proteger.
// ===========================================================================

import { useEffect, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

export default function AdminLoginPage() {
  const router = useRouter()
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState("")

  // null = todavia no sabemos. Hasta saberlo no se decide que ofrecer.
  const [fundada, setFundada] = useState<boolean | null>(null)
  const [fase, setFase] = useState<"entrar" | "fundar">("entrar")

  const [codigo, setCodigo] = useState("")
  const [nombre, setNombre] = useState("")

  useEffect(() => {
    let vivo = true
    void (async () => {
      const { data, error: e } = await supabase.rpc("casa_fundada")
      if (!vivo) return
      // Ante la duda, se asume fundada: ofrecer fundar una casa que ya tiene
      // dueno confunde; no ofrecerlo en una que no lo tiene solo obliga a
      // preguntar. El error menos malo es el segundo.
      setFundada(e ? true : data === true)
    })()
    return () => {
      vivo = false
    }
  }, [])

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault()
    setError("")
    setLoading(true)

    const { data, error: loginErr } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password: password.trim(),
    })

    if (loginErr) {
      setLoading(false)
      return setError(loginErr.message)
    }

    const userId = data.user?.id
    if (!userId) {
      setLoading(false)
      return setError("Sesion invalida.")
    }

    const { data: prof, error: pErr } = await supabase
      .from("profiles")
      .select("es_admin,es_super_admin")
      .eq("id", userId)
      .maybeSingle()

    if (pErr) {
      await supabase.auth.signOut()
      setLoading(false)
      return setError(pErr.message)
    }

    if (prof?.es_admin || prof?.es_super_admin) {
      setLoading(false)
      return router.replace("/admin")
    }

    // No es admin. Si la casa NO tiene dueno, puede que sea el designado: se
    // le ofrece fundar y SE MANTIENE LA SESION, que es lo que necesita la RPC.
    if (fundada === false) {
      setLoading(false)
      return setFase("fundar")
    }

    await supabase.auth.signOut()
    setLoading(false)
    setError("No autorizado. Esta ruta es solo para administradores.")
  }

  async function handleFundar(e: React.FormEvent) {
    e.preventDefault()
    setError("")
    setLoading(true)

    const { data, error: rpcErr } = await supabase.rpc("fundar_super_admin", {
      p_codigo: codigo.trim().toUpperCase(),
      p_nombre: nombre.trim(),
    })

    if (rpcErr) {
      setLoading(false)
      // Los mensajes de la base ya estan escritos para que los lea una
      // persona. No se traducen aqui: seria un segundo sitio donde mantener
      // el mismo texto (ADR-015).
      return setError(rpcErr.message)
    }

    setLoading(false)
    console.info(typeof data === "string" ? data : "Casa fundada.")
    router.replace("/admin")
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 sm:px-6 lg:px-8 flex items-center justify-center">
      <div className="w-full max-w-sm rounded-2xl bg-zinc-900/60 border border-zinc-800 p-5">
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">{fase === "fundar" ? "Fundar la casa" : "Admin"}</h1>
          <Link href="/login" className="text-xs text-zinc-300 underline underline-offset-4">
            Login normal
          </Link>
        </div>

        {fase === "entrar" ? (
          <>
            {fundada === false ? (
              <div className="mt-4 rounded-xl bg-amber-500/10 p-3 text-xs leading-snug text-amber-200 ring-1 ring-amber-500/20">
                Esta casa todavía no tiene dueño. Entra con el correo designado al instalarla y
                te pediremos los datos para fundarla.
                {/* EL DEFECTO QUE ARREGLA (11/10/2026)

                    En una casa recien instalada la cuenta del fundador NO EXISTE
                    todavia: `auth.users` esta vacio. Esta pantalla solo sabe hacer
                    signInWithPassword, asi que el designado escribia el correo que le
                    dieron y recibia "Invalid login credentials" -- el texto menos
                    informativo posible, porque suena a contrasena mal escrita cuando
                    en realidad no hay cuenta ninguna.

                    El camino al registro SI existia: este login -> enlace "Login
                    normal" -> /login -> "Crear cuenta" -> /register. Tres saltos
                    detras de un enlace rotulado "Login normal" no es un camino, es un
                    acertijo. Medido en la primera instalacion real (11/10/2026): se
                    quedo bloqueado exactamente aqui.

                    Solo se pinta con `fundada === false`. En una casa con dueno este
                    aviso no existe, y mandar admins al registro seria un error. */}
                <div className="mt-2">
                  ¿Todavía no tienes cuenta?{" "}
                  <Link href="/register" className="font-semibold underline underline-offset-4">
                    Créala con el correo designado
                  </Link>
                  , y vuelve aquí a fundar.
                </div>
              </div>
            ) : null}

            <form onSubmit={handleLogin} className="mt-5 space-y-3">
              <input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="admin@correo.com"
                className="w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
              />
              <input
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="contraseña"
                className="w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
              />

              {error ? (
                <div className="rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
                  {error}
                </div>
              ) : null}

              <button
                type="submit"
                disabled={loading}
                className="w-full rounded-xl bg-white text-zinc-950 font-semibold py-2 disabled:opacity-60"
              >
                {loading ? "Verificando..." : "Entrar como admin"}
              </button>
            </form>
          </>
        ) : (
          <>
            <p className="mt-4 text-xs leading-snug text-zinc-300">
              Vas a quedar como <span className="font-semibold text-zinc-100">super administrador</span> de
              esta casa: podrás aprobar recargas, pagar retiros, liquidar remates y nombrar a tus
              propios administradores.
            </p>
            {/* El codigo y el nombre NO son adorno: cada accion del panel queda
                firmada con ellos en la bitacora (ADR-027). Pedirlos aqui evita
                estrenar la casa con el defecto que el aviso ambar de
                /admin/super/admins viene a senalar. */}
            <p className="mt-2 text-xs leading-snug text-zinc-500">
              Con estos datos se firma cada acción tuya en el registro de la casa.
            </p>

            <form onSubmit={handleFundar} className="mt-5 space-y-3">
              <label className="block">
                <span className="text-xs text-zinc-400">Código (2 a 6 letras o números)</span>
                <input
                  value={codigo}
                  onChange={(e) => setCodigo(e.target.value.toUpperCase())}
                  placeholder="DUE1"
                  maxLength={6}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm uppercase outline-none focus:ring-2 focus:ring-white/10"
                />
              </label>
              <label className="block">
                <span className="text-xs text-zinc-400">Nombre visible</span>
                <input
                  value={nombre}
                  onChange={(e) => setNombre(e.target.value)}
                  placeholder="Juan Pérez"
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
                />
              </label>

              {error ? (
                <div className="rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
                  {error}
                </div>
              ) : null}

              <button
                type="submit"
                disabled={loading || codigo.trim().length < 2 || nombre.trim().length < 3}
                className="w-full rounded-xl bg-amber-400 text-zinc-950 font-semibold py-2 disabled:opacity-60"
              >
                {loading ? "Fundando..." : "Fundar la casa"}
              </button>
            </form>
          </>
        )}
      </div>
    </main>
  )
}
