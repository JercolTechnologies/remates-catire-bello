"use client"

// APP/DASHBOARD/LAYOUT.TSX
//
// EL PANEL DE JUGADOR NO ES PARA LA CASA
//
// Lo propuso Jota el 05/10, probando la guarda nueva: "¿por qué no nos quitamos
// eso de encima y quitamos /dashboard a cualquier cuenta que sea admin? Al fin y
// al cabo un admin no hace nada con un dashboard: ahí solo se ven saldos,
// recargas, retiros, historial de movimientos. No tiene sentido."
//
// Tiene razón, y ademas cierra de raiz una confusion que acabamos de ver. El
// probo pedir un retiro desde su cuenta de admin y la pantalla le contesto "no
// tienes saldo suficiente" en vez del rechazo por ser admin. No era que la
// guarda de la base fallara -- `app/dashboard/retirar/page.tsx:130` compara
// contra lo retirable y RETORNA ANTES de llamar a la RPC, asi que el mensaje
// que gana es el de la pantalla. La guarda de la base sigue ahi y P65 la mide.
//
// Pero el episodio deja clara una cosa: mientras la pantalla exista para un
// admin, va a seguir ofreciendole operaciones que la base le rechaza, y el
// mensaje que lea sera el que su pantalla decida contarle. **La forma de que
// una pantalla no confunda es que no este.**
//
// POR QUE UN LAYOUT Y NO UNA COMPROBACION EN CADA PAGINA
// Son tres pantallas hoy y cualquiera que se anada manana heredaria la guarda
// gratis. Es el mismo criterio del ADR-026 y del ADR-032: la regla que vale para
// un area vive por encima de sus pantallas, no repetida dentro de cada una.
//
// LA BASE SIGUE MANDANDO. Esto esconde la puerta; quien la cierra es
// `solicitar_recarga` y `solicitar_retiro` (ADR-033). Un admin que llame la RPC
// desde la consola del navegador sigue chocando con la base, que es donde tiene
// que chocar.

import { useEffect, useState } from "react"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  const router = useRouter()
  const [listo, setListo] = useState(false)

  useEffect(() => {
    let vivo = true

    async function comprobar() {
      const { data: auth } = await supabase.auth.getUser()
      if (!vivo) return

      if (!auth?.user) {
        router.replace("/login")
        return
      }

      const { data: prof } = await supabase
        .from("profiles")
        .select("es_admin,es_super_admin")
        .eq("id", auth.user.id)
        .maybeSingle()
      if (!vivo) return

      if (prof?.es_admin || prof?.es_super_admin) {
        router.replace("/admin")
        return
      }

      setListo(true)
    }

    void comprobar()
    return () => {
      vivo = false
    }
  }, [router])

  // Nada se pinta hasta saber quien mira. Sin esto, un admin ve su saldo y sus
  // botones de recargar y retirar durante el parpadeo previo a la redireccion.
  if (!listo) {
    return (
      <div className="min-h-screen flex items-center justify-center text-zinc-400 text-sm">
        Cargando...
      </div>
    )
  }

  return <>{children}</>
}
