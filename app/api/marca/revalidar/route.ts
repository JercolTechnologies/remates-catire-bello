// ===========================================================================
//  /api/marca/revalidar  -  TIRAR LA CACHE CUANDO DEJA DE SER VALIDA
//
//  EL DEFECTO QUE ARREGLA (11/10/2026, ADR-050)
//
//  `lib/marcaCasa.ts` lee el nombre y el logo de la casa con
//  `next: { revalidate: 300 }`. Eso mantiene las paginas ESTATICAS -- medido
//  en el build: las 30 rutas siguen `○ (Static)` -- y evita una consulta por
//  visita. El precio es stale-while-revalidate: pasados los cinco minutos, la
//  primera peticion sirve la copia VIEJA y regenera por detras; la nueva se ve
//  en la siguiente. Con el CDN por medio, ni eso.
//
//  Consecuencia medida el 11/10 en la primera licencia: el dueno puso el
//  nombre de su casa, guardo, y la portada siguio diciendo el nombre de la
//  plataforma. El codigo funcionaba -- `/panel`, que es dinamica, ya decia
//  "Remate VJSS" -- pero las paginas que miraba el, no.
//
//  Y eso no es un caso raro: cambiar el nombre de la casa es LO PRIMERO que
//  hace un licenciatario despues de fundar. Le habria pasado a todos.
//
//  LA SOLUCION NO ES QUITAR LA CACHE. Sin ella el sitio pasa a dinamico y
//  paga una consulta por visita en todas las casas, para siempre, por un dato
//  que cambia una vez en la vida. La solucion es invalidarla en el momento
//  exacto en que deja de ser cierta: al guardar.
//
//  POR QUE COMPRUEBA QUIEN LLAMA. Sin comprobacion, cualquiera podria pedir
//  revalidaciones en bucle y obligar a regenerar paginas sin parar. No es un
//  agujero de datos, es uno de gasto. Se sigue el mismo patron que
//  `/api/notify/recarga`: sesion por cookie y perfil desde la base.
// ===========================================================================

import { NextResponse } from "next/server"
import { createServerClient } from "@supabase/ssr"
import { cookies } from "next/headers"
import { revalidateTag, revalidatePath } from "next/cache"
import { ETIQUETA_MARCA_CASA } from "@/lib/marcaCasa"

export const runtime = "nodejs"

export async function POST() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
  const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  if (!supabaseUrl || !supabaseAnonKey) {
    return NextResponse.json({ error: "Sin configuracion de Supabase" }, { status: 500 })
  }

  const cookieStore = await cookies()
  const supabase = createServerClient(supabaseUrl, supabaseAnonKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll()
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value, options }) => {
          cookieStore.set(name, value, options)
        })
      },
    },
  })

  const { data: auth, error: authErr } = await supabase.auth.getUser()
  if (authErr || !auth?.user) {
    return NextResponse.json({ error: "Sin sesion" }, { status: 401 })
  }

  const { data: perfil, error: perfilErr } = await supabase
    .from("profiles")
    .select("es_super_admin")
    .eq("id", auth.user.id)
    .maybeSingle()

  if (perfilErr) {
    return NextResponse.json({ error: perfilErr.message }, { status: 500 })
  }
  if (perfil?.es_super_admin !== true) {
    return NextResponse.json({ error: "No autorizado" }, { status: 403 })
  }

  // LAS DOS LLAMADAS HACEN COSAS DISTINTAS, Y HACEN FALTA LAS DOS.
  //
  //  - `revalidateTag` tira el dato CACHEADO del `fetch` a Supabase. Sin esto,
  //    la pagina se vuelve a pintar... con el valor viejo, que sigue fresco en
  //    la cache de datos durante sus 300 segundos.
  //  - `revalidatePath('/', 'layout')` tira el HTML ya generado de todas las
  //    paginas que cuelgan del layout raiz -- que son todas, porque la marca
  //    vive ahi.
  //
  //  `{ expire: 0 }` y no `'max'`: la documentacion de Next 16 dice que con el
  //  perfil recomendado se sigue sirviendo contenido viejo mientras regenera
  //  por detras, y que `{ expire: 0 }` hace que la siguiente peticion espere a
  //  la revalidacion. Aqui eso es lo que se quiere: el dueno acaba de guardar
  //  su nombre y tiene que verlo, no "dentro de un rato". Esperar unos
  //  milisegundos en la siguiente visita es exactamente el precio correcto.
  //
  //  `updateTag`, que seria lo natural, NO sirve: la documentacion dice que
  //  solo esta disponible dentro de un Server Action, y esto es un Route
  //  Handler.
  revalidateTag(ETIQUETA_MARCA_CASA, { expire: 0 })
  revalidatePath("/", "layout")

  return NextResponse.json({ ok: true })
}
