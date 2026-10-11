"use client"

// ===========================================================================
//  components/MarcaCasa.tsx  -  LA CASA, RESUELTA UNA VEZ PARA TODA LA APP
//
//  El servidor la lee en el layout (`lib/marcaCasa.ts`) y la mete aqui. Los
//  componentes de cliente la consumen con `useCasa()` sin una sola consulta
//  extra: es el mismo patron que `SesionCliente` -- lo que vale para toda la
//  aplicacion vive POR ENCIMA de las pantallas (ADR-026).
//
//  `null` significa "esta instalacion es la de la plataforma". No es un error
//  ni un estado de carga: es el caso de nuestra propia casa, donde la casa y
//  la plataforma son la misma cosa y no hay una segunda marca que pintar.
// ===========================================================================

import { createContext, useContext } from "react"
import type { MarcaCasa } from "@/lib/marcaCasa"

const Ctx = createContext<MarcaCasa>(null)

export function ProveedorMarcaCasa({
  valor,
  children,
}: {
  valor: MarcaCasa
  children: React.ReactNode
}) {
  return <Ctx.Provider value={valor}>{children}</Ctx.Provider>
}

export function useCasa(): MarcaCasa {
  return useContext(Ctx)
}
