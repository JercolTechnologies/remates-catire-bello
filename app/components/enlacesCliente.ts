// ===========================================================================
//  components/enlacesCliente.ts  -  EL MENU DE CLIENTE, UNA SOLA LISTA
//
//  POR QUE EXISTE (09/10/2026)
//
//  El menu del jugador se pinta ahora en DOS sitios: la barra inferior en
//  movil y la cabecera en escritorio. Si cada uno lleva su propia lista, el
//  dia que se anada una pantalla va a entrar en uno y no en el otro, y nadie
//  se va a enterar hasta que un jugador se queje desde un portatil.
//
//  Es el mismo razonamiento que ya aplicamos al menu del admin y al aviso de
//  caja (ADR-026): lo que vale para toda la aplicacion se declara UNA vez.
//
//  `activo` se declara aqui y no se adivina en el componente. "/remates"
//  tiene que seguir marcado cuando estas dentro de un remate concreto, y
//  "/dashboard" NO tiene que marcarse cuando estas en "/dashboard/retirar",
//  porque retirar es su propio boton. Esa diferencia es una decision, no un
//  detalle de pintura.
//
//  LO QUE NO ESTA AQUI: "/reglas". No cabe -- la barra inferior ya lleva
//  cinco botones y un sexto en un movil estrecho los deja ilegibles. Hoy se
//  llega desde los enlaces del pie de las pantallas que la citan. Queda
//  anotado en PENDIENTES por si Jota prefiere meterla y sacar otra.
// ===========================================================================

export type EnlaceCliente = {
  href: string
  etiqueta: string
  /** Si este enlace es el de la pantalla en la que estamos. */
  activo: (ruta: string) => boolean
}

export const ENLACES_CLIENTE: EnlaceCliente[] = [
  {
    href: "/remates",
    etiqueta: "Remates",
    activo: (r) => r === "/remates" || r.startsWith("/remates/"),
  },
  {
    href: "/dashboard",
    etiqueta: "Panel",
    activo: (r) => r === "/dashboard",
  },
  {
    href: "/dashboard/recargar",
    etiqueta: "Recargar",
    activo: (r) => r === "/dashboard/recargar",
  },
  {
    href: "/dashboard/retirar",
    etiqueta: "Retirar",
    activo: (r) => r === "/dashboard/retirar",
  },
  {
    href: "/contactanos",
    etiqueta: "Contactanos",
    activo: (r) => r === "/contactanos",
  },
]
