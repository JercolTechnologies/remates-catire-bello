// ===========================================================================
//  lib/marca.ts  -  LA MARCA, EN UN SOLO SITIO
//
//  POR QUE EXISTE (09/10/2026)
//
//  "Remate Catire Bello" estaba escrito a mano en cinco sitios: dos `alt` de
//  BrandLogo, el `title` del layout, el pie de pagina y el `h1` de la portada.
//  Cambiar el nombre obligaba a buscarlos todos, y el que se olvidara se
//  quedaba con el nombre viejo sin que nadie se enterara.
//
//  Pero el motivo de fondo no es la comodidad: es el MODELO DE NEGOCIO. Esta
//  aplicacion se alquila, y cada licenciatario quiere el nombre de SU remate.
//
//  LAS DOS RANURAS, Y CUAL MANDA
//
//  Decision de Jota (09/10): el licenciatario puede poner el nombre de su
//  remate y su logo si lo tiene, pero **la marca que destaca es siempre la de
//  la plataforma**. Asi que son dos ranuras con jerarquia, no una sustitucion:
//
//    PLATAFORMA -> la nuestra. Siempre visible, siempre primero.
//    CASA       -> la del licenciatario. Secundaria, y opcional.
//
//  `casa.nombre` en null significa "esta instalacion es la de la plataforma"
//  (la de Jota), y entonces solo se pinta una marca, no dos iguales.
//
//  SE PUEDEN INVERTIR SIN REHACER NADA. Si algun dia se decide que la del
//  licenciatario sea la que manda -- y hay un argumento para ello, porque la
//  casa que cobra y paga es la suya, asi que su reputacion es la que esta en
//  juego delante del jugador -- se cambia el orden en los componentes que leen
//  esto, no en veinte pantallas.
//
//  DE DONDE VENDRAN ESTOS VALORES. Hoy estan aqui escritos. El destino es
//  `ajustes_instalacion`, que ya existe en la base con tres claves y ya tiene
//  su lectura publica por lista blanca (`ajustes_publicos()`, ADR-029). Este
//  archivo es la COSTURA: el dia que se anadan las claves de marca, cambia la
//  funcion de aqui y ninguna pantalla se entera. Esta en PENDIENTES 5.4.
// ===========================================================================

export type Marca = {
  /** El nombre largo, para titulos y textos legales. */
  nombre: string
  /** El nombre corto, para sitios estrechos como la barra lateral. */
  corto: string
  /** Logo con texto, en linea. Cabeceras anchas. */
  horizontal: string
  /** Logo con texto, apilado. Portada, login, registro. */
  vertical: string
  /** Solo el simbolo, sin texto. Barras, iconos, avatares. */
  isotipo: string
  /** Las mismas piezas en `currentColor`, para pintarlas con CSS. */
  mono: { horizontal: string; vertical: string; isotipo: string }
  /** La proporcion de cada pieza, para no repetir numeros en cada pantalla. */
  tam: {
    horizontal: { w: number; h: number }
    vertical: { w: number; h: number }
    isotipo: { w: number; h: number }
  }
}

/**
 * SVG, no PNG, desde el 10/10/2026.
 *
 * Los vectoriales se sacaron de los propios PNG con
 * `herramientas/marca_vectorizar.py` -- el disenador nunca entrego ninguno.
 * El isotipo pasa de 1.008 KB a 4,3 KB y ademas se ve mejor a cualquier
 * tamano. El procedimiento, lo que estos SVG NO son, y por que, estan en
 * `docs/MARCA.md`.
 *
 * NO HACE FALTA TOCAR `next.config.ts`. La documentacion de Next 16 dice:
 * "We recommend using the `unoptimized` prop when the `src` prop is known to
 * be SVG. This happens automatically when `src` ends with `.svg`". Es decir,
 * `next/image` con un .svg se salta el optimizador solo, y por eso NO hace
 * falta `dangerouslyAllowSVG`, que es la bandera que habria que poner si el
 * SVG pasara por el optimizador.
 *
 * Los PNG de 3,3 MB se quedan para lo que un vector plano no cubre: los
 * iconos del sistema operativo (`app/icon.png`, `apple-icon.png`) y la vista
 * previa al compartir (`opengraph-image.png`), que tienen que ser mapas de
 * bits por exigencia de iOS y de las redes.
 */
export const PLATAFORMA: Marca = {
  nombre: "Remate Catire Bello",
  corto: "Catire Bello",
  horizontal: "/marca/logo-horizontal.svg",
  vertical: "/marca/logo-vertical.svg",
  isotipo: "/marca/isotipo.svg",
  mono: {
    horizontal: "/marca/logo-horizontal-mono.svg",
    vertical: "/marca/logo-vertical-mono.svg",
    isotipo: "/marca/isotipo-mono.svg",
  },
  // Salen del `viewBox` de cada archivo. `next/image` exige `width` y
  // `height` aunque luego los controle el CSS: son la PROPORCION, no el
  // tamano final, y sin ellos el navegador no sabe cuanto hueco reservar y la
  // pagina da un salto al cargar.
  tam: {
    horizontal: { w: 3132, h: 785 },
    vertical: { w: 1289, h: 1255 },
    isotipo: { w: 978, h: 785 },
  },
}

