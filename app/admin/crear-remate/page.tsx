// ADMIN/CREAR-REMATE/PAGE.TSX

"use client"

import { useEffect, useMemo, useRef, useState } from "react"
import type { Dispatch, SetStateAction } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"
import SelectorFechaHora, { nombreDiaDeIso } from "@/app/components/SelectorFechaHora"
// La escalera vive en lib/escalera.ts desde el 01/10: la pantalla de
// MODIFICAR un remate necesita exactamente lo mismo, y copiarla habria sido
// crear la segunda implementacion de una regla que ya existe (ADR-015).
import {
  type PriceRuleDraft,
  type RitmoEscalera,
  ETIQUETA_RITMO,
  RITMOS,
  generarEscalera,
  simularPujas,
  pujasHasta,
  problemasEscalera,
} from "@/lib/escalera"

type HorseDraft = {
  tempId: string
  numero: string
  nombre: string
  jinete: string
  comentarios: string
  precio_salida: string
}





function parseDateParts(ddRaw: string, mmRaw: string, yyRaw: string) {
  const dd = ddRaw.trim().padStart(2, "0")
  const mm = mmRaw.trim().padStart(2, "0")
  const yy = yyRaw.trim().padStart(2, "0")
  const d = Number(dd)
  const m = Number(mm)
  const y = Number(yy)
  if (!Number.isFinite(d) || !Number.isFinite(m) || !Number.isFinite(y)) return ""
  if (d < 1 || d > 31) return ""
  if (m < 1 || m > 12) return ""
  const yyyy = `20${yy}`
  return `${yyyy}-${mm}-${dd}`
}


function parseTime12hTo24(raw: string) {
  const s = String(raw || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ")
  const m = s.match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/)
  if (!m) return ""
  let h = Number(m[1])
  const mins = m[2] ?? "00"
  const ap = m[3]
  if (!Number.isFinite(h) || h < 1 || h > 12) return ""
  const mm = Number(mins)
  if (!Number.isFinite(mm) || mm < 0 || mm > 59) return ""
  if (ap === "pm" && h !== 12) h += 12
  if (ap === "am" && h === 12) h = 0
  const hh = String(h).padStart(2, "0")
  const min = String(mm).padStart(2, "0")
  return `${hh}:${min}:00`
}

function buildCaracasTs(dateIso: string, time24: string) {
  if (!dateIso) return null
  let t = (time24 || "").trim()
  if (!t) t = "00:00:00"
  if (t.length === 5) t = `${t}:00`
  return `${dateIso}T${t}-04:00`
}


