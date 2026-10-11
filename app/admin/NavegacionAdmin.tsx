"use client"

// ===========================================================================
//  admin/NavegacionAdmin.tsx  -  EL PANEL DEJA DE NO TENER NAVEGACION
//
//  EL DEFECTO QUE ARREGLA (09/10/2026)
//
//  Jota: "ME TIENE ENFERMO EL PUTO BOTONSITO DE VOLVER, VOLVER, VOLVER".
//
//  Habia 25 enlaces "Volver" repartidos en 19 archivos, y 15 de ellos estaban
//  en el panel. No era un problema de botones: el panel tiene ONCE pantallas y
//  CERO navegacion, asi que ese enlace era la unica forma de salir de
//  cualquiera de ellas. Por eso estaba en todas.
//
//  Con una navegacion permanente los 15 sobran y se borran. No hay que ir
//  quitandolos de uno en uno como si fueran el problema: eran el sintoma.
//
//  LOS GRUPOS SALEN DE LA OPERACION, NO DE LA ESTRUCTURA DE CARPETAS
//
//    Caja     recargas, retiros        -> todos los dias
//    Remates  lista, crear             -> los dias de carrera
//    Casa     contabilidad, registro   -> cada semana o cada mes
//    Ajustes  admins, usuarios, soporte-> casi nunca
//
//  LATERAL EN ESCRITORIO Y NO BARRA SUPERIOR. Once pantallas no caben en
//  horizontal sin menus colgantes, y un menu colgante es un "Volver" con otra
//  ropa: sigue haciendo falta un clic para ver a donde puedes ir. En vertical
//  caben las once a la vez.
//
//  LOS CONTADORES NO SE CALCULAN AQUI. `CajaEnVivo` ya los tiene y ya esta
//  suscrito al canal `admin:caja` por encima de todo el panel (ADR-026).
//  Contarlos otra vez seria una segunda fuente para el mismo hecho, y
//  acabariamos con la barra diciendo 3 y el aviso diciendo 4.
//
//  POR QUE EL NUMERO IMPORTA TANTO: es dinero de gente esperando. Verlo sin
//  entrar a mirar es la diferencia entre enterarte y acordarte de mirar.
// ===========================================================================

import Link from "next/link"
import Image from "next/image"
import { usePathname } from "next/navigation"
import { useState } from "react"
import { useCajaEnVivo } from "./CajaEnVivo"
import { PLATAFORMA, enlaceContacto } from "@/lib/marca"
import { useCasa } from "@/app/components/MarcaCasa"

type Punto = {
  href: string
  texto: string
  /** Cuando una pantalla tiene hijas, `exacto: false` mantiene el grupo
   *  marcado tambien dentro de ellas. */
  exacto?: boolean
  contador?: "recargas" | "retiros"
}

type Grupo = { titulo: string; icono: React.ReactNode; puntos: Punto[] }

// Iconos en SVG, dibujados aqui. Una libreria de iconos por cuatro simbolos
// son cientos de kilobytes que el jugador tambien se descarga.
const I = (d: string) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"
       strokeLinecap="round" strokeLinejoin="round" className="h-5 w-5" aria-hidden="true">
    <path d={d} />
  </svg>
)

const GRUPOS: Grupo[] = [
  {
    titulo: "Caja",
    icono: I("M3 7h18v12H3zM3 7l2-3h14l2 3M16 13h2"),
    puntos: [
      { href: "/admin/recargas", texto: "Recargas", contador: "recargas" },
      { href: "/admin/retiros", texto: "Retiros", contador: "retiros" },
    ],
  },
  {
    titulo: "Remates",
    icono: I("M5 21V4h12l-2 3 2 3H5M5 21H3"),
    puntos: [
      { href: "/admin/remates", texto: "Ver remates", exacto: false },
      { href: "/admin/crear-remate", texto: "Crear remate" },
    ],
  },
  {
    titulo: "Casa",
    icono: I("M4 20V9l8-5 8 5v11M9 20v-6h6v6"),
    puntos: [
      { href: "/admin/contabilidad", texto: "Contabilidad" },
      { href: "/admin/log", texto: "Registro" },
    ],
  },
  {
    titulo: "Ajustes",
    icono: I("M12 15a3 3 0 100-6 3 3 0 000 6zM19.4 15a1.7 1.7 0 00.3 1.9l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-2.9 1.2V21a2 2 0 11-4 0v-.1A1.7 1.7 0 007 19.4a1.7 1.7 0 00-1.9.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00-1.2-2.9H1a2 2 0 110-4h.1A1.7 1.7 0 002.6 7a1.7 1.7 0 00-.3-1.9l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.9.3H7a1.7 1.7 0 001-1.5V1a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.9-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.9V7a1.7 1.7 0 001.5 1H23a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z"),
    puntos: [
      { href: "/admin/super/ajustes", texto: "Datos de la casa" },
      { href: "/admin/super/admins", texto: "Administradores" },
      { href: "/admin/super/usuarios", texto: "Usuarios" },
      { href: "/admin/super/soporte", texto: "Soporte" },
    ],
  },
]

