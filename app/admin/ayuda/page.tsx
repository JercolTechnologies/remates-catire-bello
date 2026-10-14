// ===========================================================================
//  /admin/ayuda  -  LA GUIA DEL LICENCIATARIO, DENTRO DEL PANEL
//
//  POR QUE EXISTE (14/10/2026, ADR-053)
//
//  La guia operativa se escribio como documento para mandarsela al
//  licenciatario. Un archivo que se manda por correo se pierde en el correo.
//  El dueno de una casa la necesita cuando esta operando -- delante de una
//  recarga que no sabe si aprobar -- y ahi lo util es tenerla a un clic.
//
//  LEE EL PROPIO .md, NO UNA COPIA.
//
//  Escribir el texto otra vez en JSX habria creado dos versiones de la misma
//  guia, y dos versiones se separan: la del repositorio se corrige y la de la
//  pantalla se queda mintiendo. Es el mismo principio que el ADR-015 aplicado
//  a documentacion -- una sola fuente, y aqui la fuente es el documento.
//
//  La lectura ocurre en el SERVIDOR y en tiempo de compilacion: esta pagina no
//  tiene nada dinamico, asi que Next la prerrenderiza y el archivo se lee una
//  vez al construir, no en cada visita. Comprobado en el build: sale como
//  estatica.
// ===========================================================================

import fs from "node:fs"
import path from "node:path"
import ReactMarkdown from "react-markdown"
import remarkGfm from "remark-gfm"

export const metadata = { title: "Ayuda" }

function leerGuia() {
  try {
    return fs.readFileSync(
      path.join(process.cwd(), "docs", "GUIA_LICENCIATARIO.md"),
      "utf8"
    )
  } catch {
    // Si el archivo no viaja al despliegue, la pantalla lo dice en vez de
    // reventar. Una ayuda rota no puede tumbar el panel.
    return "## La guía no está disponible\n\nNo se pudo leer el documento. Escríbenos y lo revisamos."
  }
}

export default function AyudaPage() {
  const guia = leerGuia()

  return (
    <main className="min-h-screen bg-zinc-950 px-4 py-6 text-zinc-50 sm:px-6 lg:px-8">
      <div className="mx-auto w-full max-w-3xl">
        {/* Los estilos van aqui y no en el documento: el .md tiene que seguir
            sirviendo tal cual para el PDF y para leerlo en el repositorio. */}
        <article
          className="
            [&_h1]:mt-0 [&_h1]:text-2xl [&_h1]:font-bold [&_h1]:text-zinc-50
            [&_h2]:mt-10 [&_h2]:border-t [&_h2]:border-zinc-800 [&_h2]:pt-6 [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:text-oro
            [&_h3]:mt-6 [&_h3]:text-sm [&_h3]:font-semibold [&_h3]:text-zinc-100
            [&_p]:mt-3 [&_p]:text-sm [&_p]:leading-relaxed [&_p]:text-zinc-300
            [&_ul]:mt-3 [&_ul]:list-disc [&_ul]:space-y-1.5 [&_ul]:pl-5 [&_ul]:text-sm [&_ul]:text-zinc-300
            [&_ol]:mt-3 [&_ol]:list-decimal [&_ol]:space-y-1.5 [&_ol]:pl-5 [&_ol]:text-sm [&_ol]:text-zinc-300
            [&_strong]:font-semibold [&_strong]:text-zinc-100
            [&_a]:text-oro [&_a]:underline [&_a]:underline-offset-4
            [&_code]:rounded [&_code]:bg-zinc-900 [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:font-mono [&_code]:text-[0.8em] [&_code]:text-zinc-200
            [&_hr]:my-8 [&_hr]:border-zinc-800
            [&_blockquote]:mt-4 [&_blockquote]:rounded-xl [&_blockquote]:bg-amber-500/10 [&_blockquote]:px-4 [&_blockquote]:py-3 [&_blockquote]:text-sm [&_blockquote]:leading-snug [&_blockquote]:text-amber-200 [&_blockquote]:ring-1 [&_blockquote]:ring-amber-500/20
            [&_blockquote_p]:mt-0 [&_blockquote_p]:text-amber-200
            [&_blockquote_strong]:text-amber-100
            [&_table]:mt-4 [&_table]:w-full [&_table]:border-collapse [&_table]:text-sm
            [&_th]:border-b [&_th]:border-zinc-700 [&_th]:px-2 [&_th]:py-2 [&_th]:text-left [&_th]:text-xs [&_th]:uppercase [&_th]:tracking-wide [&_th]:text-zinc-400
            [&_td]:border-b [&_td]:border-zinc-900 [&_td]:px-2 [&_td]:py-2 [&_td]:align-top [&_td]:text-zinc-300
          "
        >
          <ReactMarkdown remarkPlugins={[remarkGfm]}>{guia}</ReactMarkdown>
        </article>
      </div>
    </main>
  )
}