function uid() {
  return Math.random().toString(16).slice(2) + Date.now().toString(16)
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

// Miles con punto y sin decimales: los precios de un remate son enteros.
function formatoBs(v: number) {
  if (!Number.isFinite(v)) return "0"
  return Math.round(v).toLocaleString("es-VE")
}



export default function AdminCrearRematePage() {
  const router = useRouter()

  // =========================
  // Estado general de la pantalla
  // =========================
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)

  // LA CLAVE DE IDEMPOTENCIA (10/10/2026, pendiente 1.2).
  //
  // Identifica el INTENTO, no la pulsacion. Se genera en el primer envio y se
  // repite en todos los reintentos del mismo intento, asi que dos clics
  // mandan la misma clave y la base devuelve el mismo remate en vez de crear
  // dos. Ver 20261010150000_idempotencia_crear_remate.sql y P72.
  //
  // Va en una referencia y no en estado a proposito: cambiarla no tiene que
  // repintar nada, y en estado provocaria un render por cada envio.
  const claveCreacion = useRef<string>("")
  const [error, setError] = useState("")
  const [ok, setOk] = useState("")

  // =========================
  // Datos creados (para linkear rápido al final)
  // =========================
  const [createdRaceId, setCreatedRaceId] = useState<string | null>(null)
  const [createdRemateId, setCreatedRemateId] = useState<string | null>(null)

  // =========================
  // Form Carrera (races)
  // =========================
  const [raceDescripcion, setRaceDescripcion] = useState("Carrera de Prueba")
  const [racePais, setRacePais] = useState("Venezuela")
  const [raceHipodromo, setRaceHipodromo] = useState("La Rinconada")
  const [raceNumeroCarreraText, setRaceNumeroCarreraText] = useState("1")
  // =========================================================================
  //  FECHAS Y HORAS: VACIAS AL ENTRAR (01/10/2026)
  //
  //  Venian prellenadas con el momento de abrir el formulario. Como crear un
  //  remate toma unos minutos, la hora de apertura YA HABIA PASADO cuando el
  //  admin le daba a Crear, y el boton se quedaba gris sin decir por que.
  //  Jota lo encontro asi y tardo en dar con la causa.
  //
  //  Peticion suya: vacias, y con selects para no teclear. El componente es
  //  app/components/SelectorFechaHora.tsx y habla el mismo idioma que este
  //  estado (dd / mm / aa + hora en 12h), asi que el guardado y la validacion
  //  no cambian.
  //
  //  Y se fueron los dos efectos espejo que copiaban la fecha y la hora de la
  //  carrera al cierre del remate: con el cierre ya opcional, un espejo que lo
  //  rellena solo hace imposible dejarlo vacio.
  // =========================================================================
  const [raceFechaDD, setRaceFechaDD] = useState("")
  const [raceFechaMM, setRaceFechaMM] = useState("")
  const [raceFechaAA, setRaceFechaAA] = useState("")
  const [raceHora, setRaceHora] = useState("")
  // El nombre del dia se RELLENA desde la fecha elegida en vez de salir del
  // reloj. Antes traia el dia de hoy aunque la carrera fuera el sabado, asi que
  // el admin tenia dos datos para un mismo hecho y uno de los dos estaba mal.
  // Sigue siendo editable: hay hipodromos que escriben "Domingo - Clasico".
  const [raceDia, setRaceDia] = useState("")
  const [raceDistancia, setRaceDistancia] = useState("")

  // =========================
  // Form Remate (remates)
  // =========================
  const [incrementoMinimo, setIncrementoMinimo] = useState("50")
  // Solo vive en el formulario: precarga el precio de salida de cada caballo.
  // NO se guarda en la base. Esa columna quedo sin uso en la tarea 2.17.
  const [salidaPorDefecto, setSalidaPorDefecto] = useState("100")
  const [porcentajeCasa, setPorcentajeCasa] = useState("25")
  const [remateTipo, setRemateTipo] = useState<"vivo" | "adelantado">("vivo")
  const [opensDD, setOpensDD] = useState("")
  const [opensMM, setOpensMM] = useState("")
  const [opensAA, setOpensAA] = useState("")
  const [opensTime, setOpensTime] = useState("")
  const [closesDD, setClosesDD] = useState("")
  const [closesMM, setClosesMM] = useState("")
  const [closesAA, setClosesAA] = useState("")
  const [closesTime, setClosesTime] = useState("")

  const raceFechaISO = useMemo(() => parseDateParts(raceFechaDD, raceFechaMM, raceFechaAA), [raceFechaDD, raceFechaMM, raceFechaAA])
  const raceHora24 = useMemo(() => parseTime12hTo24(raceHora), [raceHora])
  const opensDateISO = useMemo(() => parseDateParts(opensDD, opensMM, opensAA), [opensDD, opensMM, opensAA])
  const closesDateISO = useMemo(() => parseDateParts(closesDD, closesMM, closesAA), [closesDD, closesMM, closesAA])
  const opensTime24 = useMemo(() => parseTime12hTo24(opensTime), [opensTime])
  const closesTime24 = useMemo(() => parseTime12hTo24(closesTime), [closesTime])

  // =========================
  // Caballos (horses) - lista dinámica
  // NOTA: precio_salida es obligatorio (precio inicial del caballo).
  // =========================
  // Sin caballos semilla. Antes nacian dos, "Relampago" y "Tormenta", con un
  // precio de 60 escrito a mano que no tenia nada que ver con el precio de
  // salida del remate. De ahi venia que la pantalla dijera 40 y los caballos
  // 60: no era un bug de logica, era que no habia logica — eran dos numeros
  // sueltos sin ninguna relacion.
  const [horses, setHorses] = useState<HorseDraft[]>([])

  // =========================================================================
  //  LA ESCALERA GENERAL SE FUE (01/10/2026)
  //
  //  Existia una escalera "del remate" que al guardar se expandia a una copia
  //  por caballo. Consecuencia medida: NINGUN caballo quedaba regido por
  //  `remates.incremento_minimo`, asi que el admin cambiaba el incremento, la
  //  pantalla se lo confirmaba, y la base seguia cobrando el tramo de la
  //  escalera. Tres sintomas de una sola causa: el incremento no surtia efecto,
  //  la casilla de "reglas propias" aparecia marcada en TODOS los caballos, y
  //  la pantalla decia "siguen la escalera general" cuando ya era mentira.
  //
  //  Decision de Jota: la escalera general no hace falta. "El incremento se
  //  puede hacer a mano y hasta mejor, porque si el admin quiere poner de 75 en
  //  75 lo puede hacer." La regla general es ahora un numero:
  //
  //      precio_salida + incremento_minimo, siempre
  //
  //  La escalera por tramos sobrevive SOLO como regla propia de un caballo, que
  //  es donde se pidio desde el principio: el favorito que tiene que subir
  //  distinto.
  // =========================================================================
  const [horseRulesEnabled, setHorseRulesEnabled] = useState<Record<string, boolean>>({})
  const [horseRulesByTempId, setHorseRulesByTempId] = useState<Record<string, PriceRuleDraft[]>>({})
  // Ritmo de la escalera propia de cada caballo. Mismo mecanismo que la
  // general, pero generado desde el precio de salida DE ESE caballo.
  const [horseRitmo, setHorseRitmo] = useState<Record<string, RitmoEscalera>>({})
  const [horseTablaAbierta, setHorseTablaAbierta] = useState<Record<string, boolean>>({})
  const [horseEscaleraTocada, setHorseEscaleraTocada] = useState<Record<string, boolean>>({})

  // Los minimos los pone la INSTALACION, no este archivo (migracion
  // 20261001100000). La base los defiende con triggers; esta pantalla solo los
  // lee para avisar ANTES de guardar, en vez de dejar que el admin reciba el
  // error crudo de Postgres despues de darle a Crear.
  const [minIncremento, setMinIncremento] = useState<number | null>(null)
  const [minSalida, setMinSalida] = useState<number | null>(null)

  // =========================================================================
  //  EL PRECIO DE SALIDA MANDA
  //
  //  Decision del 25/09: el precio de salida del remate es EL precio de todos
  //  los caballos. La unica forma de que un caballo tenga otro precio es
  //  activarle su regla individual. Asi no existe un tercer estado invisible
  //  ("caballo que toque a mano y ya no sigue al remate") que no se vea en
  //  pantalla.
  //
  //  Antes no habia ningun efecto que conectara las dos cosas: cambiabas el
  //  precio del remate y los caballos ya creados se quedaban donde estaban.
  // =========================================================================
  useEffect(() => {
    const valor = salidaPorDefecto.trim()
    if (!valor) return
    setHorses((prev) => {
      if (prev.length === 0) return prev
      // El caballo con reglas propias activadas queda exento: activarlas es
      // justamente la forma de declarar "este va por su cuenta". Si lo
      // resincronizaramos igual, la casilla no significaria nada.
      const alcanzados = prev.filter((h) => !horseRulesEnabled[h.tempId])
      if (alcanzados.length === 0) return prev
      if (alcanzados.every((h) => h.precio_salida === valor)) return prev
      return prev.map((h) => (horseRulesEnabled[h.tempId] ? h : { ...h, precio_salida: valor }))
    })
  }, [salidaPorDefecto, horseRulesEnabled])

  // Lo mismo para cada caballo con reglas propias: si cambias SU precio, su
  // escalera se recalcula, salvo que la hayas tocado a mano. Sin esto, un
  // caballo con reglas propias quedaba con una escalera calculada sobre un
  // precio que ya no es el suyo.
  useEffect(() => {
    setHorseRulesByTempId((prev) => {
      let cambio = false
      const next = { ...prev }
      for (const h of horses) {
        if (!horseRulesEnabled[h.tempId]) continue
        if (horseEscaleraTocada[h.tempId]) continue
        const base = n(h.precio_salida)
        if (!(base > 0)) continue
        const generada = generarEscalera(base, horseRitmo[h.tempId] ?? "normal")
        const actual = prev[h.tempId] || []
        const igual =
          actual.length === generada.length &&
          actual.every(
            (r, i) =>
              r.min_precio === generada[i].min_precio &&
              r.max_precio === generada[i].max_precio &&
              r.incremento === generada[i].incremento
          )
        if (!igual) {
          next[h.tempId] = generada
          cambio = true
        }
      }
      return cambio ? next : prev
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [horses, horseRulesEnabled, horseRitmo, horseEscaleraTocada])

  // La simulacion, que es lo que de verdad hace entendible una regla de precio.
  // Ahora simula lo que la base va a hacer de verdad con un caballo sin reglas
  // propias: sumar el incremento, siempre el mismo. Se le pasa una lista de
  // tramos VACIA a proposito -- ya no hay escalera general que consultar.
  const simulacion = useMemo(
    () => simularPujas(n(salidaPorDefecto), [], n(incrementoMinimo), 9),
    [salidaPorDefecto, incrementoMinimo]
  )
  const pujasPara1000 = useMemo(
    () => pujasHasta(n(salidaPorDefecto), [], n(incrementoMinimo), 1000),
    [salidaPorDefecto, incrementoMinimo]
  )
  const pujasPara5000 = useMemo(
    () => pujasHasta(n(salidaPorDefecto), [], n(incrementoMinimo), 5000),
    [salidaPorDefecto, incrementoMinimo]
  )

  // =========================
  // Guard: asegurar que es admin
  // =========================
  async function ensureAdmin() {
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/admin/login")
      return null
    }

    const { data: prof, error: profErr } = await supabase
      .from("profiles")
      .select("id,es_admin,es_super_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (profErr) throw new Error(profErr.message)

    if (!prof?.es_admin && !prof?.es_super_admin) {
      router.replace("/dashboard")
      return null
    }

    return auth.user.id
  }

  useEffect(() => {
    ;(async () => {
      setLoading(true)
      setError("")
      try {
        const aid = await ensureAdmin()
        if (!aid) return

        // Los minimos de la instalacion. Si la lectura falla no se bloquea el
        // formulario: la base los defiende igual con sus triggers, y lo unico
        // que se pierde es el aviso temprano. Un aviso roto no puede impedir
        // crear un remate.
        const { data: aj, error: ajErr } = await supabase
          .from("ajustes_instalacion")
          .select("clave,valor")
          .in("clave", ["minimo_incremento", "minimo_precio_salida"])

        if (ajErr) {
          console.warn("[ajustes] no se pudieron leer los minimos:", ajErr.message)
        } else {
          for (const row of (aj ?? []) as { clave: string; valor: string }[]) {
            const v = Number(row.valor)
            if (!Number.isFinite(v)) continue
            if (row.clave === "minimo_incremento") setMinIncremento(v)
            if (row.clave === "minimo_precio_salida") setMinSalida(v)
          }
        }
      } catch (e: any) {
        setError(e?.message || "Error de sesion admin")
      } finally {
        setLoading(false)
      }
    })()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // =========================
  // Helpers UI
  // =========================
  // =========================================================================
  //  POR QUE ESTO DEVUELVE UNA LISTA Y NO UN BOOLEANO
  //
  //  Antes era `canSave: boolean`. El boton se quedaba gris y el admin tenia
  //  que adivinar cual de los treinta campos faltaba. Palabras de Jota: "no
  //  dice qué y entonces ahora toca adivinar, eso es una deficiencia de UX
  //  terrible". Tenia razon: un formulario que no sabe decir que le falta esta
  //  guardando la respuesta y no dandola.
  //
  //  Ahora cada condicion lleva su frase. `canSave` sigue existiendo, pero es
  //  una consecuencia: la lista vacia.
  // =========================================================================
  const faltantes = useMemo(() => {
    const f: string[] = []

    if (!raceDescripcion.trim()) f.push("Descripción de la carrera")
    if (!raceHipodromo.trim()) f.push("Hipódromo")
    if (!raceNumeroCarreraText.trim()) f.push("Número de carrera")
    if (!raceDia.trim()) f.push("Día")
    if (!raceFechaISO) f.push("Fecha de la carrera")
    if (!raceHora24) f.push("Hora de la carrera")
    if (!raceDistancia.trim() || !(n(raceDistancia) > 0)) f.push("Distancia en metros")

    const inc = n(incrementoMinimo)
    if (!(inc > 0)) {
      f.push("Incremento")
    } else if (minIncremento !== null && inc < minIncremento) {
      f.push(`El incremento no puede ser menor a ${formatoBs(minIncremento)} Bs`)
    }

    const casa = n(porcentajeCasa)
    if (!(casa >= 0 && casa <= 100)) f.push("% de la casa (entre 0 y 100)")

    // LAS DOS FECHAS SON OPCIONALES.
    // Cierre: "un admin puede llenarlo o no porque el mismo cierra el remate
    // manualmente cuando quiera". Apertura: "que lo programen si quieren y si
    // lo dejan vacio el remate queda activo apenas se cree".
    // La base ya admitia los dos nulos: `hacer_puja` solo compara contra
    // opens_at `if v_remate.opens_at is not null`, y el cierre automatico solo
    // mira los remates con closes_at. Esto es cambio de FRONTEND unicamente.
    const o = buildCaracasTs(opensDateISO, opensTime24)
    const c = buildCaracasTs(closesDateISO, closesTime24)

    // Media fecha es peor que ninguna: buildCaracasTs rellena la hora vacia con
    // 00:00, asi que una fecha sin hora programaba el remate a medianoche sin
    // que nadie lo hubiera pedido, y en silencio. Se exige el par completo o
    // nada, en los dos campos.
    if (opensDateISO && !opensTime24) f.push("Hora de apertura (ya elegiste la fecha)")
    if (!opensDateISO && opensTime24) f.push("Fecha de apertura (ya elegiste la hora)")
    if (closesDateISO && !closesTime24) f.push("Hora de cierre (ya elegiste la fecha)")
    if (!closesDateISO && closesTime24) f.push("Fecha de cierre (ya elegiste la hora)")

    if (c && o && new Date(c).getTime() <= new Date(o).getTime()) {
      f.push("El cierre tiene que ser después de la apertura")
    }

    if (horses.length === 0) f.push("Al menos un caballo")

    // NUMEROS REPETIDOS. `horses` tiene UNIQUE (race_id, numero), asi que esto
    // lo rechaza la base de todas formas -- pero lo rechaza A MITAD del
    // guardado, cuando la carrera y el remate ya se escribieron. El resultado
    // era un remate ABIERTO, visible al publico, con cero caballos. Crear un
    // remate son cuatro escrituras sin transaccion (pendiente 1.1), y mientras
    // no haya un RPC transaccional, la unica defensa es no llegar nunca al
    // insert que rebota.
    //
    // Se comparan los numeros YA NORMALIZADOS: "03" y "3" son el mismo caballo
    // para la base, porque la columna es `integer`.
    const vistos = new Map<number, number>()
    for (const h of horses) {
      const txt = h.numero.trim()
      if (!txt) continue
      const num = Number(txt)
      if (!Number.isInteger(num)) continue
      vistos.set(num, (vistos.get(num) ?? 0) + 1)
    }
    for (const [num, cuantos] of vistos) {
      if (cuantos > 1) f.push(`El número ${num} está repetido en ${cuantos} caballos`)
    }
    for (const h of horses) {
      const quien = h.numero.trim() ? `Caballo ${h.numero.trim()}` : "Un caballo"
      if (!h.numero.trim()) f.push("Número de un caballo")
      if (!h.nombre.trim()) f.push(`${quien}: nombre`)
      if (!h.jinete.trim()) f.push(`${quien}: jinete`)
      if (!h.precio_salida.trim() || !(n(h.precio_salida) > 0)) {
        f.push(`${quien}: precio de salida`)
      } else if (minSalida !== null && n(h.precio_salida) < minSalida) {
        f.push(`${quien}: el precio de salida no puede ser menor a ${formatoBs(minSalida)} Bs`)
      }
    }

    // La validacion de una escalera la hace lib/escalera.ts, igual que en la
    // pantalla de editar. Estaba escrita dos veces y ya sabemos como acaba eso.
    for (const h of horses) {
      if (!horseRulesEnabled[h.tempId]) continue
      const quien = h.numero.trim() ? `Caballo ${h.numero.trim()}` : "Un caballo"
      f.push(...problemasEscalera(horseRulesByTempId[h.tempId] || [], minIncremento, quien))
    }

    // Sin duplicados: el mismo aviso repetido diez veces no informa mas.
    return Array.from(new Set(f))
  }, [
    raceDescripcion,
    raceHipodromo,
    raceNumeroCarreraText,
    raceDia,
    raceFechaDD,
    raceFechaMM,
    raceFechaAA,
    raceHora,
    raceDistancia,
    raceFechaISO,
    raceHora24,
    incrementoMinimo,
    salidaPorDefecto,
    porcentajeCasa,
    opensDD,
    opensMM,
    opensAA,
    opensTime,
    closesDD,
    closesMM,
    closesAA,
    closesTime,
    opensDateISO,
    opensTime24,
    closesDateISO,
    closesTime24,
    horses,
    horseRulesEnabled,
    horseRulesByTempId,
    minIncremento,
    minSalida,
  ])

  const canSave = faltantes.length === 0

  // CONFIRMACION ANTES DE CREAR.
  //
  // Pedido por Jota el 01/10: los tres numeros de dinero a la vista antes de
  // escribir nada. La razon es que crear un remate NO es reversible de forma
  // limpia: una vez abierto, la gente puja, y cambiar el incremento o el
  // porcentaje despues deja avisos al jugador (migracion 20260928110000) o
  // directamente no se puede si ya hay pujas. El momento de leer los numeros
  // es ANTES, no cuando ya hay dinero encima.
  //
  // Y hay un segundo motivo, que es el que de verdad muerde: el formulario
  // arranca con valores por defecto -- "Carrera de Prueba", "La Rinconada",
  // incremento 50, casa 25%. Crear un remate real sin haber mirado esos
  // campos es facilisimo, y es un error que no se nota hasta que un jugador
  // pregunta por que la carrera se llama "Carrera de Prueba".
  const [confirmando, setConfirmando] = useState(false)

  // El pozo minimo: lo que entraria si nadie pujara por ningun caballo, que es
  // el suelo garantizado del remate. No es una prediccion, es una cota.
  const resumen = useMemo(() => {
    const pozoMinimo = horses.reduce((acc, h) => acc + n(h.precio_salida), 0)
    const casa = n(porcentajeCasa)
    return {
      pozoMinimo,
      casa,
      comisionMinima: Math.round(pozoMinimo * (casa / 100) * 100) / 100,
      premioMinimo: Math.round(pozoMinimo * ((100 - casa) / 100) * 100) / 100,
      conEscalera: horses.filter((h) => horseRulesEnabled[h.tempId]).length,
    }
  }, [horses, porcentajeCasa, horseRulesEnabled])

  function addHorse() {
    const nextNum =
      horses.length > 0
        ? String(Math.max(...horses.map((h) => Number(h.numero) || 0)) + 1)
        : "1"
    setHorses((prev) => [
      ...prev,
      { tempId: uid(), numero: nextNum, nombre: "", jinete: "", comentarios: "", precio_salida: salidaPorDefecto || "" },
    ])
  }

  function removeHorse(tempId: string) {
    setHorses((prev) => prev.filter((h) => h.tempId !== tempId))
    setHorseRulesEnabled((prev) => {
      const next = { ...prev }
      delete next[tempId]
      return next
    })
    setHorseRulesByTempId((prev) => {
      const next = { ...prev }
      delete next[tempId]
      return next
    })
  }

  function updateHorse(tempId: string, patch: Partial<HorseDraft>) {
    setHorses((prev) => prev.map((h) => (h.tempId === tempId ? { ...h, ...patch } : h)))
  }

  function addRule(setter: Dispatch<SetStateAction<PriceRuleDraft[]>>) {
    setter((prev) => [...prev, { tempId: uid(), min_precio: "", max_precio: "", incremento: "" }])
  }

  function updateRule(
    setter: Dispatch<SetStateAction<PriceRuleDraft[]>>,
    tempId: string,
    patch: Partial<PriceRuleDraft>
  ) {
    setter((prev) => prev.map((r) => (r.tempId === tempId ? { ...r, ...patch } : r)))
  }

  function removeRule(setter: Dispatch<SetStateAction<PriceRuleDraft[]>>, tempId: string) {
    setter((prev) => prev.filter((r) => r.tempId !== tempId))
  }

  function addHorseRule(horseTempId: string) {
    setHorseRulesByTempId((prev) => {
      const list = prev[horseTempId] || []
      return { ...prev, [horseTempId]: [...list, { tempId: uid(), min_precio: "", max_precio: "", incremento: "" }] }
    })
  }

  function updateHorseRule(horseTempId: string, ruleTempId: string, patch: Partial<PriceRuleDraft>) {
    setHorseRulesByTempId((prev) => {
      const list = prev[horseTempId] || []
      return {
        ...prev,
        [horseTempId]: list.map((r) => (r.tempId === ruleTempId ? { ...r, ...patch } : r)),
      }
    })
  }

  function removeHorseRule(horseTempId: string, ruleTempId: string) {
    setHorseRulesByTempId((prev) => {
      const list = prev[horseTempId] || []
      return { ...prev, [horseTempId]: list.filter((r) => r.tempId !== ruleTempId) }
    })
  }

  // =========================
  // GUARDAR TODO, EN UNA SOLA TRANSACCION
  //
  // Desde el 07/10 esto es UNA llamada a crear_remate_completo(). Antes eran
  // cinco sueltas y un fallo a mitad dejaba basura: ver el comentario de
  // dentro y 20261007130000_crear_remate_completo.sql.
  // =========================
  async function onCreate() {
    // EL DOBLE CLIC, CERRADO EN LA BASE DESDE EL 10/10.
    //
    // Jota lo encontro asi: "al crearse un remate, el boton de crear remate
    // queda activo y si le doy 20 veces mas, crea 20 remates con el mismo
    // nombre y los mismos datos".
    //
    // La transaccion del 07/10 NO arreglaba esto, y conviene tenerlo claro:
    // dos clics son dos llamadas COMPLETAS Y CORRECTAS, no hay nada a medias
    // que deshacer. La base creaba dos remates porque no tenia forma de saber
    // que era el mismo.
    //
    // Ahora el payload lleva `p_clave` y la base tiene un indice unico detras:
    // el segundo envio devuelve el remate del primero en vez de crear otro, y
    // sin error -- un admin que hizo doble clic no tiene por que ver uno.
    //
    // Estas dos guardas SE QUEDAN, y no son redundantes: ahorran la ida y
    // vuelta al servidor. Lo que ya no son es la unica defensa, que es lo que
    // las hacia fragiles -- recargar y reenviar las saltaba.
    if (saving) return
    if (createdRemateId) {
      setError("Este remate ya se creó. Recarga la página si quieres crear otro.")
      return
    }

    setError("")
    setOk("")
    setCreatedRaceId(null)

    if (!canSave) {
      setError(
        faltantes.length > 0
          ? "Falta: " + faltantes.join(" · ")
          : "Revisa los campos: hay datos faltantes o inválidos."
      )
      return
    }

    setSaving(true)

    try {
      // 0) Verificar admin antes de escribir
      const aid = await ensureAdmin()
      if (!aid) return

      // La clave se genera UNA vez por intento. Si este envio falla por lo que
      // sea -- la red, una validacion de la base -- el siguiente reintento
      // manda la misma, y si resulta que el primero si llego a escribir, la
      // base devuelve ese remate en vez de crear un gemelo.
      //
      // `crypto.randomUUID` solo existe en contexto seguro (https o
      // localhost). El panel siempre lo es, pero un respaldo de tres lineas
      // quita una clase entera de fallo, y una clave "peor" sigue cumpliendo
      // su trabajo: solo tiene que no repetirse.
      if (!claveCreacion.current) {
        claveCreacion.current =
          typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
            ? crypto.randomUUID()
            : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`
      }

      // UNA SOLA LLAMADA. (07/10/2026, pendiente 1.1)
      //
      // Aqui habia CINCO llamadas, y cada una era su propia transaccion ya
      // confirmada: insert en races, insert en remates, insert en horses,
      // select en horses para recuperar los ids, insert en remate_price_rules.
      // Si fallaba la tercera, las dos primeras estaban en disco y este
      // `catch` hacia exactamente una cosa: setError(). Ni un delete.
      //
      // Medido en el arnes, con el admin repitiendo el numero 5: quedaba una
      // carrera huerfana, un remate ABIERTO con cero caballos, y la senal del
      // ADR-031 ya emitida -- el remate roto empujado a la pantalla de todos
      // los jugadores conectados.
      //
      // Ahora es una funcion PL/pgSQL, o sea una transaccion. Si algo revienta
      // -- un numero repetido, un incremento por debajo del minimo de la
      // instalacion, cualquier cosa -- no queda nada escrito y no sale
      // ninguna senal. Ver 20261007130000_crear_remate_completo.sql y P67.
      //
      // El paso del `select` para recuperar los ids de los caballos ya no
      // existe: las escaleras viajan COLGANDO de su caballo dentro del
      // payload, y la base usa `insert ... returning`.
      const numeroCarreraText = raceNumeroCarreraText.trim()
      const numeroCarreraNum =
        numeroCarreraText && Number.isFinite(Number(numeroCarreraText)) ? Number(numeroCarreraText) : null

      const remateNombreInterno =
        raceDescripcion.trim() ||
        (raceHipodromo.trim()
          ? `Remate ${raceHipodromo.trim()}`
          : `Remate ${numeroCarreraText || ""}`.trim())

      // LA ESCALERA GENERAL NO EXISTE EN LA BASE (30/09/2026).
      //
      // Sigue existiendo en ESTE formulario, porque es un atajo comodo para
      // configurar doce caballos de un golpe, pero al guardar no se escribe
      // como una regla con `horse_id` nulo: un caballo sin escalera propia no
      // recibe ninguna fila, y por eso la base le aplica
      // `remates.incremento_minimo`. Esa es toda la regla general.
      //
      // `remate_price_rules.horse_id` es NOT NULL desde la migracion
      // 20260930100000, asi que una regla sin caballo es imposible de escribir.
      const caballosPayload = horses.map((h) => {
        const reglas = horseRulesEnabled[h.tempId]
          ? (horseRulesByTempId[h.tempId] || [])
              .filter((r) => r.min_precio.trim() && r.incremento.trim())
              .map((r) => ({
                min_precio: n(r.min_precio),
                max_precio: r.max_precio.trim() ? n(r.max_precio) : null,
                incremento: n(r.incremento),
              }))
          : []

        return {
          numero: Number(h.numero),
          nombre: h.nombre.trim(),
          jinete: h.jinete.trim() ? h.jinete.trim() : null,
          entrenador: null,
          comentarios: h.comentarios.trim() ? h.comentarios.trim() : null,
          precio_salida: n(h.precio_salida),
          reglas,
        }
      })

      const { data: creado, error: rpcErr } = await supabase.rpc("crear_remate_completo", {
        p_carrera: {
          nombre: raceDescripcion.trim(),
          hipodromo: raceHipodromo.trim() ? raceHipodromo.trim() : null,
          numero_carrera: numeroCarreraNum,
          numero_carrera_text: numeroCarreraText || null,
          fecha: raceFechaISO,
          hora_programada: raceHora24 ? raceHora24 : null,
          dia: raceDia.trim() ? raceDia.trim() : null,
          distancia_m: n(raceDistancia),
        },
        p_remate: {
          nombre: remateNombreInterno,
          incremento_minimo: n(incrementoMinimo),
          porcentaje_casa: n(porcentajeCasa),
          tipo: remateTipo,
          opens_at: buildCaracasTs(opensDateISO, opensTime24),
          closes_at: buildCaracasTs(closesDateISO, closesTime24),
        },
        p_caballos: caballosPayload,
        p_clave: claveCreacion.current,
      })

      if (rpcErr) throw new Error(rpcErr.message)

      // `returns table` llega como un arreglo de una fila.
      const fila = Array.isArray(creado) ? creado[0] : creado
      if (!fila?.id_remate) throw new Error("La base no devolvio el remate creado.")

      setCreatedRaceId(String(fila.id_carrera))
      setCreatedRemateId(String(fila.id_remate))

      setOk("Listo. Carrera, remate y caballos creados.")
    } catch (e: any) {
      setError(e?.message || "Error creando remate")
    } finally {
      setSaving(false)
    }
  }

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando...</div>
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 sm:px-6 lg:px-8 py-6">
      {/* En movil se ve igual que antes; en PC deja de ser una columna
          de 448px con una rejilla de 3 columnas apretada adentro. */}
      <div className="mx-auto w-full max-w-5xl">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Admin - Crear remate</h1>
        </div>

        {/* Mensajes */}
        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}
        {ok ? (
          <div className="mt-4 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
            {ok}
            {createdRemateId ? (
              <div className="mt-2">
                <Link href={`/remates/${createdRemateId}`} className="underline underline-offset-4 text-emerald-200">
                  Ir al remate
                </Link>
              </div>
            ) : null}
          </div>
        ) : null}

        {/* Carrera */}
        <section className="mt-5 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">1) Carrera</h2>

          <div className="mt-3 space-y-3">
            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">País</label>
                <select
                  value={racePais}
                  onChange={(e) => {
                    const next = e.target.value
                    setRacePais(next)
                    if (next !== "Venezuela") {
                      setRaceHipodromo("")
                    } else if (!raceHipodromo.trim()) {
                      setRaceHipodromo("La Rinconada")
                    }
                  }}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  <option value="Venezuela">Venezuela</option>
                  <option value="Estados Unidos" disabled>
                    Estados Unidos (próximamente)
                  </option>
                </select>
              </div>
              <div>
                <label className="text-sm text-zinc-200">Hipódromo</label>
                <select
                  value={raceHipodromo}
                  onChange={(e) => setRaceHipodromo(e.target.value)}
                  disabled={racePais !== "Venezuela"}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  <option value="La Rinconada">La Rinconada</option>
                  <option value="Valencia">Valencia</option>
                </select>
              </div>
            </div>

            <div>
              <label className="text-sm text-zinc-200">Descripción de la carrera</label>
              <input
                value={raceDescripcion}
                onChange={(e) => setRaceDescripcion(e.target.value)}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                placeholder="Ej: Cl?sico Especial de la Tarde"
              />
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Día</label>
                <input
                  value={raceDia}
                  onChange={(e) => setRaceDia(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="Domingo"
                />
              </div>
              <div>
                <label className="text-sm text-zinc-200">Distancia (m)</label>
                <input
                  inputMode="numeric"
                  value={raceDistancia}
                  onChange={(e) => setRaceDistancia(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="1600"
                />
              </div>
            </div>

            <SelectorFechaHora
              etiqueta="Cuándo corre la carrera"
              valor={{ dd: raceFechaDD, mm: raceFechaMM, aa: raceFechaAA, hora12: raceHora }}
              onChange={(v) => {
                setRaceFechaDD(v.dd)
                setRaceFechaMM(v.mm)
                setRaceFechaAA(v.aa)
                setRaceHora(v.hora12)
                // El dia sigue a la fecha. Si el admin lo habia personalizado,
                // elegir otra fecha lo vuelve a poner: la fecha manda.
                const iso = v.dd && v.mm && v.aa ? `20${v.aa}-${v.mm}-${v.dd}` : ""
                setRaceDia(nombreDiaDeIso(iso))
              }}
            />

            <div>
              <label className="text-sm text-zinc-200">N° carrera (texto)</label>
              <input
                value={raceNumeroCarreraText}
                onChange={(e) => setRaceNumeroCarreraText(e.target.value)}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                placeholder="6 - PRIMERA VÁLIDA"
              />
            </div>
          </div>
        </section>
        {/* Remate */}
        <section className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">2) Remate</h2>

          <div className="mt-3 space-y-3">
            <div className="grid grid-cols-3 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Precio de salida</label>
                <input
                  inputMode="decimal"
                  value={salidaPorDefecto}
                  onChange={(e) => setSalidaPorDefecto(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="100"
                />
                <div className="mt-1 text-[11px] text-zinc-500">Salen todos los caballos</div>
              </div>
              <div>
                {/* Este es EL incremento del remate, sin matices. Hasta el
                    01/10 decia "Incremento fijo" y debajo "Solo si apagas la
                    escalera", porque habia una escalera general que lo dejaba
                    sin efecto. Ya no existe: lo que se escriba aqui es lo que
                    la base va a cobrar en todo caballo sin reglas propias. */}
                <label className="text-sm text-zinc-200">Incremento</label>
                <input
                  inputMode="decimal"
                  value={incrementoMinimo}
                  onChange={(e) => setIncrementoMinimo(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="50"
                />
                <div className="mt-1 text-[11px] text-zinc-500">
                  Sube así siempre{minIncremento !== null ? `, mínimo ${formatoBs(minIncremento)} Bs` : ""}
                </div>
              </div>
              <div>
                <label className="text-sm text-zinc-200">% casa</label>
                <input
                  inputMode="decimal"
                  value={porcentajeCasa}
                  onChange={(e) => setPorcentajeCasa(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="25"
                />
              </div>
            </div>

            <div className="text-xs text-zinc-500">
              Este "crear rapido" deja el remate <span className="text-zinc-300">abierto</span> para que entres a probar de una.
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Tipo</label>
                <select
                  value={remateTipo}
                  onChange={(e) => setRemateTipo(e.target.value as "vivo" | "adelantado")}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  <option value="vivo">En vivo</option>
                  <option value="adelantado">Adelantado</option>
                </select>
              </div>
            </div>

            <SelectorFechaHora
              etiqueta="Apertura del remate"
              opcional
              valor={{ dd: opensDD, mm: opensMM, aa: opensAA, hora12: opensTime }}
              onChange={(v) => {
                setOpensDD(v.dd)
                setOpensMM(v.mm)
                setOpensAA(v.aa)
                setOpensTime(v.hora12)
              }}
              ayuda="Déjalo vacío y el remate queda activo apenas se cree."
            />

            <SelectorFechaHora
              etiqueta="Cierre del remate"
              opcional
              valor={{ dd: closesDD, mm: closesMM, aa: closesAA, hora12: closesTime }}
              onChange={(v) => {
                setClosesDD(v.dd)
                setClosesMM(v.mm)
                setClosesAA(v.aa)
                setClosesTime(v.hora12)
              }}
              ayuda="Déjalo vacío si vas a cerrar el remate a mano."
            />
          </div>
        </section>
        {/* Como sube el precio.

            Antes esto era una escalera por tramos con tres ritmos y una tabla
            editable, y al guardar se copiaba a cada caballo. El efecto era que
            `remates.incremento_minimo` no gobernaba a nadie: el admin cambiaba
            el incremento y la base seguia cobrando el tramo. Ahora esta seccion
            no decide nada por su cuenta -- muestra lo que va a pasar con el
            numero que se puso arriba. Una sola fuente. */}
        <section className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">3) Cómo sube el precio</h2>

          <div className="mt-3 rounded-xl bg-zinc-950/40 border border-zinc-800 p-3">
            <div className="text-sm text-zinc-200">
              Sube de {formatoBs(n(incrementoMinimo))} Bs en {formatoBs(n(incrementoMinimo))} Bs
            </div>
            <div className="mt-1 text-xs text-zinc-400">
              Vale para todos los caballos del remate. Si alguno tiene que subir distinto, actívale las
              reglas propias en el paso 4 — ahí sí puedes ponerle tramos.
            </div>
            {minIncremento !== null && n(incrementoMinimo) > 0 && n(incrementoMinimo) < minIncremento ? (
              <div className="mt-2 rounded-lg bg-red-500/10 border border-red-500/30 px-3 py-2 text-xs text-red-200">
                El mínimo de esta instalación es {formatoBs(minIncremento)} Bs. Con{" "}
                {formatoBs(n(incrementoMinimo))} Bs la base lo va a rechazar.
              </div>
            ) : null}
          </div>

          {/* LA SIMULACION. Cuatro columnas de numeros no te dicen nunca como se
              siente pujar; una lista de precios si. */}
          <div className="mt-3 rounded-xl bg-zinc-950/40 border border-zinc-800 p-3">
            <div className="text-xs text-zinc-500">Así se vería una subasta</div>
            {simulacion.length > 1 ? (
              <>
                <div className="mt-2 flex flex-wrap items-center gap-x-1 gap-y-1 text-sm">
                  {simulacion.map((v, i) => (
                    <span key={i} className="flex items-center gap-1">
                      {i > 0 ? <span className="text-zinc-600">→</span> : null}
                      <span className={i === 0 ? "font-semibold text-zinc-100" : "text-zinc-300"}>
                        {formatoBs(v)}
                      </span>
                    </span>
                  ))}
                  <span className="text-zinc-600">→ …</span>
                </div>
                <div className="mt-2 text-[11px] text-zinc-400">
                  {pujasPara1000 !== null ? <>Llegar a 1.000 Bs: <b>{pujasPara1000} pujas</b>. </> : null}
                  {pujasPara5000 !== null ? <>Llegar a 5.000 Bs: <b>{pujasPara5000} pujas</b>.</> : null}
                </div>
              </>
            ) : (
              <div className="mt-2 text-sm text-zinc-500">
                Pon un precio de salida y un incremento para ver la simulación.
              </div>
            )}
          </div>
        </section>
        {/* Caballos */}
        <section className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="flex items-center justify-between">
            <h2 className="text-base font-semibold">4) Caballos</h2>
            <button
              onClick={addHorse}
              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs font-semibold"
            >
              + Agregar caballo
            </button>
          </div>

          {horses.length === 0 ? (
            <div className="mt-3 rounded-xl bg-zinc-950/40 border border-zinc-800 p-3 text-sm text-zinc-400">
              Todavía no hay caballos. Agrégalos con el botón de arriba; cada uno sale en{" "}
              <b className="text-zinc-200">{formatoBs(n(salidaPorDefecto))} Bs</b>, el precio de salida del remate.
              <br />
              ¿Quieres otro precio para todos? Cámbialo arriba, en <b className="text-zinc-300">2) Remate → Precio de
              salida</b>, y los caballos se ajustan solos. Para que uno solo salga distinto, actívale sus reglas
              propias más abajo.
            </div>
          ) : null}

          <div className="mt-3 space-y-3">
            {horses.map((h) => (
              <div key={h.tempId} className="rounded-2xl bg-zinc-950/40 border border-zinc-800 p-3">
                <div className="flex items-center justify-between">
                  <div className="text-sm font-semibold">Caballo</div>
                  <button
                    onClick={() => removeHorse(h.tempId)}
                    className="text-xs text-red-200 bg-red-500/10 ring-1 ring-red-500/20 rounded-lg px-2 py-1"
                  >
                    Quitar
                  </button>
                </div>

                <div className="mt-3 grid grid-cols-3 gap-2">
                  <div>
                    <label className="text-xs text-zinc-300">No.</label>
                    <input
                      inputMode="numeric"
                      value={h.numero}
                      onChange={(e) => updateHorse(h.tempId, { numero: e.target.value })}
                      className="mt-1 w-full rounded-xl bg-zinc-900/40 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder="1"
                    />
                  </div>
                  <div className="col-span-2">
                    <label className="text-xs text-zinc-300">Nombre</label>
                    <input
                      value={h.nombre}
                      onChange={(e) => updateHorse(h.tempId, { nombre: e.target.value })}
                      className="mt-1 w-full rounded-xl bg-zinc-900/40 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder="Relámpago"
                    />
                  </div>
                </div>

                <div className="mt-2 grid grid-cols-2 gap-2">
                  <div>
                    <label className="text-xs text-zinc-300">Jinete</label>
                    <input
                      value={h.jinete}
                      onChange={(e) => updateHorse(h.tempId, { jinete: e.target.value })}
                      className="mt-1 w-full rounded-xl bg-zinc-900/40 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder="J1"
                    />
                  </div>
                </div>

                <div className="mt-2 grid grid-cols-2 gap-2">
                  <div>
                    <label className="text-xs text-zinc-300">Precio salida</label>
                    <input
                      inputMode="decimal"
                      value={h.precio_salida}
                      onChange={(e) => updateHorse(h.tempId, { precio_salida: e.target.value })}
                      className="mt-1 w-full rounded-xl bg-zinc-900/40 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder={salidaPorDefecto || "100"}
                    />
                  </div>
                  <div>
                    <label className="text-xs text-zinc-300">Comentario (opcional)</label>
                    <input
                      value={h.comentarios}
                      onChange={(e) => updateHorse(h.tempId, { comentarios: e.target.value })}
                      className="mt-1 w-full rounded-xl bg-zinc-900/40 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder="Caballo veloz"
                    />
                  </div>
                </div>

                <div className="mt-3 rounded-xl bg-zinc-950/40 border border-zinc-800 p-3">
                  <div className="flex items-center justify-between">
                    <div className="text-xs text-zinc-300">Reglas propias</div>
                    <label className="text-xs text-zinc-300 flex items-center gap-2">
                      <input
                        type="checkbox"
                        checked={!!horseRulesEnabled[h.tempId]}
                        onChange={(e) => {
                          const activado = e.target.checked
                          setHorseRulesEnabled((prev) => ({ ...prev, [h.tempId]: activado }))
                          if (activado) {
                            // Nace con una escalera valida, no con la tabla en
                            // blanco: activar la casilla no puede dejarte con un
                            // formulario que no deja guardar.
                            const r = horseRitmo[h.tempId] ?? "normal"
                            setHorseRitmo((prev) => ({ ...prev, [h.tempId]: r }))
                            setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: false }))
                            setHorseRulesByTempId((prev) => ({
                              ...prev,
                              [h.tempId]: generarEscalera(n(h.precio_salida) || n(salidaPorDefecto) || 100, r),
                            }))
                          }
                        }}
                      />
                      Activar
                    </label>
                  </div>

                  {horseRulesEnabled[h.tempId] ? (
                    <div className="mt-3 space-y-2">
                      {/* Mismos tres ritmos que la escalera general, pero
                          generados desde el precio de salida DE ESTE caballo.
                          Un favorito no sube igual que el resto: ese es el caso
                          que esta casilla existe para cubrir. */}
                      <div className="space-y-2">
                        {RITMOS.map((op) => {
                          const activo = (horseRitmo[h.tempId] ?? "normal") === op && !horseEscaleraTocada[h.tempId]
                          return (
                            <label
                              key={op}
                              className={`flex items-start gap-2 rounded-xl border px-3 py-2 text-xs cursor-pointer ${
                                activo ? "bg-zinc-950/70 border-zinc-600" : "bg-zinc-950/40 border-zinc-800"
                              }`}
                            >
                              <input
                                type="radio"
                                name={`ritmo-${h.tempId}`}
                                className="mt-0.5"
                                checked={activo}
                                onChange={() => {
                                  setHorseRitmo((prev) => ({ ...prev, [h.tempId]: op }))
                                  setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: false }))
                                  setHorseRulesByTempId((prev) => ({
                                    ...prev,
                                    [h.tempId]: generarEscalera(
                                      n(h.precio_salida) || n(salidaPorDefecto) || 100,
                                      op
                                    ),
                                  }))
                                }}
                              />
                              <span className="text-zinc-200">{ETIQUETA_RITMO[op]}</span>
                            </label>
                          )
                        })}
                      </div>

                      {horseEscaleraTocada[h.tempId] ? (
                        <div className="flex items-center justify-between gap-2 rounded-xl bg-amber-500/10 border border-amber-500/30 px-3 py-2">
                          <span className="text-[11px] text-amber-100">Escalera personalizada</span>
                          <button
                            type="button"
                            onClick={() => {
                              const r = horseRitmo[h.tempId] ?? "normal"
                              setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: false }))
                              setHorseRulesByTempId((prev) => ({
                                ...prev,
                                [h.tempId]: generarEscalera(n(h.precio_salida) || n(salidaPorDefecto) || 100, r),
                              }))
                            }}
                            className="text-[11px] text-amber-100 underline underline-offset-4"
                          >
                            Volver a la automática
                          </button>
                        </div>
                      ) : null}

                      <div className="rounded-xl bg-zinc-950/40 border border-zinc-800 p-3">
                        <div className="text-[11px] text-zinc-500">Así subiría este caballo</div>
                        {n(h.precio_salida) > 0 ? (
                          <div className="mt-1 flex flex-wrap items-center gap-1 text-xs">
                            {simularPujas(
                              n(h.precio_salida),
                              horseRulesByTempId[h.tempId] || [],
                              n(incrementoMinimo),
                              7
                            ).map((v, i) => (
                              <span key={i} className="flex items-center gap-1">
                                {i > 0 ? <span className="text-zinc-600">→</span> : null}
                                <span className={i === 0 ? "font-semibold text-zinc-100" : "text-zinc-300"}>
                                  {formatoBs(v)}
                                </span>
                              </span>
                            ))}
                            <span className="text-zinc-600">→ …</span>
                          </div>
                        ) : (
                          <div className="mt-1 text-xs text-zinc-500">
                            Ponle precio de salida a este caballo para ver la simulación.
                          </div>
                        )}
                      </div>

                      <button
                        type="button"
                        onClick={() =>
                          setHorseTablaAbierta((prev) => ({ ...prev, [h.tempId]: !prev[h.tempId] }))
                        }
                        className="text-[11px] text-zinc-300 underline underline-offset-4"
                      >
                        {horseTablaAbierta[h.tempId] ? "Ocultar los tramos" : "Ver y editar los tramos"}
                      </button>

                      {horseTablaAbierta[h.tempId] ? (
                        <div className="space-y-2">
                          {(horseRulesByTempId[h.tempId] || []).map((r, i) => (
                            <div key={r.tempId} className="rounded-xl bg-zinc-950/40 border border-zinc-800 p-2">
                              <div className="flex items-center justify-between">
                                <span className="text-[11px] text-zinc-500">Tramo {i + 1}</span>
                                <button
                                  type="button"
                                  onClick={() => {
                                    setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: true }))
                                    removeHorseRule(h.tempId, r.tempId)
                                  }}
                                  className="text-[11px] text-zinc-400 underline underline-offset-4"
                                >
                                  Quitar
                                </button>
                              </div>
                              <div className="mt-2 grid grid-cols-3 gap-2">
                                <label className="block">
                                  <span className="block text-[10px] text-zinc-500">Desde</span>
                                  <input
                                    inputMode="decimal"
                                    value={r.min_precio}
                                    onChange={(e) => {
                                      setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: true }))
                                      updateHorseRule(h.tempId, r.tempId, { min_precio: e.target.value })
                                    }}
                                    className="mt-1 w-full rounded-lg bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-xs"
                                  />
                                </label>
                                <label className="block">
                                  <span className="block text-[10px] text-zinc-500">Hasta</span>
                                  <input
                                    inputMode="decimal"
                                    value={r.max_precio}
                                    onChange={(e) => {
                                      setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: true }))
                                      updateHorseRule(h.tempId, r.tempId, { max_precio: e.target.value })
                                    }}
                                    placeholder="sin tope"
                                    className="mt-1 w-full rounded-lg bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-xs"
                                  />
                                </label>
                                <label className="block">
                                  <span className="block text-[10px] text-zinc-500">Sube de</span>
                                  <input
                                    inputMode="decimal"
                                    value={r.incremento}
                                    onChange={(e) => {
                                      setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: true }))
                                      updateHorseRule(h.tempId, r.tempId, { incremento: e.target.value })
                                    }}
                                    className="mt-1 w-full rounded-lg bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-xs"
                                  />
                                </label>
                              </div>
                            </div>
                          ))}
                          <button
                            type="button"
                            onClick={() => {
                              setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: true }))
                              addHorseRule(h.tempId)
                            }}
                            className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                          >
                            + Agregar tramo
                          </button>
                        </div>
                      ) : null}
                    </div>
                  ) : (
                    <div className="mt-2 text-xs text-zinc-500">
                      Sube de {formatoBs(n(incrementoMinimo))} Bs en {formatoBs(n(incrementoMinimo))} Bs,
                      como el resto del remate.
                    </div>
                  )}
                </div>
              </div>
            ))}
            <button
              onClick={addHorse}
              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs font-semibold"
            >
              + Agregar caballo
            </button>
          </div>

          <div className="mt-3 text-xs text-zinc-500">
            Todos los caballos suben con el incremento del remate. Actívale las reglas propias solo al que
            tenga que subir distinto — el favorito, normalmente.
          </div>
        </section>

        {/* Guardar.

            El boton desactivado ya no es un misterio: debajo sale la lista de lo
            que falta. Y una vez creado NO se puede volver a pulsar, que es como
            se creaban veinte remates iguales. */}
        {faltantes.length > 0 && !createdRemateId ? (
          <div className="mt-4 rounded-xl bg-amber-500/10 border border-amber-500/30 p-3">
            <div className="text-xs font-semibold text-amber-100">
              Falta {faltantes.length === 1 ? "esto" : `esto (${faltantes.length})`} para poder crear:
            </div>
            <ul className="mt-2 space-y-1">
              {faltantes.map((m) => (
                <li key={m} className="text-xs text-amber-100/90">
                  · {m}
                </li>
              ))}
            </ul>
          </div>
        ) : null}

        <button
          onClick={() => setConfirmando(true)}
          disabled={!canSave || saving || !!createdRemateId}
          className="mt-4 w-full rounded-xl bg-white text-zinc-950 font-semibold py-3 disabled:opacity-60"
        >
          {createdRemateId ? "Remate creado" : saving ? "Creando..." : "Revisar y crear"}
        </button>

        {/* ---------------------------------------------------------------
            EL REPASO ANTES DE CREAR

            No es un "¿estás seguro?". Un cuadro que solo pregunta eso se
            responde que sí sin leerlo, y entonces no sirve para nada: lo
            unico que aporta es un clic mas.

            Este ENSEÑA lo que no se puede deshacer -- el nombre que va a ver
            el jugador, el incremento, el porcentaje de la casa y el pozo
            minimo -- porque el error tipico no es crear sin querer, es crear
            con los valores por defecto sin haberlos mirado.
            --------------------------------------------------------------- */}
        {confirmando ? (
          <div className="fixed inset-0 z-[90] flex items-end justify-center bg-black/70 p-4 sm:items-center">
            <div className="w-full max-w-md rounded-2xl border border-zinc-700 bg-zinc-900 p-5 shadow-2xl max-h-[90vh] overflow-y-auto">
              <div className="text-lg font-bold text-zinc-50">Revisa antes de crear</div>
              <p className="mt-1 text-xs text-zinc-400">
                Una vez abierto, la gente puja. El incremento y el porcentaje de la casa ya no se
                pueden cambiar sin avisar a los jugadores, y con pujas hechas no se pueden cambiar.
              </p>

              <div className="mt-4 rounded-xl border border-zinc-800 bg-zinc-950/60 p-3">
                <div className="text-xs text-zinc-500">Lo que verá el jugador</div>
                <div className="mt-1 text-sm font-semibold text-zinc-100">
                  {raceDescripcion.trim() || "(sin descripción)"}
                </div>
                <div className="text-xs text-zinc-400">
                  {raceHipodromo.trim()} · carrera {raceNumeroCarreraText.trim()} ·{" "}
                  {raceDia.trim()} {raceFechaDD}/{raceFechaMM}/{raceFechaAA} {raceHora}
                </div>
              </div>

              <div className="mt-2 grid grid-cols-3 gap-2">
                <div className="rounded-xl border border-zinc-800 bg-zinc-950/60 p-3">
                  <div className="text-[11px] text-zinc-500">Incremento</div>
                  <div className="mt-1 text-base font-semibold text-zinc-100">
                    {formatoBs(n(incrementoMinimo))}
                  </div>
                </div>
                <div className="rounded-xl border border-zinc-800 bg-zinc-950/60 p-3">
                  <div className="text-[11px] text-zinc-500">Casa</div>
                  <div className="mt-1 text-base font-semibold text-zinc-100">{resumen.casa}%</div>
                </div>
                <div className="rounded-xl border border-zinc-800 bg-zinc-950/60 p-3">
                  <div className="text-[11px] text-zinc-500">Caballos</div>
                  <div className="mt-1 text-base font-semibold text-zinc-100">{horses.length}</div>
                </div>
              </div>

              <div className="mt-2 rounded-xl border border-zinc-800 bg-zinc-950/60 p-3">
                <div className="text-xs text-zinc-500">
                  Si nadie pujara por ningún caballo (el suelo del remate)
                </div>
                <div className="mt-2 flex items-baseline justify-between">
                  <span className="text-sm text-zinc-300">Pozo</span>
                  <span className="text-sm font-semibold tabular-nums text-zinc-100">
                    {formatoBs(resumen.pozoMinimo)} Bs
                  </span>
                </div>
                <div className="mt-1 flex items-baseline justify-between">
                  <span className="text-sm text-zinc-300">Se queda la casa</span>
                  <span className="text-sm font-semibold tabular-nums text-emerald-300">
                    {formatoBs(resumen.comisionMinima)} Bs
                  </span>
                </div>
                <div className="mt-1 flex items-baseline justify-between">
                  <span className="text-sm text-zinc-300">Premio</span>
                  <span className="text-sm font-semibold tabular-nums text-zinc-100">
                    {formatoBs(resumen.premioMinimo)} Bs
                  </span>
                </div>
                <div className="mt-2 text-[11px] text-zinc-500">
                  Con pujas, las tres cifras suben. Esto es el mínimo, no una previsión.
                </div>
              </div>

              <div className="mt-2 text-[11px] text-zinc-500">
                {resumen.conEscalera > 0
                  ? `${resumen.conEscalera} de ${horses.length} caballos llevan escalera propia.`
                  : "Ningún caballo lleva escalera propia: todos suben con el incremento fijo."}
                {" "}
                Apertura:{" "}
                {opensDateISO && opensTime24
                  ? `${opensDD}/${opensMM}/${opensAA} ${opensTime}`
                  : "activo al crearse"}
                . Cierre:{" "}
                {closesDateISO && closesTime24
                  ? `${closesDD}/${closesMM}/${closesAA} ${closesTime}`
                  : "a mano"}
                .
              </div>

              <div className="mt-4 flex gap-2">
                <button
                  onClick={() => {
                    setConfirmando(false)
                    void onCreate()
                  }}
                  disabled={saving}
                  className="flex-1 rounded-xl bg-white px-3 py-2 text-sm font-semibold text-zinc-950 disabled:opacity-60"
                >
                  Crear remate
                </button>
                <button
                  onClick={() => setConfirmando(false)}
                  className="rounded-xl border border-zinc-700 bg-zinc-950/60 px-3 py-2 text-sm text-zinc-200"
                >
                  Volver a revisar
                </button>
              </div>
            </div>
          </div>
        ) : null}

        {createdRaceId || createdRemateId ? (
          <div className="mt-4 text-xs text-zinc-500">
            {createdRaceId ? <div>Race ID: {createdRaceId}</div> : null}
            {createdRemateId ? <div>Remate ID: {createdRemateId}</div> : null}
          </div>
        ) : null}
      </div>
    </main>
  )
}