function activo(pathname: string, p: Punto) {
  return p.exacto === false ? pathname.startsWith(p.href) : pathname === p.href
}

export default function NavegacionAdmin() {
  const pathname = usePathname()
  // Aqui la plataforma SIGUE mandando y la casa va debajo (ADR-049). Esta
  // pantalla la ve el licenciatario, no el jugador: es el escaparate del
  // software, y es a el a quien se le vende.
  const casa = useCasa()
  const { recargasPendientes, retirosPendientes, activo: esAdmin } = useCajaEnVivo()
  const [abierto, setAbierto] = useState(false)

  // QUIEN NO ES ADMIN NO VE EL PANEL, NI SU ESQUELETO.
  //
  // El layout envuelve TODO /admin/*, incluida la pantalla de login y
  // cualquier visita de un jugador que llegue ahi por un enlace viejo.
  // Ensenarle la barra con "Contabilidad" y "Administradores" seria contarle
  // la estructura de la casa a quien no entra en ella; y en /admin/login,
  // ademas, pintar una navegacion a sitios que aun no puede abrir.
  //
  // `activo` es el `esAdmin` de CajaEnVivo (se renombra al sacarlo: dentro
  // de este archivo `activo` ya es la funcion que decide si un punto del
  // menu esta seleccionado, y el booleano la tapaba sin avisar), que ya hace esa consulta para
  // decidir si se suscribe. Preguntarlo otra vez aqui seria una segunda
  // fuente para el mismo hecho. Empieza en `false`, asi que por omision NO se
  // pinta: si algo falla, el fallo es no ensenar la barra, no ensenarsela a
  // quien no debe.
  if (!esAdmin || pathname === "/admin/login") return null

  const cuenta = (c?: Punto["contador"]) =>
    c === "recargas" ? recargasPendientes : c === "retiros" ? retirosPendientes : 0

  const pendientesDeGrupo = (g: Grupo) =>
    g.puntos.reduce((n, p) => n + cuenta(p.contador), 0)

  const Marca = (
    <Link href="/admin" className="flex items-center gap-3" aria-label="Panel">
      <Image src={PLATAFORMA.isotipo} alt="" width={40} height={40}
             className="h-9 w-9 shrink-0 object-contain" />
      <span className="min-w-0">
        <span className="block truncate text-sm font-semibold text-oro">
          {PLATAFORMA.corto}
        </span>
        {/* La marca del licenciatario va DEBAJO y mas pequena: la que destaca
            es la de la plataforma. Ver lib/marca.ts. */}
        <span className="block truncate text-[11px] text-zinc-500">
          {casa ? casa.nombre : "Panel de la casa"}
        </span>
      </span>
    </Link>
  )

  const Enlaces = (
    <nav className="space-y-5">
      {GRUPOS.map((g) => (
        <div key={g.titulo}>
          <div className="flex items-center gap-2 px-3 pb-1.5 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
            <span className="text-zinc-600">{g.icono}</span>
            {g.titulo}
          </div>
          <ul className="space-y-0.5">
            {g.puntos.map((p) => {
              const act = activo(pathname, p)
              const n = cuenta(p.contador)
              return (
                <li key={p.href}>
                  <Link
                    href={p.href}
                    onClick={() => setAbierto(false)}
                    aria-current={act ? "page" : undefined}
                    className={`flex items-center justify-between gap-2 rounded-xl px-3 py-2 text-sm transition-colors ${
                      act
                        ? "bg-oro/10 font-semibold text-oro ring-1 ring-oro/25"
                        : "text-zinc-300 hover:bg-zinc-900 hover:text-zinc-100"
                    }`}
                  >
                    <span className="truncate">{p.texto}</span>
                    {n > 0 ? (
                      <span className="inline-flex min-w-[1.4rem] items-center justify-center rounded-full bg-amber-400 px-1.5 text-[11px] font-bold tabular-nums text-zinc-950">
                        {n > 99 ? "99+" : n}
                      </span>
                    ) : null}
                  </Link>
                </li>
              )
            })}
          </ul>
        </div>
      ))}
    </nav>
  )

  return (
    <>
      {/* ---------------------------------------------------- ESCRITORIO */}
      <aside className="fixed inset-y-0 left-0 z-40 hidden w-64 flex-col border-r border-zinc-800 bg-zinc-950 lg:flex">
        <div className="border-b border-zinc-800 px-4 py-4">{Marca}</div>
        <div className="flex-1 overflow-y-auto px-2 py-4">{Enlaces}</div>
        <div className="border-t border-zinc-800 p-2">
          <Link href="/remates"
                className="block rounded-xl px-3 py-2 text-xs text-zinc-400 hover:bg-zinc-900 hover:text-zinc-200">
            Ver la app como un jugador
          </Link>
          {/* El soporte de la PLATAFORMA, no el de la casa. Va aqui y no en el
              pie publico porque aqui esta exactamente quien lo necesita -- el
              licenciatario -- y ningun jugador. */}
          <a
            href={enlaceContacto("soporte")}
            target="_blank"
            rel="noopener noreferrer"
            className="block rounded-xl px-3 py-2 text-xs text-zinc-500 hover:bg-zinc-900 hover:text-zinc-200"
          >
            Soporte de la plataforma
          </a>
        </div>
      </aside>

      {/* -------------------------------------------------------- MOVIL */}
      {/* Cabecera fija con el boton del menu. El panel se opera desde el
          escritorio, pero cuando Jota mira el telefono tiene que poder llegar
          a Caja sin buscar. */}
      <header className="sticky top-0 z-40 flex items-center justify-between gap-3 border-b border-zinc-800 bg-zinc-950/95 px-4 py-3 backdrop-blur lg:hidden">
        {Marca}
        <button
          type="button"
          onClick={() => setAbierto(true)}
          className="relative rounded-xl border border-zinc-800 p-2 text-zinc-300"
          aria-label="Abrir el menú"
        >
          {I("M4 7h16M4 12h16M4 17h16")}
          {recargasPendientes + retirosPendientes > 0 ? (
            <span className="absolute -right-1 -top-1 h-2.5 w-2.5 rounded-full bg-amber-400" />
          ) : null}
        </button>
      </header>

      {abierto ? (
        <div className="fixed inset-0 z-50 lg:hidden">
          <button
            type="button"
            aria-label="Cerrar el menú"
            onClick={() => setAbierto(false)}
            className="absolute inset-0 bg-black/70"
          />
          <div className="absolute inset-y-0 left-0 flex w-72 max-w-[85vw] flex-col border-r border-zinc-800 bg-zinc-950">
            <div className="flex items-center justify-between border-b border-zinc-800 px-4 py-4">
              {Marca}
              <button type="button" onClick={() => setAbierto(false)}
                      className="rounded-lg p-1 text-zinc-400" aria-label="Cerrar">
                {I("M6 6l12 12M18 6L6 18")}
              </button>
            </div>
            <div className="flex-1 overflow-y-auto px-2 py-4">{Enlaces}</div>
          </div>
        </div>
      ) : null}

      {/* Barra inferior: los cuatro grupos, al alcance del pulgar. Lleva al
          primer punto de cada uno, que es el que se usa. */}
      <nav className="fixed inset-x-0 bottom-0 z-40 border-t border-zinc-800 bg-zinc-950/95 backdrop-blur lg:hidden">
        <ul className="mx-auto flex max-w-md items-stretch">
          {GRUPOS.map((g) => {
            const destino = g.puntos[0].href
            const act = g.puntos.some((p) => activo(pathname, p))
            const n = pendientesDeGrupo(g)
            return (
              <li key={g.titulo} className="flex-1">
                <Link href={destino}
                      className={`relative flex flex-col items-center gap-0.5 py-2 text-[11px] font-semibold ${
                        act ? "text-oro" : "text-zinc-400"
                      }`}>
                  {g.icono}
                  {g.titulo}
                  {n > 0 ? (
                    <span className="absolute right-1/2 top-1 translate-x-4 inline-flex min-w-[1.1rem] items-center justify-center rounded-full bg-amber-400 px-1 text-[10px] font-bold text-zinc-950">
                      {n > 9 ? "9+" : n}
                    </span>
                  ) : null}
                </Link>
              </li>
            )
          })}
        </ul>
      </nav>
    </>
  )
}
