// ===========================================================================
//  components/Contenedor.tsx  -  EL ANCHO DE LAS PANTALLAS, EN UN SOLO SITIO
//
//  EL DEFECTO QUE ARREGLA (09/10/2026)
//
//  Jota: "en pc se vea normal y no un rectangulo en el medio".
//
//  Tenia razon y era literal: `mx-auto w-full max-w-md` aparecia 24 veces, y
//  448px es el ancho de un movil. En un monitor de 27 pulgadas, TODA la
//  aplicacion era una columna estrecha en el centro con dos desiertos a los
//  lados. No era una decision de diseno: era el ancho de movil aplicado a
//  todas las pantallas porque nadie miro nunca la version de escritorio.
//
//  LOS TRES ANCHOS, Y POR QUE TRES Y NO UNO
//
//    "lectura"  (max-w-md, 448px)  formularios y pantallas de una columna:
//                                  login, registro, recargar, retirar. Un
//                                  formulario ancho es PEOR de leer, no mejor:
//                                  el ojo pierde el renglon. Aqui 448 es
//                                  correcto y se queda.
//
//    "normal"   (max-w-3xl, 768px) el contenido con algo de estructura:
//                                  reglas, contactanos, la ficha de un remate.
//
//    "ancho"    (max-w-7xl, 1280px) tablas y paneles: el log, la contabilidad,
//                                  la lista de remates, crear remate. Son los
//                                  sitios donde el espacio de escritorio sirve
//                                  de verdad.
//
//  El padding lateral crece con la pantalla (4 -> 6 -> 8) para que el
//  contenido no quede pegado al borde en un monitor grande.
// ===========================================================================

type Ancho = "lectura" | "normal" | "ancho"

const ANCHOS: Record<Ancho, string> = {
  lectura: "max-w-md",
  normal: "max-w-3xl",
  ancho: "max-w-7xl",
}

export default function Contenedor({
  ancho = "normal",
  className = "",
  children,
}: {
  ancho?: Ancho
  className?: string
  children: React.ReactNode
}) {
  return (
    <div className={`mx-auto w-full ${ANCHOS[ancho]} px-4 sm:px-6 lg:px-8 ${className}`}>
      {children}
    </div>
  )
}
