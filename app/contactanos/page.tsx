"use client"

import { useEffect, useMemo, useState } from "react"
import { supabase } from "@/lib/supabaseClient"
import { useCasa } from "@/app/components/MarcaCasa"

type SupportItem = {
  id: string
  label: string
  value: string
  type: "email" | "whatsapp" | "phone" | "social" | string
  href: string | null
  sort_order: number | null
}

function buildHref(type: string, value: string) {
  const clean = value.replace(/\s+/g, "")
  if (type === "email") return `mailto:${clean}`
  if (type === "whatsapp") {
    const digits = clean.replace(/[^0-9]/g, "")
    return digits ? `https://wa.me/${digits}` : null
  }
  if (type === "phone") {
    const digits = clean.replace(/[^0-9+]/g, "")
    return digits ? `tel:${digits}` : null
  }
  return null
}

export default function ContactanosPage() {
  // De quien son estos canales. En una casa licenciada, "escribenos" sin
  // nombre se lee como la plataforma -- y es justo al reves. Ver ADR-052.
  const casa = useCasa()
  const [items, setItems] = useState<SupportItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")

  useEffect(() => {
    ;(async () => {
      setLoading(true)
      setError("")
      const { data, error: err } = await supabase
        .from("support_settings")
        .select("id,label,value,type,href,sort_order")
        .eq("is_active", true)
        .order("sort_order", { ascending: true })

      if (err) {
        setError(err.message)
      } else {
        // Era `(data as any[])?.map(r => ({...r}))`: un `any` y una copia que
        // no servia para nada. La fila ya tiene la forma de SupportItem.
        setItems((data ?? []) as SupportItem[])
      }
      setLoading(false)
    })()
  }, [])

  const grouped = useMemo(() => {
    const groups: Record<string, SupportItem[]> = {}
    for (const item of items) {
      const key = String(item.type || "otro")
      if (!groups[key]) groups[key] = []
      groups[key].push(item)
    }
    return groups
  }, [items])

  return (
    <>
      <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 sm:px-6 lg:px-8 py-6">
        <div className="mx-auto w-full max-w-3xl">
          <div className="flex items-center justify-between">
            <h1 className="text-xl font-bold">Quejas, reclamos y sugerencias</h1>
          </div>

          {/* QUIEN RESPONDE, CON NOMBRE. Es el descargo mas util que hay en
              toda la aplicacion: el jugador que no ve su recarga tiene que
              saber a quien escribirle, y no es a la plataforma. */}
          <p className="mt-2 text-sm text-zinc-300">
            {casa ? (
              <>
                Esta casa la opera{" "}
                <span className="font-semibold text-zinc-100">{casa.nombre}</span>, que es quien
                recibe los depósitos, paga los retiros y responde por cualquier reclamo. Estos son
                sus canales:
              </>
            ) : (
              <>Escríbenos por los canales oficiales. Responderemos lo antes posible.</>
            )}
          </p>

          {loading ? (
            <div className="mt-4 text-sm text-zinc-400">Cargando...</div>
          ) : error ? (
            <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
              {error}
            </div>
          ) : items.length === 0 ? (
            <div className="mt-4 rounded-xl bg-amber-500/10 p-3 text-sm leading-snug text-amber-200 ring-1 ring-amber-500/20">
              <div className="font-semibold">Esta casa todavía no ha publicado sus canales</div>
              <div className="mt-1 text-amber-200/80">
                {casa ? `Avisa a ${casa.nombre}` : "Avisa al administrador"} para que ponga su
                correo o su WhatsApp. Mientras tanto no hay forma de contactarlos desde aquí.
              </div>
            </div>
          ) : (
            <div className="mt-4 space-y-3">
              {Object.entries(grouped).map(([type, list]) => (
                <div key={type} className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
                  <div className="text-xs uppercase tracking-wide text-zinc-400">
                    {type === "email"
                      ? "Correo"
                      : type === "whatsapp"
                      ? "WhatsApp"
                      : type === "phone"
                      ? "Teléfono"
                      : "Redes"}
                  </div>
                  <div className="mt-2 space-y-2">
                    {list.map((item) => {
                      const href = item.href || buildHref(item.type, item.value)
                      return (
                        <div key={item.id} className="flex items-center justify-between gap-2">
                          <div className="text-sm text-zinc-200">
                            <div className="text-xs text-zinc-400">{item.label}</div>
                            <div className="font-semibold">{item.value}</div>
                          </div>
                          {href ? (
                            <a
                              href={href}
                              target={item.type === "social" ? "_blank" : undefined}
                              rel={item.type === "social" ? "noreferrer" : undefined}
                              className="rounded-xl bg-white text-zinc-950 px-3 py-2 text-xs font-semibold"
                            >
                              Abrir
                            </a>
                          ) : null}
                        </div>
                      )
                    })}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </main>
    </>
  )
}
