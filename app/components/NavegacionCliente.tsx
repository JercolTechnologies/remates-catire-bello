"use client"

// COMPONENTS/NAVEGACIONCLIENTE.TSX
//
// EL MENU INFERIOR, EN UN SOLO SITIO
//
// EL DEFECTO QUE ARREGLA: `ClientBottomNav` estaba importado a mano en SEIS
// pantallas, con TRES condiciones distintas:
//
//   /contactanos              -> siempre
//   /dashboard y sus dos hijas -> si hay sesion
//   /remates y /remates/[id]  -> si hay sesion Y NO es admin
//
// Consecuencias de eso, todas reales:
//   - `/reglas` no lo tenia. Un jugador que entraba a leer las condiciones se
//     quedaba sin menu y sin forma obvia de volver.
//   - Cualquier pantalla nueva nacia sin el, y nadie se enteraba.
//   - La regla de "los admins no lo ven" se aplicaba en dos pantallas de seis.
//
// Es el mismo patron que ya corregimos dos veces esta semana: el aviso de caja
// (ADR-026) y el popup de avisos al usuario (ADR-030). Lo que vale para toda la
// aplicacion vive POR ENCIMA de las pantallas, no dentro de una.
//
// LA REGLA, AHORA UNA SOLA: se ve en las rutas de cliente, con sesion iniciada,
// y NO siendo administrador.
//
// CORREGIDO EL 05/10 POR LA TARDE. La primera version se lo ensenaba tambien a
// los admins, con el argumento de que "tienen cartera como cualquiera". Jota
// pregunto si eso no contradecia la regla de que un admin no puede pujar, y
// tenia razon: la casa no juega, y tampoco usa la cartera de jugador. Peor
// todavia, ensenarle "Recargar" y "Retirar" a un admin le ofrecia dos
// operaciones que desde la migracion 20261006110000 la base le rechaza.
//
// Unificar hacia la mayoria era un mal criterio: cuatro pantallas hacian una
// cosa y dos hacian la correcta.
//
// LAS RUTAS SE DECLARAN POR LO QUE NO SON. Una lista blanca habria que ampliarla
// con cada pantalla nueva, y la siguiente volveria a nacer sin menu -- que es el
// defecto que estamos cerrando. La lista negra es corta y estable: panel de
// admin, autenticacion y la portada.

import { useEffect, useState } from "react"
import { usePathname } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"
import ClientBottomNav from "./ClientBottomNav"

// Donde el menu de cliente no pinta nada.
const FUERA = ["/admin", "/login", "/register", "/auth", "/panel", "/api"]

export default function NavegacionCliente() {
  const pathname = usePathname()
  const [haySesion, setHaySesion] = useState(false)
  const [esAdmin, setEsAdmin] = useState(false)

  useEffect(() => {
    let vivo = true

    async function mirar() {
      const { data } = await supabase.auth.getUser()
      if (!vivo) return
      const u = data?.user ?? null
      setHaySesion(!!u)

      if (!u) {
        setEsAdmin(false)
        return
      }
      const { data: prof } = await supabase
        .from("profiles")
        .select("es_admin,es_super_admin")
        .eq("id", u.id)
        .maybeSingle()
      if (!vivo) return
      setEsAdmin(!!(prof?.es_admin || prof?.es_super_admin))
    }

    void mirar()
    // Al iniciar o cerrar sesion el menu aparece o desaparece sin recargar.
    const { data: sub } = supabase.auth.onAuthStateChange(() => void mirar())
    return () => {
      vivo = false
      sub?.subscription?.unsubscribe()
    }
  }, [])

  // La portada es su propia pantalla de entrada y no lleva menu.
  const esPortada = pathname === "/"
  const esDeAdminOAuth = FUERA.some((p) => pathname === p || pathname.startsWith(p + "/"))

  if (!haySesion || esAdmin || esPortada || esDeAdminOAuth) return null

  return (
    <>
      <ClientBottomNav />
      {/* El hueco que deja la barra, que es `fixed` y no ocupa sitio en el
          flujo. Va aqui y no como `pb-24` en cada pantalla: una pantalla nueva
          que se olvide del padding acaba con el ultimo boton tapado. */}
      <div className="h-16" aria-hidden="true" />
    </>
  )
}
