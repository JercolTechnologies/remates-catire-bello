// app/reglas/page.tsx
//
// LO QUE EL JUGADOR ACEPTA ANTES DE PONER DINERO
//
// REESCRITA EL 05/10/2026, y no por estilo: la version anterior describia un
// modelo de dinero que la base habia dejado de implementar. Comprobado contra
// las migraciones, punto por punto:
//
//   decia                                        | la base, desde
//   ---------------------------------------------|------------------------
//   "cada puja bloquea saldo"                     | NO. 24/09, puja_sin_bloqueo
//   "el saldo no se libera hasta el cierre"       | no hay nada que liberar
//   "manual minimo = auto minimo + 10 Bs"         | NO. 23/09, reglas_primera_puja
//   "la casa retiene 25%"                         | es porcentaje_casa, por remate
//   "incrementos por rangos por defecto"          | NO. 30/09, escalera solo por caballo
//   (nada sobre la regla del 50% para retirar)    | SI se aplica desde el 01/10
//
// Lo ultimo era lo peor: la base aplicaba una regla que esta pagina no
// mencionaba, asi que el jugador se enteraba AL INTENTAR RETIRAR. El peor
// momento posible para leer una condicion.
//
// LOS NUMEROS NO SE CLAVAN. Se leen de `ajustes_publicos()`, que es una lista
// blanca sobre `ajustes_instalacion` (migracion 20261005140000). Un
// licenciatario que ponga el porcentaje en 30 tiene esta pagina diciendo 30,
// sin tocar codigo. Un numero clavado aqui seria una reclamacion esperando
// fecha.
//
// Y SI LOS AJUSTES NO SE PUEDEN LEER, NO SE INVENTA NINGUNO: se dice que no se
// pudieron cargar. Una pagina de condiciones que rellena huecos con suposiciones
// es peor que una que admite que le falta un dato.

"use client"

import { useEffect, useState } from "react"
import Link from "next/link"
import { CornerLogo } from "@/app/components/BrandLogo"
import { supabase } from "@/lib/supabaseClient"

function Bloque({ titulo, children }: { titulo: string; children: React.ReactNode }) {
  return (
    <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
      <h2 className="text-base font-semibold">{titulo}</h2>
      <div className="mt-2 text-sm text-zinc-300 space-y-2">{children}</div>
    </div>
  )
}

