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
}

export const PLATAFORMA: Marca = {
  nombre: "Remate Catire Bello",
  corto: "Catire Bello",
  horizontal: "/marca/logo-horizontal.png",
  vertical: "/marca/logo-vertical.png",
  isotipo: "/marca/isotipo.png",
}

/**
 * La casa de ESTA instalacion. `null` = la instalacion es la de la plataforma
 * y no hay una segunda marca que pintar.
 *
 * Para un licenciatario: { nombre: "Remate El Zuliano", logo: "/marca/casa.png" }
 * El logo es opcional: muchos no van a tener uno.
 */
export const CASA: { nombre: string; logo?: string } | null = null

/** Lo que va en el pie. El año NO se escribe a mano: el `©2026` del pie
 *  llevaba clavado desde enero y en enero de 2027 habria mentido. */
export function pieDePagina() {
  return `${PLATAFORMA.nombre} ©${new Date().getFullYear()} Todos los derechos reservados. Desarrollado por Jercol Technologies.`
}

/** El titulo de la pestaña y de las vistas previas. Si hay casa, va detras:
 *  la plataforma manda. */
export function tituloDocumento() {
  return CASA ? `${PLATAFORMA.nombre} · ${CASA.nombre}` : PLATAFORMA.nombre
}
