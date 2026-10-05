"use client"

import { useEffect, useRef } from "react"
import { supabase } from "./supabaseClient"

/**
 * SUSCRIPCION A LAS SENALES DE LA BASE
 *
 * El evento que llega es una SENAL, no el dato: dice "algo cambio en el
 * remate X" y nada mas. Quien lo recibe vuelve a preguntarle a la base.
 *
 * Eso no es un rodeo, es el ADR-015. Si el evento trajera la puja, esta
 * pantalla tendria que recalcular el minimo siguiente, quien lidera y el
 * precio actual a partir de ella — o sea, reimplementar en TypeScript lo que
 * hace `_incremento_aplicable` en la base. Ese defecto ya ocurrio el 23/09:
 * la pantalla mostraba un numero y la base cobraba otro.
 *
 * Aqui no puede pasar, porque la pantalla nunca calcula: pregunta.
 *
 * Ver la migracion 20260930120000_realtime_senales.sql.
 */

/** Lo que puede cambiar dentro de un remate. */
export const EVENTOS_REMATE = ["puja", "remate", "aviso", "caballo"] as const

/** Lo que puede cambiar en la caja: solo lo ven los admins. */
export const EVENTOS_CAJA = ["recarga", "retiro"] as const

export function topicoRemate(remateId: string) {
  return `remate:${remateId}`
}

export const TOPICO_CAJA = "admin:caja"

/**
 * Escucha un canal y llama a `alRecibir` cuando llega cualquiera de `eventos`.
 *
 * - `topico` en null desactiva la suscripcion (util mientras no se sabe el id).
 * - Las senales se agrupan: una rafaga de pujas provoca UNA recarga, no diez.
 * - Si la suscripcion se cae, se vuelve a levantar sola y se recarga al
 *   volver, porque mientras no habia canal pudo pasar cualquier cosa.
 * - Todo estado del canal queda escrito en la consola, no solo los fallos.
 *
 * ========================================================================
 *  POR QUE ESTO NO ES UNA SUSCRIPCION Y YA  (05/10/2026)
 *
 *  Jota dejo /admin/retiros abierta en una pestana de atras, creo dos
 *  solicitudes desde otra, y la lista no se movio. La consola decia:
 *
 *      [realtime] admin:caja: SUBSCRIBED
 *      [realtime] admin:caja <- retiro
 *      [realtime] admin:caja <- retiro
 *      [realtime] admin:caja: CLOSED
 *
 *  Los dos eventos LLEGARON. La emision, la politica y la entrega estaban
 *  bien -- quedaron comprobadas una por una, ver ADR-024. Lo que fallo fue
 *  lo de despues, y son dos cosas que el navegador hace a proposito:
 *
 *   1. UNA PESTANA DE ATRAS SE CONGELA. Chrome estrangula los `setTimeout`
 *      de una pestana oculta y, pasados unos minutos, la congela entera. El
 *      temporizador de 250 ms que agrupa las senales puede no llegar a
 *      dispararse nunca. El evento entra y la recarga no sale.
 *
 *   2. EL SOCKET SE CIERRA. Ese `CLOSED` del final no lo pidio nadie: lo
 *      cerro el navegador. Y la version anterior de este hook no hacia nada
 *      con el, asi que la pantalla se quedaba muda para siempre, con pinta
 *      de estar escuchando. Ese es el peor estado posible: el admin cree
 *      que esta viendo la caja en vivo y esta mirando una foto.
 *
 *  LA REGLA QUE SALE DE AQUI: una suscripcion en tiempo real no es
 *  "suscribirse". Es suscribirse, DARSE CUENTA de que se cayo, volver a
 *  levantarla, y RECARGAR al volver -- porque mientras no se escuchaba pudo
 *  pasar cualquier cosa y ningun evento se reenvia.
 *
 *  Por eso al volver al frente se recarga SIEMPRE, aunque el canal siguiera
 *  vivo. Una consulta de mas no le cuesta nada a nadie; una solicitud de
 *  retiro que el admin no ve, si.
 * ========================================================================
 *
 * Ver la migracion 20260930120000_realtime_senales.sql y el ADR-024.
 */