export default function ReglasPage() {
  const [ajustes, setAjustes] = useState<Record<string, string> | null>(null)
  const [fallo, setFallo] = useState(false)

  useEffect(() => {
    let vivo = true
    void (async () => {
      const { data, error } = await supabase.rpc("ajustes_publicos")
      if (!vivo) return
      if (error || !data) {
        console.warn("[reglas] no se pudieron leer los ajustes:", error?.message)
        setFallo(true)
        return
      }
      const mapa: Record<string, string> = {}
      for (const fila of data as { clave: string; valor: string }[]) mapa[fila.clave] = fila.valor
      setAjustes(mapa)
    })()
    return () => {
      vivo = false
    }
  }, [])

  const pct = ajustes?.pct_apostado_para_retirar
  const pctNum = pct === undefined ? null : Number(pct)
  const reglaDelPorcentajeAplica = pctNum !== null && Number.isFinite(pctNum) && pctNum > 0

  return (
    <main className="min-h-dvh bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-2xl">
        <div className="mb-3">
          <CornerLogo />
        </div>

        <div className="flex items-center justify-between">
          <h1 className="text-2xl font-bold">Reglas del Remate</h1>
          <Link href="/remates" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver a remates
          </Link>
        </div>

        <div className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4 text-sm text-zinc-200">
          Aquí está, completo, cómo funciona el dinero en este sistema: cuándo se te cobra, cuánto
          se queda la casa, y qué hace falta para poder retirar. Léelo antes de recargar.
        </div>

        {fallo ? (
          <div className="mt-4 rounded-2xl bg-amber-500/15 p-4 text-sm text-amber-100 ring-1 ring-amber-500/40">
            No se pudieron cargar las condiciones configurables de esta instalación. Los apartados
            que dependen de ellas aparecen marcados: <span className="font-semibold">pregunta por
            soporte antes de recargar</span> en vez de darlos por supuestos.
          </div>
        ) : null}

        <section className="mt-6 space-y-4">
          <Bloque titulo="1) Qué es un remate">
            <p>
              Cada remate corresponde a una carrera real. Mientras el remate está abierto, los
              usuarios pujan por cada caballo. Al cerrarse, cada caballo queda para quien hizo la
              puja más alta por él.
            </p>
          </Bloque>

          <Bloque titulo="2) Tipos de remate">
            <ul className="list-disc pl-5 space-y-1">
              <li>
                <span className="font-semibold">En vivo:</span> se usa el día de la carrera y cierra
                minutos antes de que empiece.
              </li>
              <li>
                <span className="font-semibold">Adelantado:</span> se abre días antes para pujar con
                anticipación.
              </li>
            </ul>
          </Bloque>

          <Bloque titulo="3) Horarios">
            <ul className="list-disc pl-5 space-y-1">
              <li>Todos los horarios se manejan en hora de Venezuela (America/Caracas).</li>
              <li>
                Un remate puede tener hora de apertura o no tenerla. Si no la tiene, está activo
                desde que se crea.
              </li>
              <li>
                El cierre puede ser automático a una hora fijada, o a mano. La{" "}
                <span className="font-semibold">liquidación nunca es automática</span>: la hace una
                persona después de la carrera.
              </li>
            </ul>
          </Bloque>

          <Bloque titulo="4) Cómo se puja">
            <ul className="list-disc pl-5 space-y-1">
              <li>
                <span className="font-semibold">Ponerle:</span> sube tu puja al mínimo permitido en
                ese momento.
              </li>
              <li>
                <span className="font-semibold">Manual:</span> escribes un monto y lo envías. El
                mínimo que acepta es el mismo que el automático; por encima, lo que quieras.
              </li>
              <li>
                Cada caballo sube según el incremento de su remate, o según su propia escalera de
                tramos si el organizador se la puso. El mínimo siguiente siempre está a la vista
                antes de pujar.
              </li>
            </ul>
          </Bloque>

          <Bloque titulo="5) Pujar NO te descuenta saldo">
            <p>
              Esto es lo que más se malentiende, así que va claro:{" "}
              <span className="font-semibold text-zinc-100">
                mientras el remate está abierto no se te cobra nada
              </span>
              . Tu saldo no baja al pujar.
            </p>
            <p>
              Lo que sí ocurre es que el dinero de las pujas que vas ganando queda{" "}
              <span className="font-semibold">comprometido</span>: no puedes retirarlo ni gastarlo
              dos veces. Si otro te supera, ese compromiso desaparece solo. Si retiran el caballo o
              se cancela el remate, también.
            </p>
            <p className="text-zinc-400">
              Por eso no existen «devoluciones» de pujas perdidas: al que pierde nunca se le quitó
              nada.
            </p>
          </Bloque>

          <Bloque titulo="6) Cuándo se te cobra">
            <p>
              <span className="font-semibold text-zinc-100">Al cerrar el remate</span>, y solo por
              los caballos que te quedaste. Ese es el único momento en que baja tu saldo por una
              puja.
            </p>
          </Bloque>

          <Bloque titulo="7) El pozo y lo que se queda la casa">
            <p>
              El pozo es la suma del precio final de cada caballo: la mejor puja, o su precio de
              salida si nadie pujó por él (en ese caso el caballo queda para la casa, que lo banca).
            </p>
            <p>
              La casa retiene un porcentaje del pozo y el resto es el premio.{" "}
              <span className="font-semibold">Ese porcentaje se fija por remate</span> y está
              siempre visible en la ficha del remate antes de que pujes. Si el caballo ganador había
              quedado para la casa, no hay premio que pagar.
            </p>
          </Bloque>

          <Bloque titulo="8) La liquidación">
            <p>
              Después de la carrera, el organizador marca el caballo ganador. Si ese caballo era
              tuyo, se te acredita el premio en el saldo. Caballo retirado no corre, así que no
              puede ganar.
            </p>
          </Bloque>

          <Bloque titulo="9) Para retirar: hay que haber jugado">
            {reglaDelPorcentajeAplica ? (
              <>
                <p>
                  Para poder retirar tienes que haber apostado al menos el{" "}
                  <span className="font-semibold text-zinc-100">{pct}%</span> del total que has
                  recargado. Es una medida contra el uso del sistema como forma de mover dinero sin
                  jugar, y la aplican todas las casas serias.
                </p>
                <ul className="list-disc pl-5 space-y-1">
                  <li>Cuenta la puja más alta que hiciste por cada caballo, en cada remate.</li>
                  <li>
                    <span className="font-semibold">Lo que hayas ganado en premios queda exento</span>
                    : eso lo puedes retirar siempre, aunque no llegues al porcentaje.
                  </li>
                  <li>
                    Una recarga nueva sube el total a cubrir, también sobre el saldo que ya tenías.
                  </li>
                  <li>
                    En la pantalla de retirar ves en todo momento cuánto te falta por apostar.
                  </li>
                </ul>
              </>
            ) : pctNum === 0 ? (
              <p>En esta instalación no hay requisito de apuesta para retirar.</p>
            ) : (
              <p className="text-amber-200">
                No se pudo cargar el requisito de apuesta de esta instalación. Consúltalo con
                soporte antes de recargar.
              </p>
            )}
            <p className="text-zinc-400">
              Aparte de esto, nunca puedes retirar el dinero que tengas comprometido en pujas que
              estás ganando ahora mismo (apartado 5).
            </p>
          </Bloque>

          <Bloque titulo="10) Recargas y retiros">
            <ul className="list-disc pl-5 space-y-1">
              <li>
                Las recargas y los retiros los revisa una persona. No son instantáneos.
              </li>
              <li>
                Si te rechazan una solicitud,{" "}
                <span className="font-semibold">se te dice el motivo</span>, y lo ves en la misma
                pantalla donde la pediste.
              </li>
              <li>Un retiro rechazado te devuelve el dinero al saldo.</li>
            </ul>
          </Bloque>

          <Bloque titulo="11) Transparencia">
            <p>
              Las pujas son públicas: se ve el nombre de usuario de quien va ganando cada caballo.
              No se muestra ningún otro dato tuyo — ni correo, ni teléfono, ni identificación.
            </p>
            <p>
              Toda operación sobre tu dinero queda registrada con fecha, importe y quién la hizo.
            </p>
          </Bloque>
        </section>

        <p className="mt-6 text-[11px] text-zinc-600">
          Si algo de esta página no coincide con lo que ves en la aplicación, no juegues y avisa:
          una regla que no coincide con la pantalla es un error nuestro, no tuyo.
        </p>
      </div>
    </main>
  )
}
