// ===========================================================================
//  tests/aviso_puja.mjs
//
//  PARA QUE: el aviso que sale ANTES de pujar (07/10/2026). Dos piezas:
//
//    1. `intencionDePuja` en app/remates/[id]/page.tsx -- que monto se va a
//       ofrecer y, si algo esta mal, decirlo EN VIVO. Hasta hoy el aviso de
//       "muy poco" salia despues de apretar el boton.
//
//    2. `cuentasDelAviso` en app/components/ConfirmarPuja.tsx -- como le queda
//       el saldo al jugador si confirma.
//
//  POR QUE HACE FALTA UNA PRUEBA: son numeros que el compilador tipa bien y
//  que en pantalla se leen plausibles. El caso que mas duele -- el jugador que
//  YA lidera el caballo -- es justo el que no se ve mirando: subir la propia
//  puja la REEMPLAZA, no la suma, y si esto lo sumara, el aviso le diria que
//  no le alcanza a alguien a quien si le alcanza. Ese error ya se cometio una
//  vez en esta pantalla (defecto R4: se restaba la puja mas alta historica en
//  vez de la que lidera ahora).
//
//  LO QUE ESTA PRUEBA NO ES: no comprueba ninguna regla de dinero. Las reglas
//  viven en la base (hacer_puja, remate_minimos, compromiso_usuario) y las
//  cubre tests/pruebas_dinero.sql. Aqui se comprueba que la PANTALLA ensena
//  bien lo que la base ya dijo.
//
//  COMO: se transpilan los archivos REALES con el propio TypeScript y se
//  extraen sus funciones del JS resultante. No hay copias aqui, a proposito:
//  una copia se separa del original y entonces la prueba miente. Mismo
//  criterio que tests/fechas.mjs y tests/log.mjs.
//
//  COMO SE CORRE, desde la raiz del repo:
//
//      node tests/aviso_puja.mjs
//
//  Sale 0 si todo esta en verde y 1 si algo falla, asi que vale para CI.
// ===========================================================================

import fs from "fs"
import ts from "typescript"

function transpila(archivo) {
  return ts.transpileModule(fs.readFileSync(archivo, "utf8"), {
    compilerOptions: {
      target: ts.ScriptTarget.ES2020,
      module: ts.ModuleKind.None,
      jsx: ts.JsxEmit.None,
    },
  }).outputText
}

function saca(js, archivo, nombre) {
  const i = js.indexOf(`function ${nombre}(`)
  if (i < 0) throw new Error(`no se encontro ${nombre} en ${archivo}`)
  const j = js.indexOf("\n}\n", i) + 2
  return js.slice(i, j)
}

const PANTALLA = "app/remates/[id]/page.tsx"
const AVISO = "app/components/ConfirmarPuja.tsx"

const jsPantalla = transpila(PANTALLA)
const jsAviso = transpila(AVISO)

const dePantalla = ["n", "parseAmount", "formatMoney", "intencionDePuja"]
const deAviso = ["cuentasDelAviso"]

const f = new Function(
  dePantalla.map((x) => saca(jsPantalla, PANTALLA, x)).join("\n") +
    "\n" +
    deAviso.map((x) => saca(jsAviso, AVISO, x)).join("\n") +
    `\nreturn {${[...dePantalla, ...deAviso].join(",")}}`
)()

let fallos = 0
function ok(nombre, real, esperado) {
  const bien = JSON.stringify(real) === JSON.stringify(esperado)
  if (!bien) fallos++
  console.log(
    `${bien ? "ok   " : "FALLA"} ${nombre}: ${JSON.stringify(real)}` +
      (bien ? "" : `  <- esperado ${JSON.stringify(esperado)}`)
  )
}

// ===========================================================================
//  1) QUE PUJA SE INTENTA
//
//  Firma: intencionDePuja(loQueEscribio, minimoAuto, minimoManual).
//  Hoy remate_minimos() devuelve el MISMO numero en las dos columnas, pero la
//  pantalla no lo da por hecho: las pasa por separado.
// ===========================================================================

