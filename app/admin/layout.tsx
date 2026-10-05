// ADMIN/LAYOUT.TSX
//
// Envuelve TODO /admin/*. Existe por una sola razón: que la suscripción al
// canal `admin:caja` viva por encima de las pantallas y no dentro de dos de
// ellas. Ver app/admin/CajaEnVivo.tsx y el ADR-026.
//
// Un layout en Next.js no se vuelve a montar al navegar entre las rutas que
// cubre, así que el canal sobrevive a los cambios de pantalla: el admin puede
// ir del panel a contabilidad y de ahí al registro sin perder el aviso ni
// reconectar el socket en cada salto.

import { CajaEnVivo } from "./CajaEnVivo"

export default function AdminLayout({ children }: { children: React.ReactNode }) {
  return <CajaEnVivo>{children}</CajaEnVivo>
}
