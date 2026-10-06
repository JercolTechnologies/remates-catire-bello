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
// LA REGLA, AHORA UNA SOLA: se ve en las rutas de cliente, con sesion iniciada.
// Los admins TAMBIEN lo ven -- tienen cartera y pueden recargar y retirar como
// cualquiera. Era el comportamiento de cuatro de las seis pantallas; esto
// unifica hacia donde ya estaba la mayoria, no inventa uno nuevo.
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

  useEffect(() => {
    let vivo = true

    async function mirar() {
      const { data } = await supabase.auth.getUser()
      if (!vivo) return
      setHaySesion(!!data?.user)
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

  if (!haySesion || esPortada || esDeAdminOAuth) return null

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