ok("campo vacio -> la automatica, al minimo de la base",
  f.intencionDePuja("", 1650, 1650),
  { monto: 1650, esManual: false, problema: null })

ok("solo espacios cuenta como vacio",
  f.intencionDePuja("   ", 1650, 1650),
  { monto: 1650, esManual: false, problema: null })

ok("monto exacto al minimo es valido",
  f.intencionDePuja("1650", 1650, 1650),
  { monto: 1650, esManual: true, problema: null })

ok("monto por encima es valido",
  f.intencionDePuja("2000", 1650, 1650),
  { monto: 2000, esManual: true, problema: null })

ok("un centimo por debajo NO pasa",
  f.intencionDePuja("1649.99", 1650, 1650),
  { monto: 1649.99, esManual: true, problema: "Muy poco: ahora el mínimo son 1.650,00 Bs." })

ok("coma decimal, como la escribe un venezolano",
  f.intencionDePuja("1650,50", 1650, 1650),
  { monto: 1650.5, esManual: true, problema: null })

ok("texto que no es numero",
  f.intencionDePuja("mil", 1650, 1650).problema,
  "Ese monto no se entiende: escribe solo números.")

ok("texto que no es numero: monto NaN",
  Number.isNaN(f.intencionDePuja("mil", 1650, 1650).monto),
  true)

ok("negativo se trata como muy poco, no como basura",
  f.intencionDePuja("-500", 1650, 1650).problema,
  "Muy poco: ahora el mínimo son 1.650,00 Bs.")

ok("cero tambien",
  f.intencionDePuja("0", 1650, 1650).problema,
  "Muy poco: ahora el mínimo son 1.650,00 Bs.")

// Caballo virgen: se toma AL precio de salida, sin incremento (hacer_puja
// paso 5). El minimo que llega es el precio de salida pelado.
ok("caballo virgen: la automatica es el precio de salida",
  f.intencionDePuja("", 100, 100),
  { monto: 100, esManual: false, problema: null })

// Si algun dia las dos columnas de remate_minimos() se separan, el campo
// manual tiene que respetar SU minimo, no el del boton.
ok("minimos distintos: manda el manual",
  f.intencionDePuja("1700", 1650, 1800).problema,
  "Muy poco: ahora el mínimo son 1.800,00 Bs.")

// ===========================================================================
//  2) COMO QUEDA EL SALDO
// ===========================================================================

// Caso corriente: 5.000 de saldo, 1.000 comprometidos en otro caballo, puja
// de 1.650.
ok("saldo de sobra",
  f.cuentasDelAviso({
    monto: 1650, minimoAuto: 1650, saldoTotal: 5000, comprometidoSinEste: 1000,
  }),
  { comprometidoDespues: 2650, libreDespues: 2350, alcanza: true, demas: 0, muyPoco: false })

ok("justo al limite: alcanza",
  f.cuentasDelAviso({
    monto: 1650, minimoAuto: 1650, saldoTotal: 2650, comprometidoSinEste: 1000,
  }),
  { comprometidoDespues: 2650, libreDespues: 0, alcanza: true, demas: 0, muyPoco: false })

ok("un centimo de menos: NO alcanza",
  f.cuentasDelAviso({
    monto: 1650, minimoAuto: 1650, saldoTotal: 2649.99, comprometidoSinEste: 1000,
  }).alcanza,
  false)

ok("cuanto falta cuando no alcanza",
  f.cuentasDelAviso({
    monto: 1650, minimoAuto: 1650, saldoTotal: 2000, comprometidoSinEste: 1000,
  }).libreDespues,
  -650)

// EL CASO QUE NO SE VE MIRANDO. El jugador lidera este caballo con 1.500 y
// sube a 1.650. Su compromiso total es 2.500 (1.500 aqui + 1.000 en otro),
// pero la puja nueva REEMPLAZA la suya: `comprometidoSinEste` llega en 1.000.
// Con 2.700 de saldo le alcanza de sobra. Si esto sumara, diria que no.
ok("subir mi propia puja: reemplaza, no suma",
  f.cuentasDelAviso({
    monto: 1650, minimoAuto: 1650, saldoTotal: 2700, comprometidoSinEste: 1000,
  }),
  { comprometidoDespues: 2650, libreDespues: 50, alcanza: true, demas: 0, muyPoco: false })

