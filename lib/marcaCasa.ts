// ===========================================================================
//  lib/marcaCasa.ts  -  LA MARCA DE LA CASA, LEIDA EN EL SERVIDOR
//
//  POR QUE EXISTE (11/10/2026, ADR-049)
//
//  `CASA` era una constante en `lib/marca.ts` puesta a `null`. Para que un
//  licenciatario viera su nombre habia que editar el repositorio y desplegar
//  -- lo que rompe "un repo, N clientes" por el mismo sitio por donde lo
//  rompian los datos bancarios.
//
//  POR QUE EN EL SERVIDOR Y NO EN EL NAVEGADOR
//
//  El titulo de la pestana sale de `generateMetadata()`, que corre en el
//  servidor. Si la casa se leyera en el cliente, el titulo seria siempre el de
//  la plataforma y el nombre de la casa aparecería un parpadeo despues en la
//  cabecera. Leyendolo aqui, UNA vez, el servidor pinta ya el nombre correcto
//  y los componentes de cliente lo reciben por contexto sin pedir nada.
//
//  POR QUE `fetch` Y NO EL CLIENTE DE SUPABASE
//
//  Porque asi el resultado entra en la cache de Next: `revalidate` hace que la
//  pagina siga siendo estatica y que la consulta ocurra una vez cada cinco
//  minutos, no en cada visita. El cliente de supabase-js no deja pasar las
//  opciones de cache de Next sin acrobacias, y aqui no hace falta: la RPC es
//  publica (`ajustes_publicos()` la ejecuta `anon`, ADR-029/047) y una
//  peticion HTTP plana la resuelve.
//
//  SI FALLA, NO PASA NADA. Devuelve `null`, que significa "esta instalacion es
//  la de la plataforma" -- exactamente el comportamiento que habia antes. Una
//  marca que no carga no puede tumbar la pagina.
// ===========================================================================

export type MarcaCasa = { nombre: string; logo?: string } | null

/** Cinco minutos. Un licenciatario cambia su nombre una vez en la vida; que
 *  tarde un rato en verse es barato comparado con consultar en cada visita. */
const SEGUNDOS_CACHE = 300

export async function casaDeLaInstalacion(): Promise<MarcaCasa> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  if (!url || !key) return null

  try {
    const r = await fetch(`${url}/rest/v1/rpc/ajustes_publicos`, {
      method: "POST",
      headers: {
        apikey: key,
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
      },
      body: "{}",
      next: { revalidate: SEGUNDOS_CACHE },
    })
    if (!r.ok) return null

    const filas = (await r.json()) as { clave: string; valor: string }[]
    const mapa = new Map(filas.map((f) => [f.clave, (f.valor ?? "").trim()]))

    const nombre = mapa.get("casa_nombre") ?? ""
    if (!nombre) return null

    const logo = mapa.get("casa_logo_url") ?? ""
    return logo ? { nombre, logo } : { nombre }
  } catch {
    // Una instalacion a medio aplicar todavia no tiene la clave, y una red
    // caida no es motivo para no pintar la pagina.
    return null
  }
}
