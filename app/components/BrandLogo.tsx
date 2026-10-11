"use client"

// ===========================================================================
//  components/BrandLogo.tsx  -  LAS DOS PIEZAS DE MARCA SUELTAS
//
//  QUE CAMBIO EL 10/10/2026
//
//  Antes este archivo tenia la marca CLAVADA en cuatro sitios: dos rutas
//  (`/logo-hero.png`, `/logo.png`) y dos `alt` con el nombre escrito a mano.
//  Cambiar el nombre de la casa obligaba a venir aqui a buscarlos, y el que se
//  olvidara se quedaba con el nombre viejo sin que nadie se enterara. Eso es
//  exactamente lo que `lib/marca.ts` existe para evitar, y es el modelo de
//  negocio: esta aplicacion se alquila.
//
//  Ahora las dos piezas leen `PLATAFORMA`. Cambiar de marca es cambiar un
//  objeto, y el dia que esos valores vengan de `ajustes_instalacion` no hay
//  que tocar ningun componente (PENDIENTES 5.4).
//
//  Y SON SVG. `logo-vertical.svg` pesa 12,8 KB contra 1.915 KB del PNG, y se
//  ve nitido a cualquier tamano. Ver `docs/MARCA.md` para como se sacaron y
//  para lo que estos vectoriales NO son.
//
//  `width` y `height` NO son el tamano final -- lo manda el CSS. Son la
//  PROPORCION, que `next/image` necesita para reservar el hueco antes de que
//  la imagen cargue; sin ellos la pagina pega un salto. Salen de `tam` en
//  lib/marca.ts, que a su vez sale del `viewBox` de cada archivo.
// ===========================================================================

import Image from "next/image"
import Link from "next/link"
import { PLATAFORMA } from "@/lib/marca"
import { useCasa } from "./MarcaCasa"

type LogoProps = {
  href?: string
}

/** El conjunto apilado: simbolo y nombre. Portada y login. */
export function HeroLogo({ href = "/remates" }: LogoProps) {
  // La portada y las pantallas de entrada las ve el JUGADOR: su casa manda
  // (ADR-049). Sin casa, la instalacion es la nuestra y se pinta la nuestra.
  const casa = useCasa()

  if (casa) {
    return (
      <Link href={href} aria-label={casa.nombre} className="mx-auto block w-fit text-center">
        {casa.logo ? (
          /* URL distinta por instalacion: no se puede declarar en
             next.config.ts en tiempo de compilacion. Ver CabeceraCliente. */
          /* eslint-disable-next-line @next/next/no-img-element */
          <img src={casa.logo} alt={casa.nombre} className="mx-auto h-auto w-[180px] object-contain sm:w-[220px]" />
        ) : (
          // Sin logo, el nombre ES el logo. Mejor un nombre bien puesto que el
          // simbolo de otra marca haciendo de suplente.
          <span className="block text-2xl font-bold tracking-tight text-oro sm:text-3xl">
            {casa.nombre}
          </span>
        )}
      </Link>
    )
  }

  return (
    <Link href={href} aria-label={PLATAFORMA.nombre} className="mx-auto block w-fit">
      <Image
        src={PLATAFORMA.vertical}
        alt={PLATAFORMA.nombre}
        width={PLATAFORMA.tam.vertical.w}
        height={PLATAFORMA.tam.vertical.h}
        priority
        className="h-auto w-[220px] sm:w-[260px]"
      />
    </Link>
  )
}

/** El encabezado de la portada, para lectores de pantalla y buscadores.
 *
 *  El nombre visible ya esta dentro del logo; esto es el <h1> de verdad, que
 *  una pagina necesita aunque no se vea. Dice el nombre de LA CASA cuando la
 *  hay: para el buscador, este sitio es el remate de ese licenciatario. */
export function PortadaTitulo() {
  const casa = useCasa()
  return <h1 className="sr-only">{casa ? casa.nombre : PLATAFORMA.nombre}</h1>
}

/** Solo el simbolo, arriba a la derecha. Queda en las pantallas de
 *  autenticacion, que no llevan cabecera (ADR-040). */
export function CornerLogo({ href = "/remates" }: LogoProps) {
  return (
    <div className="flex justify-end">
      <Link href={href} aria-label={PLATAFORMA.nombre} className="inline-flex">
        <Image
          src={PLATAFORMA.isotipo}
          alt={PLATAFORMA.nombre}
          width={PLATAFORMA.tam.isotipo.w}
          height={PLATAFORMA.tam.isotipo.h}
          className="h-10 w-auto sm:h-12"
        />
      </Link>
    </div>
  )
}
