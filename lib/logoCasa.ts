// ===========================================================================
//  lib/logoCasa.ts  -  PREPARAR EL LOGO ANTES DE SUBIRLO
//
//  POR QUE EXISTE (11/10/2026, ADR-052)
//
//  Jota mando el logo del primer licenciatario y se midio: las dos versiones
//  -- PNG con transparencia y JPG -- son LIENZOS CUADRADOS 1:1, pero el dibujo
//  real es 2.76:1 y ocupa el 32% de la altura. El 68% es aire.
//
//  Eso no es un caso raro, es lo normal: la gente exporta su logo centrado en
//  un cuadrado. Y en una cabecera de 32 pixeles de alto, ese aire deja el
//  dibujo en unos 32x11 -- ilegible. Se comprobo pintandolo.
//
//  Decision de Jota: "recorta tu al subirlo". Nadie tiene que saber que es un
//  bounding box.
//
//  COMO SE DECIDE QUE ES AIRE. Depende de la imagen, y por eso se mira antes:
//
//   - Si tiene transparencia de verdad, el aire es lo transparente. Se recorta
//     por el canal alfa y punto.
//   - Si es opaca (un JPG), no hay alfa que mirar. Se toma el color de las
//     CUATRO ESQUINAS: si coinciden, ese es el fondo, y se recorta lo que se
//     le parezca. Vale para fondo blanco y para cualquier otro color solido.
//   - Si las esquinas no coinciden, el fondo no es solido y NO SE RECORTA
//     NADA. Mejor dejar la imagen como vino que comerse medio logo.
//
//  SE REENCODA A PNG SIEMPRE. El bucket no acepta SVG a proposito (es codigo
//  ajeno), y pasar por el lienzo garantiza que lo que sube es una imagen de
//  verdad y no un archivo con otra cosa dentro renombrado.
//
//  ESTO CORRE EN EL NAVEGADOR. Sin dependencias, sin servicio de imagenes, y
//  sin que el servidor tenga que tocar bytes de nadie.
// ===========================================================================

/** Alfa por debajo de esto cuenta como transparente. */
const ALFA_MINIMA = 16
/** Cuanto se puede alejar un pixel del color de fondo y seguir siendo fondo. */
const TOLERANCIA_FONDO = 12
/** El lado mayor del resultado. Suficiente para la portada; mantiene el peso bajo. */
const LADO_MAXIMO = 512

export type LogoPreparado = {
  blob: Blob
  ancho: number
  alto: number
  recortado: boolean
  /** Para poder decirle al dueno lo que se le hizo a su archivo. */
  resumen: string
}

function cargarImagen(file: File): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => {
      URL.revokeObjectURL(url)
      resolve(img)
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      reject(new Error("No se pudo leer la imagen. ¿Seguro que es un PNG o un JPG?"))
    }
    img.src = url
  })
}

type Caja = { x0: number; y0: number; x1: number; y1: number }

function cajaPorAlfa(d: Uint8ClampedArray, w: number, h: number): Caja | null {
  let x0 = w, y0 = h, x1 = -1, y1 = -1
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (d[(y * w + x) * 4 + 3] > ALFA_MINIMA) {
        if (x < x0) x0 = x
        if (x > x1) x1 = x
        if (y < y0) y0 = y
        if (y > y1) y1 = y
      }
    }
  }
  return x1 < 0 ? null : { x0, y0, x1, y1 }
}

function cajaPorColor(d: Uint8ClampedArray, w: number, h: number, fondo: number[]): Caja | null {
  let x0 = w, y0 = h, x1 = -1, y1 = -1
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4
      const lejos =
        Math.abs(d[i] - fondo[0]) > TOLERANCIA_FONDO ||
        Math.abs(d[i + 1] - fondo[1]) > TOLERANCIA_FONDO ||
        Math.abs(d[i + 2] - fondo[2]) > TOLERANCIA_FONDO
      if (lejos) {
        if (x < x0) x0 = x
        if (x > x1) x1 = x
        if (y < y0) y0 = y
        if (y > y1) y1 = y
      }
    }
  }
  return x1 < 0 ? null : { x0, y0, x1, y1 }
}

