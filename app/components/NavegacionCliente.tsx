"use client"

// ===========================================================================
//  components/NavegacionCliente.tsx  -  LA BARRA INFERIOR, EN UN SOLO SITIO
//
//  EL DEFECTO QUE ARREGLO (05/10/2026): `ClientBottomNav` estaba importado a
//  mano en SEIS pantallas, con TRES condiciones distintas:
//
//    /contactanos               -> siempre
//    /dashboard y sus dos hijas -> si hay sesion
//    /remates y /remates/[id]   -> si hay sesion Y NO es admin
//
//  Consecuencias de eso, todas reales:
//    - `/reglas` no lo tenia. Un jugador que entraba a leer las condiciones se
//      quedaba sin menu y sin forma obvia de volver.
//    - Cualquier pantalla nueva nacia sin el, y nadie se enteraba.
//    - La regla de "los admins no lo ven" se aplicaba en dos de seis.
//
//  Es el mismo patron que ya corregimos con el aviso de caja (ADR-026) y el
//  popup de avisos (ADR-030). Lo que vale para toda la aplicacion vive POR
//  ENCIMA de las pantallas, no dentro de una.
//
//  LA REGLA, UNA SOLA Y YA NO AQUI: la decide `SesionCliente`, que es quien
//  resuelve sesion y rol una vez para toda la aplicacion. Antes vivia en este
//  archivo; al nacer la cabecera habria hecho falta copiarla, y una regla
//  copiada es una regla que se va a desincronizar.
//
//  SOLO EN MOVIL, DESDE EL 09/10. Jota: "en movil mantengamos el menu en
//  parte inferior" y "en pc se vea normal y no un rectangulo en el medio".
//  Una barra fija abajo en un monitor de 27 pulgadas es exactamente eso: una
//  aplicacion de movil estirada. En escritorio el menu esta en la cabecera,
//  que es donde se busca. Mismo criterio que el panel del admin, que tiene
//  barra lateral en pc y barra inferior en movil.
//
//  Y los dos leen `ENLACES_CLIENTE`, asi que no pueden ofrecer menus
//  distintos.
// ===========================================================================

import ClientBottomNav from "./ClientBottomNav"
import { useRematesEnVivo } from "./RematesEnVivo"
import { useSesionCliente } from "./SesionCliente"

export default function NavegacionCliente() {
  const { visible } = useSesionCliente()
  const { nuevos } = useRematesEnVivo()

  if (!visible) return null

  return (
    <div className="lg:hidden">
      <ClientBottomNav nuevos={nuevos} />
      {/* El hueco que deja la barra, que es `fixed` y no ocupa sitio en el
          flujo. Va aqui y no como `pb-24` en cada pantalla: una pantalla nueva
          que se olvide del padding acaba con el ultimo boton tapado. Y va
          dentro del `lg:hidden` porque en escritorio no hay barra que tapar
          nada: un hueco de 64px al final de la pagina seria un bache. */}
      <div className="h-16" aria-hidden="true" />
    </div>
  )
}
