// ===========================================================================
//  app/components/ConfirmarPuja.tsx  -  EL AVISO ANTES DE PUJAR
//
//  POR QUE EXISTE (07/10/2026)
//
//  Hasta hoy el boton decia "Ponerle", sin cifra. El jugador veia "Va
//  ganando 1.500 Bs", apretaba, y quedaba comprometido con 1.650 Bs sin que
//  nadie le hubiera dicho nunca ese numero. El unico sitio donde aparecia
//  era un renglon gris de 11px rotulado "Puja manual minima", debajo del
//  campo de monto manual: se lee como la etiqueta del campo, no como el
//  precio del boton de al lado.
//
//  Y cuando el monto manual no llegaba al minimo, el aviso salia DESPUES de
//  apretar, como un error rojo arriba de la pantalla. El orden estaba al
//  reves: primero el intento, luego la informacion con la que se decide.
//
//  app/reglas/page.tsx ya promete, textual, que "el minimo siguiente siempre
//  esta a la vista antes de pujar". Esta pantalla no cumplia esa frase.
//
//  QUE HACE Y QUE NO HACE
//
//  No calcula NADA. Cada cifra llega resuelta desde la pantalla, que a su vez
//  las lee de remate_minimos() (ADR-008, ADR-015). La unica aritmetica es
//  presentacion: sumar el compromiso que ya tiene el usuario con el de esta
//  puja para decirle como le queda el saldo. Si algun dia la base y esto
//  discrepan, manda la base y esto esta mal.
//
//  Tampoco es un "¿estas seguro?". Un cuadro que solo pregunta eso se
//  responde que si sin leerlo. Este ENSENA el precio actual, el incremento y
//  el total, y como queda el saldo despues -- que es lo que el jugador
//  necesita para decidir si puja o lo deja ahi.
// ===========================================================================

"use client"

export type PujaPropuesta = {
  horseId: string
  numero: number
  nombre: string
  // Lo que dice remate_minimos() de este caballo.
  hayPujas: boolean
  montoActual: number
  incremento: number
  minimoAuto: number
  soyLider: boolean
  liderLabel: string
  // Lo que se va a ofrecer y como se llego a ese monto.
  monto: number
  esManual: boolean
  // El saldo, ya resuelto por la pantalla con mi_wallet_resumen().
  saldoTotal: number
  comprometidoSinEste: number
  // Lo pone la pantalla cuando los minimos se movieron con el cuadro ya
  // abierto: alguien pujo mientras el jugador leia.
  cambio?: string
}

// LAS CUENTAS DEL AVISO, aparte y sin JSX, para que tests/aviso_puja.mjs las
// pueda correr de verdad en vez de mirarlas.
//
// Esto NO es una regla de dinero: la regla la aplica hacer_puja (guarda de
// exposicion) y el compromiso lo calcula compromiso_usuario() en la base. Aqui
// solo se suma lo que la base ya dijo, para poder ensenarle al jugador como le
// queda el saldo ANTES de apretar. Si discrepan, manda la base.
export function cuentasDelAviso(p: {
  monto: number
  minimoAuto: number
  saldoTotal: number
  comprometidoSinEste: number
}) {
  // TODO EN CENTIMOS ENTEROS, y no es manias.
  //
  // En la base todo el dinero es numeric(12,2): dos decimales exactos, nunca
  // mas. En JavaScript son dobles, y ahi 1,10 + 2,20 da 3,3000000000000003.
  // Con 3,30 de saldo justo, `3.30 - (1.10 + 2.20) >= 0` sale FALSO: el aviso
  // le diria "no te alcanza, te faltan -0,00 Bs" y le desactivaria el boton a
  // alguien a quien le alcanza exacto. Y la base se lo habria aceptado, porque
  // alla la cuenta es exacta.
  //
  // Pasar a centimos enteros antes de sumar hace que esta cuenta sea la misma
  // que la de la base, al centimo. Las unidades vuelven a bolivares al final,
  // que es como se ensenan.
  const cent = (x: number) => Math.round(x * 100)

  const saldo = cent(p.saldoTotal)
  const yaComprometido = cent(p.comprometidoSinEste)
  // Subir la propia puja la REEMPLAZA, no la suma: `comprometidoSinEste` ya
  // viene con la de este caballo descontada (lo hace la pantalla, igual que
  // hacer_puja).
  const esta = cent(p.monto)
  const libre = saldo - yaComprometido - esta

  return {
    comprometidoDespues: (yaComprometido + esta) / 100,
    libreDespues: libre / 100,
    alcanza: libre >= 0,
    // Cuanto pone por encima del minimo, en la puja manual.
    demas: (esta - cent(p.minimoAuto)) / 100,
    // Si el precio subio con el cuadro abierto, lo escrito a mano puede
    // haberse quedado corto. La base lo rechazaria; mejor decirlo aqui.
    muyPoco: esta < cent(p.minimoAuto),
  }
}

