"use client"

// ===========================================================================
//  components/SesionCliente.tsx  -  QUIEN ERES Y CUANTO TIENES, UNA SOLA VEZ
//
//  POR QUE EXISTE (09/10/2026)
//
//  La cabecera del jugador y la barra inferior necesitan exactamente lo
//  mismo: si hay sesion, si eres admin, como te llamas y cuanto tienes. Pero
//  no pueden ser el mismo componente, porque la cabecera va ARRIBA del
//  contenido y la barra va abajo.
//
//  Dos componentes preguntando lo mismo por separado serian, contando la
//  pantalla que ya pregunta, la tercera copia de la misma pregunta en el
//  arbol. Eso es el defecto que ADR-026 cerro dos veces esta semana, asi que
//  aqui se hace bien desde el principio: un proveedor pregunta, dos
//  componentes pintan.
//
//  Es la misma forma que `CajaEnVivo` en el panel del admin, y por el mismo
//  motivo: los contadores de la barra y los del panel salen del mismo sitio,
//  asi que NO PUEDEN discrepar. Uno en 2 y el otro en 0 deja de ser posible.
//
//  CUANDO SE VUELVE A LEER EL SALDO
//
//  Al cambiar de pantalla. Es una llamada por navegacion y resuelve el caso
//  real: el jugador puja en el remate (donde la cabecera no se pinta), sale a
//  la lista, y el numero de arriba ya es el bueno. Un canal de realtime por
//  jugador solo para el numero de la cabecera seria una suscripcion mas por
//  sesion de navegador para un dato que no decide nada -- las dos pantallas
//  donde el saldo SI decide (pujar y el panel) leen el suyo y ya lo tenian.
//
//  `refrescar()` queda expuesto para quien mueva dinero y quiera que el
//  numero de arriba cambie sin esperar a la siguiente navegacion.
//
//  NO HACE NADA SIN SESION. Ni consulta, ni pinta. En la portada y en las
//  pantallas de autenticacion no hay a quien saludar, y una consulta sin
//  sesion solo llena la consola de errores.
//
//  LAS RUTAS SE DECLARAN POR LO QUE NO SON. Una lista blanca habria que
//  ampliarla con cada pantalla nueva y la siguiente volveria a nacer sin
//  menu, que es justo el defecto que cerramos el 05/10. La lista negra es
//  corta y estable: panel de admin, autenticacion y la portada.
// ===========================================================================

import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react"
import { usePathname } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

// Donde el marco de cliente no pinta nada.
const FUERA = ["/admin", "/login", "/register", "/auth", "/panel", "/api"]

type Sesion = {
  /** Si toca pintar el marco de cliente (cabecera y barra) en esta ruta. */
  visible: boolean
  /** Como se llama, para saludarle. Cae al correo si no puso nombre. */
  usuario: string
  /** `saldo_disponible`: lo que TIENE. null mientras no se sabe. */
  saldo: number | null
  /** Para quien mueva dinero y quiera el numero de arriba al dia ya. */
  refrescar: () => void
}

const SesionContexto = createContext<Sesion>({
  visible: false,
  usuario: "",
  saldo: null,
  refrescar: () => {},
})

export function useSesionCliente() {
  return useContext(SesionContexto)
}

/**
 * Pide el saldo a la base. Devuelve el numero, `null` si el usuario no tiene
 * cartera todavia, y `undefined` si la consulta fallo -- que NO es lo mismo:
 * ante un fallo de red se deja el numero que ya estaba, porque borrarlo le
 * ensena un guion donde antes tenia su dinero.
 *
 * Vive fuera del componente a proposito: asi no toca estado y los dos sitios
 * que la usan deciden por separado que hacer con la respuesta.
 */
async function pedirSaldo(): Promise<number | null | undefined> {
  const { data, error } = await supabase.rpc("mi_wallet_resumen")
  if (error) {
    console.error("saldo cabecera:", error.message)
    return undefined
  }
  const fila = Array.isArray(data) ? data[0] : null
  return fila ? Number(fila.saldo_disponible) : null
}

export function SesionCliente({ children }: { children: React.ReactNode }) {
  const pathname = usePathname()
  const [haySesion, setHaySesion] = useState(false)
  const [esAdmin, setEsAdmin] = useState(false)
  const [usuario, setUsuario] = useState("")
  const [saldo, setSaldo] = useState<number | null>(null)

  // La portada es su propia pantalla de entrada y no lleva marco.
  const esPortada = pathname === "/"
  const esDeAdminOAuth = FUERA.some((p) => pathname === p || pathname.startsWith(p + "/"))
  const enRutaDeCliente = !esPortada && !esDeAdminOAuth

  // Quien eres. Se resuelve al montar y cada vez que la sesion cambia.
  useEffect(() => {
    let vivo = true

    async function mirar() {
      const { data } = await supabase.auth.getUser()
      if (!vivo) return
      const u = data?.user ?? null
      setHaySesion(!!u)

      if (!u) {
        setEsAdmin(false)
        setUsuario("")
        setSaldo(null)
        return
      }

      const { data: prof } = await supabase
        .from("profiles")
        .select("username,es_admin,es_super_admin")
        .eq("id", u.id)
        .maybeSingle()
      if (!vivo) return

      setEsAdmin(!!(prof?.es_admin || prof?.es_super_admin))
      setUsuario(prof?.username ? String(prof.username) : (u.email ?? ""))
    }

    void mirar()
    // Al iniciar o cerrar sesion el marco aparece o desaparece sin recargar.
    const { data: sub } = supabase.auth.onAuthStateChange(() => void mirar())
    return () => {
      vivo = false
      sub?.subscription?.unsubscribe()
    }
  }, [])

  // Un admin no tiene cartera de jugador: desde la migracion 20261006110000
  // la base le rechaza recargar y retirar, asi que preguntar por su saldo es
  // preguntar por algo que no existe.
  const puedeLeerSaldo = haySesion && !esAdmin && enRutaDeCliente

  // Al cambiar de pantalla, el numero de arriba se vuelve a leer. La ruta
  // entra en las dependencias a proposito: es la senal de "algo pudo pasar".
  const yaLeido = useRef("")
  useEffect(() => {
    if (!puedeLeerSaldo) {
      yaLeido.current = ""
      return
    }
    if (yaLeido.current === pathname) return
    yaLeido.current = pathname

    let vivo = true
    void (async () => {
      const v = await pedirSaldo()
      // `undefined` es "fallo la consulta": el numero de antes se queda.
      if (vivo && v !== undefined) setSaldo(v)
    })()
    return () => {
      vivo = false
    }
  }, [puedeLeerSaldo, pathname])

  const refrescar = useCallback(() => {
    if (!puedeLeerSaldo) return
    void pedirSaldo().then((v) => {
      if (v !== undefined) setSaldo(v)
    })
  }, [puedeLeerSaldo])

  const visible = haySesion && !esAdmin && enRutaDeCliente

  return (
    <SesionContexto.Provider value={{ visible, usuario, saldo, refrescar }}>
      {children}
    </SesionContexto.Provider>
  )
}