export function useSenal(
  topico: string | null,
  eventos: readonly string[],
  alRecibir: () => void,
  esperaMs = 250,
) {
  // La referencia evita volver a suscribirse cada vez que el componente
  // vuelve a renderizar y crea una funcion nueva.
  const cb = useRef(alRecibir)
  cb.current = alRecibir

  const listaEventos = eventos.join(",")

  useEffect(() => {
    // La guarda va ANTES, y la constante lleva el tipo escrito.
    //
    // TypeScript no arrastra el estrechamiento de una variable al interior de
    // una funcion anidada, ni siquiera si es `const`. Escribir
    // `const t = topico; if (!t) return;` y usar `t` dentro de `arrancar`
    // falla con "Type 'null' is not assignable to type 'string'".
    // Comprobado con tsc --strict el 30/09, despues de equivocarme dos veces
    // razonandolo de cabeza.
    if (!topico) return
    const canalTopico: string = topico

    let cancelado = false
    let temporizador: ReturnType<typeof setTimeout> | null = null
    let reintento: ReturnType<typeof setTimeout> | null = null
    let canal: ReturnType<typeof supabase.channel> | null = null
    let intentos = 0
    // Un `removeChannel` nuestro tambien dispara CLOSED. Sin esta bandera, el
    // propio cierre ordenado programaria una reconexion contra un canal que
    // acabamos de tirar a proposito.
    let cerrandoAProposito = false

    function agrupar() {
      if (cancelado) return
      if (temporizador) clearTimeout(temporizador)
      temporizador = setTimeout(() => {
        if (!cancelado) cb.current()
      }, esperaMs)
    }

    function programarReintento(motivo: string) {
      if (cancelado || cerrandoAProposito || reintento) return
      // Espera creciente, con techo. Si el servicio esta caido, insistir cada
      // segundo no lo levanta y si gasta bateria y conexion del admin.
      const espera = Math.min(30000, 1000 * Math.pow(2, intentos))
      intentos += 1
      console.warn(`[realtime] ${canalTopico}: ${motivo}, reintento en ${espera} ms`)
      reintento = setTimeout(() => {
        reintento = null
        void reconectar()
      }, espera)
    }

    async function reconectar() {
      if (cancelado) return
      if (canal) {
        const viejo = canal
        canal = null
        cerrandoAProposito = true
        try {
          await supabase.removeChannel(viejo)
        } catch {
          // Que no se pueda cerrar el canal viejo no puede impedir abrir uno
          // nuevo: el objetivo es volver a escuchar, no dejarlo todo limpio.
        }
        cerrandoAProposito = false
      }
      if (cancelado) return
      await arrancar()
      // Mientras no habia canal pudo entrar cualquier cosa, y los eventos
      // perdidos NO se reenvian. La unica forma de ponerse al dia es preguntar.
      agrupar()
    }

    async function arrancar() {
      if (cancelado) return

      // Pone el token de la sesion (o la clave anonima) en el socket. Sin
      // esto un canal privado no autoriza y no llega nada.
      try {
        await supabase.realtime.setAuth()
      } catch (e) {
        console.warn("[realtime] setAuth fallo:", e)
      }
      if (cancelado) return

      const c = supabase.channel(canalTopico, { config: { private: true } })
      for (const ev of listaEventos.split(",")) {
        c.on("broadcast", { event: ev }, (msg) => {
          console.log(`[realtime] ${canalTopico} <- ${ev}`, msg)
          agrupar()
        })
      }
      // El canal se registra ANTES de suscribir, y cada aviso comprueba que
      // sigue siendo el canal vigente.
      //
      // Sin esto: `reconectar` cierra el canal viejo, y su CLOSED puede llegar
      // DESPUES de haber abierto el nuevo. Ese CLOSED tardio programaria otra
      // reconexion que tiraria el canal recien levantado, y asi otra vez. No
      // es un bucle infinito -- `intentos` se reinicia al suscribir -- pero es
      // una pantalla que se desconecta sola cada pocos segundos, que para el
      // que la mira es lo mismo.
      canal = c
      c.subscribe((estado, err) => {
        if (canal !== c) return
        // SE REGISTRA TODO ESTADO, NO SOLO LOS FALLOS.
        //
        // La primera version solo avisaba en CHANNEL_ERROR y TIMED_OUT, y eso
        // dejaba una consola limpia significando dos cosas opuestas: "se
        // suscribio bien" o "este hook nunca corrio". Sin poder distinguirlas,
        // el log no servia para diagnosticar nada.
        if (estado === "SUBSCRIBED") {
          intentos = 0
          console.log(`[realtime] ${canalTopico}: SUBSCRIBED`)
          return
        }
        if (estado === "CHANNEL_ERROR" || estado === "TIMED_OUT" || estado === "CLOSED") {
          if (err) console.warn(`[realtime] ${canalTopico}: ${estado}`, err)
          programarReintento(estado)
          return
        }
        console.log(`[realtime] ${canalTopico}: ${estado}`)
      })
    }

    // Volver al frente, o recuperar la conexion, es siempre motivo de recarga.
    // No se comprueba si el canal sigue vivo antes de recargar: comprobarlo
    // costaria mirar un estado interno de la libreria, y equivocarse ahi
    // significa dejar al admin mirando una foto. Preguntar de mas es barato.
    function alVolver() {
      if (cancelado) return
      if (typeof document !== "undefined" && document.visibilityState !== "visible") return
      agrupar()
      void reconectar()
    }

    if (typeof document !== "undefined") {
      document.addEventListener("visibilitychange", alVolver)
    }
    if (typeof window !== "undefined") {
      window.addEventListener("online", alVolver)
    }

    void arrancar()

    return () => {
      cancelado = true
      if (temporizador) clearTimeout(temporizador)
      if (reintento) clearTimeout(reintento)
      if (typeof document !== "undefined") {
        document.removeEventListener("visibilitychange", alVolver)
      }
      if (typeof window !== "undefined") {
        window.removeEventListener("online", alVolver)
      }
      if (canal) void supabase.removeChannel(canal)
    }
  }, [topico, listaEventos, esperaMs])
}
