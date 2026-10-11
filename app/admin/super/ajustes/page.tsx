"use client"

// ===========================================================================
//  /admin/super/ajustes  -  "LOS DATOS DE TU CASA"
//
//  POR QUE EXISTE (11/10/2026, ADR-047)
//
//  Hasta hoy, los datos de cobro de una instalacion estaban clavados en el
//  HTML de `/dashboard/recargar`. Cambiarlos exigia editar el repositorio y
//  volver a desplegar: Jercol decidiendo donde cobra la casa del cliente.
//
//  Esta pantalla es el requisito de verdad del modelo. En un SaaS el cliente
//  no abre un SQL Editor ni le pide a su proveedor que le toque la base: pone
//  sus datos y arranca. Sin esto, la migracion 20261011011500 solo habria
//  movido el problema de un archivo a otro.
//
//  NO HACE ARITMETICA NI VALIDA REGLAS. Manda `guardar_ajustes()`, que es
//  quien comprueba el super admin, filtra por su lista blanca y deja asiento
//  en la bitacora (ADR-015: lo de la base, en la base).
//
//  LA VISTA PREVIA NO ES ADORNO. El dueno escribe los datos aqui y los ve
//  como los vera su jugador. Un numero mal copiado no lo descubre quien lo
//  escribio:
//  lo descubre, dias despues, alguien que mando su dinero a otro sitio.
// ===========================================================================

import { useCallback, useEffect, useState } from "react"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"
import { prepararLogo } from "@/lib/logoCasa"

type Campo = {
  clave: string
  etiqueta: string
  ayuda?: string
  ancho?: "medio" | "entero"
  /** "logo" se pinta como subida de archivo, no como caja de texto. */
  tipo?: "texto" | "logo"
}

/** El bucket y el prefijo de los archivos de marca. Ver 20261011162000. */
const BUCKET = "marca"
const PREFIJO_PUBLICO = `/storage/v1/object/public/${BUCKET}/`

/** Si la URL apunta a NUESTRO bucket, devuelve el nombre del archivo. Sirve
 *  para borrar el logo viejo al subir uno nuevo y no dejar basura. */
function archivoDeNuestroBucket(url: string): string | null {
  const i = url.indexOf(PREFIJO_PUBLICO)
  if (i < 0) return null
  const nombre = url.slice(i + PREFIJO_PUBLICO.length).split("?")[0]
  return nombre || null
}

type Grupo = { titulo: string; nota?: string; campos: Campo[] }

// Una sola lista manda sobre el formulario, la carga y el guardado. Anadir una
// clave el dia de manana es una linea aqui y una en la migracion -- no cuatro
// sitios que se desincronizan.
const GRUPOS: Grupo[] = [
  {
    titulo: "Tu casa",
    nota: "El nombre se ensena junto al de la plataforma, nunca en su lugar.",
    campos: [
      { clave: "casa_nombre", etiqueta: "Nombre de la casa", ayuda: "Ej: Remate El Zuliano" },
      { clave: "casa_logo_url", etiqueta: "Logo", ayuda: "Opcional. Sin logo se ensena solo el nombre, y queda digno.", ancho: "entero", tipo: "logo" },
    ],
  },
  {
    titulo: "Como cobras",
    nota: "Esto es lo que ve tu jugador antes de depositar. Si falta algo, no puede recargar.",
    campos: [
      { clave: "pago_titular", etiqueta: "Titular", ayuda: "A nombre de quien estan la cuenta y el Pago Movil" },
      { clave: "pago_documento", etiqueta: "Cedula o RIF", ayuda: "Vale para los dos metodos" },
      { clave: "pago_movil_banco", etiqueta: "Pago Movil - banco" },
      { clave: "pago_movil_telefono", etiqueta: "Pago Movil - telefono" },
      { clave: "pago_transf_banco", etiqueta: "Transferencia - banco" },
      { clave: "pago_transf_tipo", etiqueta: "Transferencia - tipo de cuenta", ayuda: "Corriente, ahorro..." },
      { clave: "pago_transf_numero", etiqueta: "Transferencia - numero de cuenta", ancho: "entero" },
    ],
  },
]

const CLAVES = GRUPOS.flatMap((g) => g.campos.map((c) => c.clave))

// Lo minimo para que un jugador pueda depositar por algun metodo. El logo y
// hasta el nombre de la casa pueden faltar sin consecuencias; esto no.
const IMPRESCINDIBLES = ["pago_titular", "pago_documento"]