/**
 * LA JERARQUIA SE INVIRTIO EL 11/10/2026 (ADR-049).
 *
 * El 09/10 la decision fue que la plataforma mandara siempre. Dos dias y una
 * licencia real despues, Jota la cambio por dos motivos suyos: menos jugadores
 * reclamandole a la plataforma por problemas de la casa, y un licenciatario
 * mas contento viendo su propio nombre.
 *
 * La constante `CASA` ya no existe. La casa se lee de `ajustes_instalacion`
 * (clave `casa_nombre`) en el servidor -- ver `lib/marcaCasa.ts` -- y llega a
 * las pantallas por contexto. Por eso estas dos funciones RECIBEN la casa en
 * vez de buscarla: asi siguen siendo puras y la dependencia se ve.
 *
 * `null` significa "esta instalacion es la de la plataforma", que es el caso
 * de nuestra propia casa: ahi la casa y la plataforma son la misma cosa.
 */
export type Casa = { nombre: string; logo?: string } | null

/**
 * LOS ICONOS DEL SISTEMA, EN `public/`, NO EN `app/` (11/10/2026, ADR-051).
 *
 * Estuvieron como `app/icon.png`, `app/apple-icon.png`, `app/favicon.ico` y
 * `app/opengraph-image.png`, que son CONVENCIONES DE ARCHIVO de Next. Y la
 * documentacion es tajante: "File-based metadata has the higher priority and
 * will override the `metadata` object and `generateMetadata` function".
 *
 * Es decir: mientras esos archivos existieran, el icono de la pestana y la
 * vista previa al compartir eran los NUESTROS en todas las casas, y no habia
 * forma de cambiarlo desde el codigo. Medido el 11/10 en la licencia: la
 * marca de la plataforma salia "en todos lados" porque salia en la pestana de
 * todas las paginas.
 *
 * Se quitaron de `app/` y se declaran desde `generateMetadata`, que es lo que
 * permite que una casa con logo ponga el suyo.
 */
export const ICONOS = {
  icono: "/marca/icon.png",
  apple: "/marca/apple-icon.png",
  compartir: "/marca/opengraph-image.png",
} as const

/**
 * Por donde se contacta con la plataforma.
 *
 * PROVISIONAL: el WhatsApp de Jercol hasta que exista la web de desarrollo.
 * Decision de Jota del 11/10, sabiendo el riesgo que se le planteo -- que un
 * jugador enfadado use este enlace en vez de escribirle a su casa. Por eso el
 * mensaje va PRERRELLENADO: encauza a quien escriba, y deja claro de que va
 * este canal.
 */
const WHATSAPP = "573019314319"

export function enlaceContacto(
  motivo: "licencia" | "soporte" = "licencia"
) {
  const texto =
    motivo === "soporte"
      ? `Hola, soy administrador de una casa en ${PLATAFORMA.nombre} y necesito soporte.`
      : `Hola, vi ${PLATAFORMA.nombre} y quiero informacion para licenciar mi propio remate.`
  return `https://wa.me/${WHATSAPP}?text=${encodeURIComponent(texto)}`
}

/**
 * EL PIE. Texto de Jota (11/10). Dice quien es duena de la plataforma, quien
 * la desarrollo y QUIEN LA OPERA -- que es lo que no decia el anterior.
 *
 * Dos lineas, y la segunda SOLO existe si hay casa: en nuestra propia
 * instalacion no hay licenciatario, y un "operada bajo licencia por" en blanco
 * seria peor que no decir nada.
 *
 * El año NO se escribe a mano: el `©2026` llevaba clavado desde enero y en
 * enero de 2027 habria mentido.
 */
export function pieDePagina(casa: Casa): { principal: string; licencia: string | null } {
  const anio = new Date().getFullYear()
  return {
    principal: `© ${anio} ${PLATAFORMA.nombre}. Desarrollado por Jercol Technologies. Todos los derechos reservados.`,
    licencia: casa ? `Plataforma operada bajo licencia por ${casa.nombre}.` : null,
  }
}

/** El titulo de la pestaña y de las vistas previas.
 *
 *  Con casa, va SOLO el nombre de la casa: es lo que el jugador guarda en
 *  marcadores y lo que lee en la pestaña, y es su casa, no la nuestra. La
 *  atribucion vive en el pie. */
export function tituloDocumento(casa: Casa) {
  return casa ? casa.nombre : PLATAFORMA.nombre
}
