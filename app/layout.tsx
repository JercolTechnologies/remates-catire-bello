import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import AvisosDelUsuario from "./components/AvisosDelUsuario";
import CabeceraCliente from "./components/CabeceraCliente";
import NavegacionCliente from "./components/NavegacionCliente";
import { RematesEnVivo } from "./components/RematesEnVivo";
import { SesionCliente } from "./components/SesionCliente";
import { pieDePagina } from "@/lib/marca";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Remate Catire Bello",
  description: "Remates hipicos en vivo: puja por un caballo y llevate el pozo si gana la carrera.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        {/* Los avisos al usuario viven AQUI, por encima de todas las pantallas.
            Un aviso que solo existe en la pantalla que lo muestra no es un
            aviso (ADR-026). Sin sesion no pinta ni consulta nada. */}
        <AvisosDelUsuario />
        {/* Y una sola suscripcion al canal de la coleccion de remates, que
            alimenta la lista publica, el contador del menu y la lista del
            admin. Ver components/RematesEnVivo.tsx */}
        <RematesEnVivo>
        {/* Quien eres y cuanto tienes, preguntado UNA vez para la cabecera y
            la barra inferior. Ver components/SesionCliente.tsx */}
        <SesionCliente>
        <div className="min-h-screen flex flex-col">
          {/* La cabecera del jugador: marca, menu de escritorio, y usuario y
              saldo arriba a la derecha. Decide ella sola si toca pintarla.
              Va AQUI y no al final: es `sticky top-0`, y un elemento pegado
              arriba tiene que estar arriba en el documento. */}
          <CabeceraCliente />
          <div className="flex-1">{children}</div>
          <footer className="py-4 text-center text-xs text-zinc-400">
            {/* El año lo calcula lib/marca.ts. Estuvo clavado a mano como
                "©2026" desde enero, y en enero de 2027 habria mentido. */}
            {pieDePagina()}
          </footer>
          {/* El menu de cliente en movil, una sola vez para toda la
              aplicacion. Ver components/NavegacionCliente.tsx */}
          <NavegacionCliente />
        </div>
        </SesionCliente>
        </RematesEnVivo>
      </body>
    </html>
  );
}
