import Link from "next/link"
import { HeroLogo } from "@/app/components/BrandLogo"
import { PLATAFORMA } from "@/lib/marca"

export default function Home() {
  return (
    <main className="min-h-screen flex flex-col items-center justify-center bg-zinc-950 text-zinc-50">
      <div className="mb-5">
        <HeroLogo />
      </div>
      {/* El nombre ya esta DENTRO del logo. Repetirlo debajo en texto era
          decirlo dos veces, y ademas estaba escrito a mano: decia "Remates
          Catire Bello" cuando la marca es "Remate Catire Bello", en singular.
          El h1 se queda para los lectores de pantalla y para el buscador, que
          sí necesitan un encabezado de verdad, y sale de lib/marca.ts. */}
      <h1 className="sr-only">{PLATAFORMA.nombre}</h1>
      <p className="mt-3 text-zinc-400 text-sm">
        Bienvenido a tu casa de remates digital.
      </p>

      <div className="mt-6 grid w-full max-w-xs grid-cols-1 gap-2">
        <Link
          href="/remates"
          className="inline-block rounded-lg bg-white px-4 py-2 text-center text-sm font-semibold text-zinc-950"
        >
          Ver remates en vivo
        </Link>
        <Link
          href="/login"
          className="inline-block rounded-lg bg-zinc-900/60 border border-zinc-800 px-4 py-2 text-center text-sm font-semibold"
        >
          Iniciar sesión
        </Link>
        <Link
          href="/register"
          className="inline-block rounded-lg bg-zinc-900/60 border border-zinc-800 px-4 py-2 text-center text-sm font-semibold"
        >
          Registrarme
        </Link>
      </div>
    </main>
  )
}