ok("si sumara la propia (2500+1650) no alcanzaria -- esto comprueba que NO suma",
  f.cuentasDelAviso({
    monto: 1650, minimoAuto: 1650, saldoTotal: 2700, comprometidoSinEste: 2500,
  }).alcanza,
  false)

ok("manual por encima: cuanto pone de mas",
  f.cuentasDelAviso({
    monto: 2000, minimoAuto: 1650, saldoTotal: 5000, comprometidoSinEste: 0,
  }).demas,
  350)

// El precio subio con el cuadro abierto: lo escrito a mano se quedo corto.
ok("se quedo corta mientras mirabas",
  f.cuentasDelAviso({
    monto: 1650, minimoAuto: 1800, saldoTotal: 5000, comprometidoSinEste: 0,
  }).muyPoco,
  true)

ok("al dia: no esta corta",
  f.cuentasDelAviso({
    monto: 1800, minimoAuto: 1800, saldoTotal: 5000, comprometidoSinEste: 0,
  }).muyPoco,
  false)

// CENTIMOS. En la base el dinero es numeric(12,2) y la cuenta es exacta; en
// JS son dobles. Estos tres casos daban falso negativo con la resta directa:
// 1,10 + 2,20 = 3,3000000000000003 en JS, asi que con 3,30 de saldo justo el
// aviso decia "no te alcanza, te faltan -0,00 Bs" y desactivaba el boton de
// alguien a quien la base se lo habria aceptado.
ok("centimos: 1,10 + 2,20 contra 3,30 alcanza",
  f.cuentasDelAviso({
    monto: 2.2, minimoAuto: 2.2, saldoTotal: 3.3, comprometidoSinEste: 1.1,
  }).alcanza,
  true)

ok("centimos: y el libre sale 0 limpio, no -0,00",
  f.cuentasDelAviso({
    monto: 2.2, minimoAuto: 2.2, saldoTotal: 3.3, comprometidoSinEste: 1.1,
  }).libreDespues,
  0)

ok("centimos: 10,10 + 20,20 contra 30,30 alcanza",
  f.cuentasDelAviso({
    monto: 20.2, minimoAuto: 20.2, saldoTotal: 30.3, comprometidoSinEste: 10.1,
  }).alcanza,
  true)

ok("centimos: 0,07 + 0,01 contra 0,08 alcanza",
  f.cuentasDelAviso({
    monto: 0.01, minimoAuto: 0.01, saldoTotal: 0.08, comprometidoSinEste: 0.07,
  }),
  { comprometidoDespues: 0.08, libreDespues: 0, alcanza: true, demas: 0, muyPoco: false })

ok("centimos: un centimo de verdad por debajo sigue siendo NO",
  f.cuentasDelAviso({
    monto: 2.2, minimoAuto: 2.2, saldoTotal: 3.29, comprometidoSinEste: 1.1,
  }),
  { comprometidoDespues: 3.3, libreDespues: -0.01, alcanza: false, demas: 0, muyPoco: false })

// ===========================================================================
//  3) EL FORMATO, que es lo que el jugador lee
// ===========================================================================

ok("miles con punto y decimales con coma", f.formatMoney(1650), "1.650,00")
ok("millon", f.formatMoney(1234567.89), "1.234.567,89")
ok("cero", f.formatMoney(0), "0,00")
ok("string de la base (numeric llega como texto)", f.formatMoney("1650.5"), "1.650,50")
ok("null no rompe", f.formatMoney(null), "0,00")

console.log("")
console.log(fallos === 0 ? `TODO EN VERDE` : `${fallos} FALLO(S)`)
process.exit(fallos === 0 ? 0 : 1)
