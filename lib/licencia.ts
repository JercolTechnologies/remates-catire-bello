// ===========================================================================
//  lib/licencia.ts  -  EL INTERRUPTOR DE LA LICENCIA
//
//  QUE HACE (24/10/2026, ADR-053)
//
//  Responde una sola pregunta: esta instalacion tiene la licencia al dia. Si la
//  respuesta es que no, `app/layout.tsx` no pinta la aplicacion: pinta una
//  pantalla que dice por que esta cerrada y a quien hay que escribir.
//
//  POR QUE EN UNA VARIABLE DE ENTORNO Y NO EN LA BASE
//
//  Porque el interruptor no puede vivir dentro de la cosa que quiza hay que
//  apagar. Si el cobro se corta y ademas el proyecto de Supabase esta pausado,
//  una bandera guardada en `ajustes_instalacion` no se puede leer justo cuando
//  hace falta. Una variable de entorno se lee del proceso: no hace red, no
//  consulta nada y no falla.
//
//  Y porque nadie mas la puede tocar. `ajustes_instalacion` la escribe el super
//  admin de la casa a traves de una RPC (ADR-047); una clave de licencia en esa
//  tabla seria una clave que el licenciatario podria devolver a "activa" desde
//  su propio panel. Esto vive en el despliegue, que es de la plataforma.
//
//  EL COSTE, DICHO CLARO: las paginas se generan en el build, asi que cambiar
//  la variable NO surte efecto hasta el siguiente despliegue (un minuto en
//  Vercel). Es el precio de que la pagina siga siendo estatica y de que el
//  interruptor no dependa de la red. Ver `docs/LICENCIA_SUSPENSION.md`.
//
//  SI NO HAY NADA CONFIGURADO, LA LICENCIA ESTA ACTIVA. Siempre. Un error de
//  dedo escribiendo la variable no puede dejar a un cliente que paga con la
//  web en blanco; al reves, un corte que no se aplica se nota en el acto.
// ===========================================================================

export type EstadoLicencia = {
  /** true = la instalacion queda cerrada al publico. */
  suspendida: boolean
  /** Lo que se lee en la pantalla de suspension. */
  aviso: string
}

/** Lo que se lee si `LICENCIA_AVISO` esta vacia. Jota lo queria con esas
 *  palabras: primero el hecho, despues la salida. */
const AVISO_POR_DEFECTO =
  "La licencia de esta instalación está suspendida. Si eres el administrador de la casa, " +
  "ponte en contacto con los administradores de la plataforma para regularizar la situación."

/** Lo que se acepta como "si". Se tolera lo que la gente escribe de verdad
 *  (`1`, `SI`, `true`) porque escribir mal esto NO debe activar el bloqueo. */
const AFIRMATIVOS = new Set(["1", "true", "si", "sí", "suspendida"])

export function estadoDeLicencia(): EstadoLicencia {
  const crudo = (process.env.LICENCIA_SUSPENDIDA ?? "").trim().toLowerCase()

  return {
    suspendida: AFIRMATIVOS.has(crudo),
    aviso: (process.env.LICENCIA_AVISO ?? "").trim() || AVISO_POR_DEFECTO,
  }
}