function faltaParaCobrar(v: Record<string, string>): string[] {
  const faltan = IMPRESCINDIBLES.filter((k) => !v[k]?.trim())
  const hayMovil = v.pago_movil_banco?.trim() && v.pago_movil_telefono?.trim()
  const hayTransf = v.pago_transf_banco?.trim() && v.pago_transf_numero?.trim()
  if (!hayMovil && !hayTransf) faltan.push("al menos un metodo de pago completo")
  return faltan
}

export default function AjustesCasaPage() {
  const router = useRouter()

  const [cargando, setCargando] = useState(true)
  const [esSuper, setEsSuper] = useState(false)
  const [error, setError] = useState("")
  const [ok, setOk] = useState("")
  const [guardando, setGuardando] = useState(false)

  const [valores, setValores] = useState<Record<string, string>>({})
  const [guardado, setGuardado] = useState<Record<string, string>>({})
  const [subiendo, setSubiendo] = useState(false)
  const [avisoLogo, setAvisoLogo] = useState("")

  // El navegador recorta el aire del lienzo antes de subir: la gente exporta
  // su logo centrado en un cuadrado, y en una cabecera de 32 px ese aire deja
  // el dibujo ilegible. Medido con el logo del primer licenciatario: lienzo
  // 1:1, dibujo 2.76:1 ocupando el 32% de la altura. Ver lib/logoCasa.ts.
  async function subirLogo(file: File) {
    setError("")
    setOk("")
    setAvisoLogo("")
    setSubiendo(true)
    try {
      const preparado = await prepararLogo(file)

      // Nombre con marca de tiempo: si se reescribiera siempre el mismo
      // archivo, la URL no cambiaria y el navegador y el CDN seguirian
      // sirviendo el logo viejo.
      const nombre = `casa-${Date.now()}.png`
      const { error: subErr } = await supabase.storage
        .from(BUCKET)
        .upload(nombre, preparado.blob, { contentType: "image/png" })
      if (subErr) throw new Error(subErr.message)

      const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(nombre)

      // Fuera el anterior, si era nuestro. Si falla, no se interrumpe nada:
      // lo que queda es un archivo huerfano, no un logo roto.
      const viejo = archivoDeNuestroBucket(valores.casa_logo_url ?? "")
      if (viejo) {
        const { error: delErr } = await supabase.storage.from(BUCKET).remove([viejo])
        if (delErr) console.warn("[logo] no se pudo borrar el anterior:", delErr.message)
      }

      setValores((v) => ({ ...v, casa_logo_url: pub.publicUrl }))
      setAvisoLogo(`${preparado.resumen} Pulsa Guardar para que lo vean tus jugadores.`)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "No se pudo subir el logo")
    } finally {
      setSubiendo(false)
    }
  }

  async function quitarLogo() {
    const viejo = archivoDeNuestroBucket(valores.casa_logo_url ?? "")
    if (viejo) {
      const { error: delErr } = await supabase.storage.from(BUCKET).remove([viejo])
      if (delErr) console.warn("[logo] no se pudo borrar:", delErr.message)
    }
    setValores((v) => ({ ...v, casa_logo_url: "" }))
    setAvisoLogo("Logo quitado. Pulsa Guardar para confirmarlo.")
  }

  const cargar = useCallback(async () => {
    setError("")
    try {
      const { data: auth } = await supabase.auth.getUser()
      if (!auth?.user) {
        router.replace("/admin/login")
        return
      }

      const { data: perfil, error: pErr } = await supabase
        .from("profiles")
        .select("es_super_admin")
        .eq("id", auth.user.id)
        .maybeSingle()
      if (pErr) throw new Error(pErr.message)

      const sup = perfil?.es_super_admin === true
      setEsSuper(sup)

      // La tabla la lee cualquier admin (politica `ajustes_lee_admin`). Un
      // admin no super ve sus datos pero no puede guardarlos, y vale la pena
      // que los vea: saber a que cuenta deposita la gente es parte de su
      // trabajo cuando aprueba una recarga.
      const { data, error: e } = await supabase
        .from("ajustes_instalacion")
        .select("clave,valor")
        .in("clave", CLAVES)
      if (e) throw new Error(e.message)

      const mapa: Record<string, string> = {}
      for (const k of CLAVES) mapa[k] = ""
      for (const fila of data ?? []) mapa[fila.clave as string] = (fila.valor as string) ?? ""

      setValores(mapa)
      setGuardado(mapa)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "No se pudieron cargar los ajustes de la casa")
    } finally {
      setCargando(false)
    }
  }, [router])

  useEffect(() => {
    void cargar()
  }, [cargar])

  const sucio = CLAVES.some((k) => (valores[k] ?? "") !== (guardado[k] ?? ""))

  async function guardar() {
    setError("")
    setOk("")
    setGuardando(true)
    try {
      // Se manda todo y la base decide que cambio. Mandar solo lo tocado seria
      // una segunda copia de esa logica aqui, y dos copias se separan.
      const { data, error: e } = await supabase.rpc("guardar_ajustes", {
        p_valores: Object.fromEntries(CLAVES.map((k) => [k, (valores[k] ?? "").trim()])),
      })
      if (e) throw new Error(e.message)

      const n = typeof data === "number" ? data : 0
      setGuardado({ ...valores })

      // La portada, la cabecera y el titulo de la pestana salen de una lectura
      // CACHEADA en el servidor (lib/marcaCasa.ts). Sin este aviso, el dueno
      // guarda su nombre y no ve cambiar nada durante minutos -- le paso al
      // primer licenciatario el 11/10. Si falla, no se rompe el guardado: lo
      // que se pierde es la inmediatez, y a los cinco minutos se arregla solo.
      if (n > 0) {
        try {
          await fetch("/api/marca/revalidar", { method: "POST" })
        } catch (e) {
          console.warn("[marca] no se pudo refrescar la cache:", e)
        }
      }
      setOk(n === 0 ? "No habia nada que cambiar." : n === 1 ? "Guardado: 1 cambio." : `Guardado: ${n} cambios.`)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "No se pudo guardar")
    } finally {
      setGuardando(false)
    }
  }

  if (cargando) {
    return (
      <main className="min-h-screen bg-zinc-950 text-zinc-50 flex items-center justify-center">
        Cargando...
      </main>
    )
  }

  const faltan = faltaParaCobrar(guardado)

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 sm:px-6 lg:px-8 py-6">
      <div className="mx-auto w-full max-w-3xl">
        <h1 className="text-xl font-bold">Los datos de tu casa</h1>
        <p className="mt-1 text-xs text-zinc-500">
          Cada cambio aqui queda firmado en el registro, con el valor anterior y el nuevo.
        </p>

        {faltan.length > 0 ? (
          <div className="mt-4 rounded-xl bg-amber-500/10 p-3 text-xs leading-snug text-amber-200 ring-1 ring-amber-500/20">
            <span className="font-semibold">Tus jugadores todavia no pueden recargar.</span> Falta{" "}
            {faltan.join(", ")}. Hasta que lo completes, la pantalla de recargar les dira que la
            casa aun no tiene datos de cobro.
          </div>
        ) : null}

        {!esSuper ? (
          <div className="mt-4 rounded-xl bg-zinc-900/60 p-3 text-xs leading-snug text-zinc-300 ring-1 ring-zinc-800">
            Puedes ver estos datos, pero solo el super administrador los cambia.
          </div>
        ) : null}

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}
        {ok ? (
          <div className="mt-4 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
            {ok}
          </div>
        ) : null}

        {GRUPOS.map((g) => (
          <section key={g.titulo} className="mt-6 rounded-2xl border border-zinc-800 bg-zinc-900/40 p-4">
            <h2 className="text-sm font-semibold text-zinc-100">{g.titulo}</h2>
            {g.nota ? <p className="mt-1 text-xs text-zinc-500">{g.nota}</p> : null}

            <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2">
              {g.campos.map((c) =>
                c.tipo === "logo" ? (
                  <div key={c.clave} className="block sm:col-span-2">
                    <span className="text-xs text-zinc-400">{c.etiqueta}</span>
                    <div className="mt-1 flex flex-wrap items-center gap-3">
                      {valores.casa_logo_url ? (
                        // Sobre chip claro, que es como se pinta en la cabecera:
                        // la vista previa tiene que mentir lo menos posible.
                        <span className="inline-flex items-center rounded-xl bg-zinc-100 px-3 py-2">
                          {/* eslint-disable-next-line @next/next/no-img-element */}
                          <img src={valores.casa_logo_url} alt="Logo de la casa" className="h-8 w-auto object-contain" />
                        </span>
                      ) : (
                        <span className="text-xs text-zinc-600">Todavía no has subido ninguno.</span>
                      )}

                      <label className="cursor-pointer rounded-xl border border-zinc-700 px-3 py-2 text-xs text-zinc-200 hover:bg-zinc-800">
                        {subiendo ? "Preparando..." : valores.casa_logo_url ? "Cambiar" : "Subir logo"}
                        <input
                          type="file"
                          accept="image/png,image/jpeg,image/webp"
                          className="hidden"
                          disabled={!esSuper || subiendo || guardando}
                          onChange={(e) => {
                            const f = e.target.files?.[0]
                            // Se limpia el input para que elegir el MISMO archivo
                            // otra vez vuelva a disparar el evento.
                            e.target.value = ""
                            if (f) void subirLogo(f)
                          }}
                        />
                      </label>

                      {valores.casa_logo_url ? (
                        <button
                          type="button"
                          onClick={() => void quitarLogo()}
                          disabled={!esSuper || subiendo || guardando}
                          className="rounded-xl px-2 py-2 text-xs text-zinc-500 underline underline-offset-4 hover:text-zinc-300 disabled:opacity-60"
                        >
                          Quitar
                        </button>
                      ) : null}
                    </div>
                    {avisoLogo ? (
                      <span className="mt-2 block text-[11px] text-emerald-300/80">{avisoLogo}</span>
                    ) : c.ayuda ? (
                      <span className="mt-1 block text-[11px] text-zinc-600">{c.ayuda}</span>
                    ) : null}
                    <span className="mt-1 block text-[11px] text-zinc-600">
                      PNG, JPG o WEBP, hasta 2 MB. Le quitamos el espacio sobrante solos.
                    </span>
                  </div>
                ) : (
                  <label key={c.clave} className={c.ancho === "entero" ? "block sm:col-span-2" : "block"}>
                    <span className="text-xs text-zinc-400">{c.etiqueta}</span>
                    <input
                      value={valores[c.clave] ?? ""}
                      onChange={(e) => setValores((v) => ({ ...v, [c.clave]: e.target.value }))}
                      disabled={!esSuper || guardando}
                      className="mt-1 w-full rounded-xl border border-zinc-800 bg-zinc-950/60 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10 disabled:opacity-60"
                    />
                    {c.ayuda ? <span className="mt-1 block text-[11px] text-zinc-600">{c.ayuda}</span> : null}
                  </label>
                )
              )}
            </div>
          </section>
        ))}

        {/* ------------------------------------------------- VISTA PREVIA */}
        <section className="mt-6 rounded-2xl border border-zinc-800 bg-zinc-900/40 p-4">
          <h2 className="text-sm font-semibold text-zinc-100">Lo que vera tu jugador</h2>
          <p className="mt-1 text-xs text-zinc-500">
            Compruebalo contra tu libreta antes de guardar. Un numero mal copiado lo descubre, dias
            despues, quien mando el dinero a otro sitio.
          </p>

          <div className="mt-3 space-y-3 rounded-2xl bg-zinc-950/60 p-4 text-sm text-zinc-200 ring-1 ring-white/10">
            <div>
              <div className="font-semibold">Pago Movil</div>
              <div className="text-zinc-400">Banco: {valores.pago_movil_banco || "—"}</div>
              <div className="text-zinc-400">Telefono: {valores.pago_movil_telefono || "—"}</div>
              <div className="text-zinc-400">Cedula: {valores.pago_documento || "—"}</div>
            </div>
            <div>
              <div className="font-semibold">Transferencia bancaria</div>
              <div className="text-zinc-400">Banco: {valores.pago_transf_banco || "—"}</div>
              <div className="text-zinc-400">Cuenta: {valores.pago_transf_tipo || "—"}</div>
              <div className="text-zinc-400">N° de cuenta: {valores.pago_transf_numero || "—"}</div>
              <div className="text-zinc-400">Cedula: {valores.pago_documento || "—"}</div>
            </div>
            <div className="text-zinc-400">A nombre de: {valores.pago_titular || "—"}</div>
          </div>
        </section>

        <div className="sticky bottom-0 mt-6 bg-gradient-to-t from-zinc-950 via-zinc-950 to-transparent pb-6 pt-4">
          <button
            type="button"
            onClick={() => void guardar()}
            disabled={!esSuper || guardando || !sucio}
            className="w-full rounded-xl bg-white py-2 font-semibold text-zinc-950 disabled:opacity-60"
          >
            {guardando ? "Guardando..." : sucio ? "Guardar cambios" : "Sin cambios que guardar"}
          </button>
        </div>
      </div>
    </main>
  )
}