function pixel(d: Uint8ClampedArray, w: number, x: number, y: number) {
  const i = (y * w + x) * 4
  return [d[i], d[i + 1], d[i + 2]]
}

function iguales(a: number[], b: number[]) {
  return (
    Math.abs(a[0] - b[0]) <= TOLERANCIA_FONDO &&
    Math.abs(a[1] - b[1]) <= TOLERANCIA_FONDO &&
    Math.abs(a[2] - b[2]) <= TOLERANCIA_FONDO
  )
}

export async function prepararLogo(file: File): Promise<LogoPreparado> {
  const img = await cargarImagen(file)
  const w = img.naturalWidth
  const h = img.naturalHeight
  if (!w || !h) throw new Error("La imagen no tiene tamaño.")

  const lienzo = document.createElement("canvas")
  lienzo.width = w
  lienzo.height = h
  const ctx = lienzo.getContext("2d", { willReadFrequently: true })
  if (!ctx) throw new Error("Este navegador no deja procesar la imagen.")
  ctx.drawImage(img, 0, 0)

  const datos = ctx.getImageData(0, 0, w, h).data

  // ¿Tiene transparencia de verdad, o es opaca?
  let hayAlfa = false
  for (let i = 3; i < datos.length; i += 4) {
    if (datos[i] < 250) {
      hayAlfa = true
      break
    }
  }

  let caja: Caja | null = null
  let motivo = ""

  if (hayAlfa) {
    caja = cajaPorAlfa(datos, w, h)
    motivo = "por transparencia"
  } else {
    const esquinas = [
      pixel(datos, w, 0, 0),
      pixel(datos, w, w - 1, 0),
      pixel(datos, w, 0, h - 1),
      pixel(datos, w, w - 1, h - 1),
    ]
    const solido = esquinas.every((e) => iguales(e, esquinas[0]))
    if (solido) {
      caja = cajaPorColor(datos, w, h, esquinas[0])
      motivo = "por color de fondo"
    } else {
      // Fondo no solido: no se toca. Comerse medio logo es peor que dejar aire.
      caja = null
      motivo = "sin recortar (el fondo no es de un solo color)"
    }
  }

  if (hayAlfa && !caja) {
    throw new Error("La imagen está completamente transparente.")
  }

  const x0 = caja ? caja.x0 : 0
  const y0 = caja ? caja.y0 : 0
  const anchoRec = caja ? caja.x1 - caja.x0 + 1 : w
  const altoRec = caja ? caja.y1 - caja.y0 + 1 : h
  const recortado = anchoRec !== w || altoRec !== h

  // Escala para que el lado mayor no pase de LADO_MAXIMO. Nunca se agranda:
  // estirar un logo pequeño solo lo deja borroso y mas pesado.
  const escala = Math.min(1, LADO_MAXIMO / Math.max(anchoRec, altoRec))
  const anchoFinal = Math.max(1, Math.round(anchoRec * escala))
  const altoFinal = Math.max(1, Math.round(altoRec * escala))

  const salida = document.createElement("canvas")
  salida.width = anchoFinal
  salida.height = altoFinal
  const ctx2 = salida.getContext("2d")
  if (!ctx2) throw new Error("Este navegador no deja procesar la imagen.")
  ctx2.imageSmoothingQuality = "high"
  ctx2.drawImage(img, x0, y0, anchoRec, altoRec, 0, 0, anchoFinal, altoFinal)

  const blob = await new Promise<Blob | null>((res) => salida.toBlob(res, "image/png"))
  if (!blob) throw new Error("No se pudo preparar la imagen.")

  const resumen = recortado
    ? `Recortado ${motivo}: de ${w}×${h} a ${anchoFinal}×${altoFinal}.`
    : `${motivo === "" ? "" : motivo.charAt(0).toUpperCase() + motivo.slice(1) + ". "}Queda en ${anchoFinal}×${altoFinal}.`

  return { blob, ancho: anchoFinal, alto: altoFinal, recortado, resumen }
}
