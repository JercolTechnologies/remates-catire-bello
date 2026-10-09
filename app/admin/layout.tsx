// ADMIN/LAYOUT.TSX
//
// Envuelve TODO /admin/*. Dos cosas que tienen que vivir POR ENCIMA de las
// pantallas y no dentro de dos de ellas:
//
//   1. La suscripción al canal `admin:caja` (ADR-026). Una sola para todo el
//      panel; estaba en dos pantallas de once y por eso el realtime "no
//      existía" fuera de ellas.
//
//   2. La navegación (09/10/2026). El panel tenía once pantallas y ninguna
//      navegación: la única salida de cada una era un enlace "Volver", y por
//      eso había quince repartidos por el panel. Con la barra montada aquí,
//      esos quince sobran. Ver admin/NavegacionAdmin.tsx.
//
// Un layout en Next.js no se vuelve a montar al navegar entre las rutas que
// cubre, así que ni el canal ni la barra se reconstruyen en cada salto: el
// admin va del panel a contabilidad y de ahí al registro sin perder el aviso,
// sin reconectar el socket y sin que la navegación parpadee.
//
// EL HUECO DE LAS BARRAS SE RESERVA AQUÍ, no con un `pl-64` o un `pb-16` en
// cada pantalla. Es la misma lección que NavegacionCliente: una pantalla nueva
// que se olvide del margen acaba con la mitad tapada, y nadie lo ve hasta que
// un cliente lo sufre.

import { CajaEnVivo } from "./CajaEnVivo"
import NavegacionAdmin from "./NavegacionAdmin"

export default function AdminLayout({ children }: { children: React.ReactNode }) {
  return (
    <CajaEnVivo>
      <NavegacionAdmin />
      {/* lg:pl-64 = el ancho de la barra lateral. pb-20 = el de la barra
          inferior del móvil, que es `fixed` y no ocupa sitio en el flujo. */}
      <div className="lg:pl-64">
        <div className="pb-20 lg:pb-0">{children}</div>
      </div>
    </CajaEnVivo>
  )
}
