// ===========================================================================
//  tests/log.mjs
//
//  PARA QUE: las dos funciones puras de app/admin/log/page.tsx que deciden lo
//  que acaba dentro de una consulta a PostgREST.
//
//  `limpiarBusqueda` NO es cosmetica. El filtro de texto se construye asi:
//
//      q.or(`descripcion.ilike.%${t}%,ref_externa.ilike.%${t}%`)
//
//  PostgREST lee ESA CADENA como sintaxis: la coma separa condiciones y los
//  parentesis agrupan. Un admin que busque "pago movil, 0412" parte el filtro
//  en tres trozos y la consulta falla; uno que escriba parentesis puede
//  cambiar el filtro entero por otro. No es inyeccion de SQL -PostgREST no
//  concatena SQL- pero si es inyeccion de FILTRO, y el resultado practico es
//  el mismo: el registro de auditoria devuelve algo distinto de lo que se
//  pidio, sin avisar. En un registro de auditoria eso es lo peor que puede
//  pasar: el que lo mira se queda convencido de que no hay nada.
//
//  `inicioDelDia` / `finDelDia` convierten el dia que escribe el admin en un
//  instante. Un fallo aqui tampoco se ve en pantalla: solo faltan filas.
//
//  COMO: se transpila el archivo REAL con TypeScript y se extraen sus
//  funciones del JS resultante. Sin copias: una copia se separa del original y
//  entonces la prueba miente. Mismo criterio que tests/fechas.mjs.
//
//  COMO SE CORRE, desde la raiz del repo:
//
//      node tests/log.mjs
// ===========================================================================

import fs from "fs"
import ts from "typescript"

const ARCHIVO = "app/admin/log/page.tsx"
const src = fs.readFileSync(ARCHIVO, "utf8")

const js = ts.transpileModule(src, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None, jsx: ts.JsxEmit.None },
}).outputText

const nombres = ["limpiarBusqueda", "inicioDelDia", "finDelDia"]

function saca(nombre) {
  const i = js.indexOf(`function ${nombre}(`)
  if (i < 0) throw new Error(`no se encontro ${nombre} en ${ARCHIVO}`)
  const j = js.indexOf("\n}\n", i) + 2
  return js.slice(i, j)
}

const f = new Function(nombres.map(saca).join("\n") + `\nreturn {${nombres.join(",")}}`)()

let fallos = 0
function ok(nombre, real, esperado) {
  const bien = JSON.stringify(real) === JSON.stringify(esperado)
  if (!bien) fallos++
  console.log(
    `${bien ? "ok   " : "FALLA"} ${nombre}: ${JSON.stringify(real)}` +
    (bien ? "" : `  <- esperado ${JSON.stringify(esperado)}`)
  )
}

// --- limpiarBusqueda: lo que rompe el filtro no puede llegar al filtro ------
ok("texto normal intacto", f.limpiarBusqueda("pago movil"), "pago movil")
ok("coma fuera",           f.limpiarBusqueda("pago movil, 0412"), "pago movil  0412")
ok("parentesis fuera",     f.limpiarBusqueda("juan(admin)"), "juan admin")
ok("comilla fuera",        f.limpiarBusqueda('el "jefe"'), "el  jefe")
ok("comodin fuera",        f.limpiarBusqueda("juan*"), "juan")
ok("porcentaje fuera",     f.limpiarBusqueda("50% casa"), "50  casa")
ok("barra fuera",          f.limpiarBusqueda("a\\b"), "a b")
ok("se recortan los bordes", f.limpiarBusqueda("   pedro   "), "pedro")
ok("solo basura queda vacio", f.limpiarBusqueda("(),*"), "")
ok("vacio sigue vacio",    f.limpiarBusqueda(""), "")

// Y lo que de verdad importa: que ningun caracter de sintaxis sobreviva.
const peligrosos = [",", "(", ")", "*", '"', "%", "\\"]
const sucio = 'juan, (admin) "jefe" 50% a\\b *'
const limpio = f.limpiarBusqueda(sucio)
ok("ningun caracter de sintaxis sobrevive",
   peligrosos.filter((c) => limpio.includes(c)), [])

// --- fechas del filtro -----------------------------------------------------
ok("sin fecha no hay limite (desde)", f.inicioDelDia(""), null)
ok("sin fecha no hay limite (hasta)", f.finDelDia(""), null)
ok("fecha invalida no inventa limite", f.inicioDelDia("no-es-fecha"), null)

const ini = f.inicioDelDia("2026-10-05")
const fin = f.finDelDia("2026-10-05")
ok("el inicio es un instante", typeof ini, "string")
ok("el fin es un instante", typeof fin, "string")
ok("el inicio va antes que el fin", new Date(ini) < new Date(fin), true)

// El rango de un dia tiene que durar un dia menos un milisegundo. Si durara
// mas, el filtro "hasta el 5" traeria filas del 6.
ok("el rango dura justo un dia",
   new Date(fin).getTime() - new Date(ini).getTime(), 24 * 60 * 60 * 1000 - 1)

// Y el inicio del dia siguiente tiene que caer DESPUES del fin del anterior,
// sin solaparse: dos dias consecutivos no pueden devolver la misma fila dos
// veces.
ok("dos dias seguidos no se solapan",
   new Date(f.inicioDelDia("2026-10-06")).getTime() > new Date(fin).getTime(), true)

console.log(fallos === 0 ? `\nTodo en verde.` : `\n${fallos} en rojo.`)
process.exit(fallos === 0 ? 0 : 1)