function bs(v: number) {
  return v.toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

export default function ConfirmarPuja({
  propuesta,
  enviando,
  onConfirmar,
  onCancelar,
}: {
  propuesta: PujaPropuesta
  enviando: boolean
  onConfirmar: () => void
  onCancelar: () => void
}) {
  const p = propuesta

  const { comprometidoDespues, libreDespues, alcanza, demas, muyPoco } = cuentasDelAviso(p)

  return (
    <div className="fixed inset-0 z-[90] flex items-end justify-center bg-black/70 p-4 sm:items-center">
      <div className="w-full max-w-md rounded-2xl border border-zinc-700 bg-zinc-900 p-5 shadow-2xl max-h-[90vh] overflow-y-auto">
        <div className="text-xs text-zinc-500">
          Caballo #{p.numero} · {p.nombre}
        </div>
        <div className="mt-1 text-lg font-bold text-zinc-50">
          Vas a ofrecer {bs(p.monto)} Bs
        </div>

        {p.cambio ? (
          <div className="mt-3 rounded-xl bg-amber-500/10 p-3 text-xs text-amber-200 ring-1 ring-amber-500/20">
            {p.cambio}
          </div>
        ) : null}

        {/* COMO SE LLEGA A ESE NUMERO. La cuenta a la vista, no el resultado
            solo: el jugador que ve el incremento entiende por que la proxima
            puja cuesta lo que cuesta. */}
        <div className="mt-4 rounded-xl border border-zinc-800 bg-zinc-950/60 p-3">
          {p.hayPujas ? (
            <>
              <div className="flex items-baseline justify-between">
                <span className="text-sm text-zinc-300">
                  Va ganando {p.soyLider ? "(tú)" : p.liderLabel ? `(${p.liderLabel})` : ""}
                </span>
                <span className="text-sm font-semibold tabular-nums text-amber-300">
                  {bs(p.montoActual)} Bs
                </span>
              </div>
              <div className="mt-1 flex items-baseline justify-between">
                <span className="text-sm text-zinc-300">Incremento</span>
                <span className="text-sm font-semibold tabular-nums text-zinc-100">
                  + {bs(p.incremento)} Bs
                </span>
              </div>
              <div className="mt-2 border-t border-zinc-800 pt-2 flex items-baseline justify-between">
                <span className="text-sm text-zinc-200">
                  {p.esManual ? "Tu oferta" : "Mínimo siguiente"}
                </span>
                <span className="text-base font-bold tabular-nums text-zinc-50">
                  {bs(p.monto)} Bs
                </span>
              </div>
              {p.esManual && demas > 0 ? (
                <div className="mt-1 text-[11px] text-zinc-500">
                  Estás poniendo {bs(demas)} Bs por encima del mínimo ({bs(p.minimoAuto)} Bs).
                </div>
              ) : null}
            </>
          ) : (
            <>
              <div className="text-sm text-zinc-300">
                Nadie ha pujado por este caballo todavía, así que lo tomas en su precio de
                salida: no se le suma incremento.
              </div>
              <div className="mt-2 border-t border-zinc-800 pt-2 flex items-baseline justify-between">
                <span className="text-sm text-zinc-200">
                  {p.esManual ? "Tu oferta" : "Precio de salida"}
                </span>
                <span className="text-base font-bold tabular-nums text-zinc-50">
                  {bs(p.monto)} Bs
                </span>
              </div>
              {p.esManual && demas > 0 ? (
                <div className="mt-1 text-[11px] text-zinc-500">
                  Estás poniendo {bs(demas)} Bs por encima del precio de salida (
                  {bs(p.minimoAuto)} Bs).
                </div>
              ) : null}
            </>
          )}
        </div>

        {p.soyLider ? (
          <div className="mt-2 rounded-xl bg-amber-500/10 p-3 text-xs text-amber-200 ring-1 ring-amber-500/20">
            Este caballo ya lo vas ganando tú. Subir tu propia puja la reemplaza, no la suma:
            quedarías comprometido con {bs(p.monto)} Bs, no con {bs(p.montoActual + p.monto)} Bs.
          </div>
        ) : null}

        {/* COMO QUEDA EL SALDO. El "no te alcanza" se dice AQUI, antes de
            apretar, no como error despues del intento. La base vuelve a
            comprobarlo igual (guarda de exposicion en hacer_puja): esto es
            informacion, no la regla. */}
        <div className="mt-2 rounded-xl border border-zinc-800 bg-zinc-950/60 p-3">
          <div className="text-xs text-zinc-500">Cómo te queda el saldo</div>
          <div className="mt-2 flex items-baseline justify-between">
            <span className="text-sm text-zinc-300">Tienes</span>
            <span className="text-sm font-semibold tabular-nums text-zinc-100">
              {bs(p.saldoTotal)} Bs
            </span>
          </div>
          <div className="mt-1 flex items-baseline justify-between">
            <span className="text-sm text-zinc-300">Quedaría comprometido en pujas</span>
            <span className="text-sm font-semibold tabular-nums text-amber-300">
              {bs(comprometidoDespues)} Bs
            </span>
          </div>
          <div className="mt-1 flex items-baseline justify-between">
            <span className="text-sm text-zinc-300">Te quedaría libre</span>
            <span
              className={`text-sm font-semibold tabular-nums ${
                alcanza ? "text-emerald-300" : "text-red-300"
              }`}
            >
              {bs(libreDespues)} Bs
            </span>
          </div>
        </div>

        {muyPoco ? (
          <div className="mt-2 rounded-xl bg-red-500/10 p-3 text-xs text-red-200 ring-1 ring-red-500/20">
            Tu oferta de {bs(p.monto)} Bs ya no alcanza: el mínimo ahora son {bs(p.minimoAuto)} Bs.
            Cierra este aviso y escribe un monto nuevo.
          </div>
        ) : null}

        {!alcanza ? (
          <div className="mt-2 rounded-xl bg-red-500/10 p-3 text-xs text-red-200 ring-1 ring-red-500/20">
            No te alcanza para esta puja. Te faltan {bs(-libreDespues)} Bs: tienes{" "}
            {bs(p.saldoTotal)} Bs y {bs(p.comprometidoSinEste)} Bs ya comprometidos en otras pujas
            que vas ganando.
          </div>
        ) : null}

        <div className="mt-3 text-[11px] text-zinc-500">
          Pujar no te descuenta nada ahora: tu saldo no baja mientras el remate está abierto.
          El dinero solo queda comprometido, y se cobra al cerrar, únicamente por los caballos
          que te quedaste. Si otro te supera, el compromiso desaparece solo.
        </div>

        <div className="mt-4 flex gap-2">
          <button
            onClick={onConfirmar}
            disabled={enviando || !alcanza || muyPoco}
            className="flex-1 rounded-xl bg-white px-3 py-2 text-sm font-semibold text-zinc-950 disabled:opacity-60"
          >
            {enviando ? "Pujando..." : `Pujar ${bs(p.monto)} Bs`}
          </button>
          <button
            onClick={onCancelar}
            disabled={enviando}
            className="rounded-xl border border-zinc-700 bg-zinc-950/60 px-3 py-2 text-sm text-zinc-200 disabled:opacity-60"
          >
            Dejarlo así
          </button>
        </div>
      </div>
    </div>
  )
}
