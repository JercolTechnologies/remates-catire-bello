import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import Link from "next/link";
import AvisosDelUsuario from "./components/AvisosDelUsuario";
import AvisoFundar from "./components/AvisoFundar";
import AvisoSuspension from "./components/AvisoSuspension";
import CabeceraCliente from "./components/CabeceraCliente";
import NavegacionCliente from "./components/NavegacionCliente";
import { RematesEnVivo } from "./components/RematesEnVivo";
import { SesionCliente } from "./components/SesionCliente";
import { pieDePagina, tituloDocumento, enlaceContacto, ICONOS, PLATAFORMA } from "@/lib/marca";
import { casaDeLaInstalacion } from "@/lib/marcaCasa";
import { estadoDeLicencia } from "@/lib/licencia";
import { ProveedorMarcaCasa } from "./components/MarcaCasa";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

// EL TITULO SALE DE lib/marca.ts, NO DE AQUI.
//
// Estaba escrito a mano, y era el quinto sitio con el nombre clavado. Si hay
// una casa licenciataria, `tituloDocumento()` la pone detras de la nuestra:
// la plataforma manda (decision de Jota, 09/10).
//
// `metadataBase` hace falta para que la vista previa al compartir el enlace
// apunte a una URL absoluta. Sin el, Next avisa en el build y las redes
// sociales se quedan sin imagen. Sale de la variable que Vercel pone sola, con
// respaldo a localhost para que `next dev` no se queje.
const DESCRIPCION =
  "Remates hipicos en vivo: puja por un caballo y llevate el pozo si gana la carrera.";

// El titulo depende de QUE CASA es esta instalacion, y eso vive en la base.
// Por eso deja de ser una constante: `generateMetadata` corre en el servidor y
// puede leerla. La lectura esta cacheada cinco minutos (lib/marcaCasa.ts), asi
// que esto no convierte cada visita en una consulta.
export async function generateMetadata(): Promise<Metadata> {
  // LA LICENCIA MANDA SOBRE TODO LO DEMAS (ADR-053). Si la instalacion esta
  // suspendida no se consulta la casa: la pestana tiene que decir que esta
  // cerrada, no el nombre de un remate que ya no esta operando. Y `noindex`
  // evita que el buscador guarde la pantalla de suspension como contenido de
  // un dominio que, con suerte, manana vuelve a estar abierto.
  const licencia = estadoDeLicencia();
  if (licencia.suspendida) {
    return {
      title: "Servicio suspendido",
      description: "El acceso a esta instalación está temporalmente cerrado.",
      robots: { index: false, follow: false },
    };
  }

  const casa = await casaDeLaInstalacion();
  const titulo = tituloDocumento(casa);

  return {
    metadataBase: new URL(
      process.env.NEXT_PUBLIC_SITIO ??
        (process.env.VERCEL_PROJECT_PRODUCTION_URL
          ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`
          : "http://localhost:3000")
    ),
    title: titulo,
    description: DESCRIPCION,
    // EL ICONO DE LA PESTANA Y LA VISTA PREVIA, POR INSTALACION (ADR-051).
    //
    // Esto solo funciona porque los archivos `app/icon.png`,
    // `app/apple-icon.png`, `app/favicon.ico` y `app/opengraph-image.png` se
    // BORRARON. Mientras existieran ganaban ellos: la documentacion dice que
    // "file-based metadata has the higher priority and will override the
    // metadata object and generateMetadata function". Los mismos archivos
    // siguen disponibles en `public/marca/`, byte a byte.
    icons: {
      icon: casa?.logo || ICONOS.icono,
      apple: casa?.logo || ICONOS.apple,
    },
    openGraph: {
      title: titulo,
      description: DESCRIPCION,
      // `siteName` es el nombre del SITIO que comparte el enlace, y para el
      // jugador ese sitio es su casa, no la plataforma.
      siteName: casa ? casa.nombre : PLATAFORMA.nombre,
      images: [casa?.logo || ICONOS.compartir],
      type: "website",
    },
  };
}

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  // EL INTERRUPTOR (ADR-053). Va lo PRIMERO, antes de leer la casa y antes de
  // montar proveedores: si la licencia esta suspendida no se consulta la base,
  // no se abre el canal de remates y no se pinta ninguna pantalla del producto
  // -- ni `/admin/login`. La pantalla de suspension ES la aplicacion entera.
  const licencia = estadoDeLicencia();
  if (licencia.suspendida) {
    return (
      <html lang="es">
        <body
          className={`${geistSans.variable} ${geistMono.variable} antialiased`}
        >
          <AvisoSuspension aviso={licencia.aviso} />
        </body>
      </html>
    );
  }

  // Una sola lectura para toda la aplicacion: el titulo de arriba, el pie de
  // abajo y las cabeceras de cliente y de admin salen de aqui. Cacheada.
  const casa = await casaDeLaInstalacion();
  const pie = pieDePagina(casa);

  return (
    <html lang="es">
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
        {/* La marca de la casa, resuelta en el servidor y repartida por
            contexto. Ver lib/marcaCasa.ts y components/MarcaCasa.tsx */}
        <ProveedorMarcaCasa valor={casa}>
        <RematesEnVivo>
        {/* Quien eres y cuanto tienes, preguntado UNA vez para la cabecera y
            la barra inferior. Ver components/SesionCliente.tsx */}
        <SesionCliente>
        <div className="min-h-screen flex flex-col">
          {/* "Esta casa todavia no tiene dueno". Se apaga solo y para siempre
              en cuanto alguien funda. Ver components/AvisoFundar.tsx */}
          <AvisoFundar />
          {/* La cabecera del jugador: marca, menu de escritorio, y usuario y
              saldo arriba a la derecha. Decide ella sola si toca pintarla.
              Va AQUI y no al final: es `sticky top-0`, y un elemento pegado
              arriba tiene que estar arriba en el documento. */}
          <CabeceraCliente />
          <div className="flex-1">{children}</div>
          {/* EL PIE. Texto de Jota (11/10): dice de quien es la plataforma,
              quien la desarrollo y QUIEN LA OPERA. La segunda linea solo
              aparece si hay casa. El año lo calcula lib/marca.ts: estuvo
              clavado como "©2026" desde enero y en enero de 2027 habria
              mentido.

              El enlace de contacto va aqui por decision de Jota, sabiendo que
              lo ve tambien el jugador. El mensaje va prerrellenado para
              encauzar a quien escriba. */}
          <footer className="px-4 py-5 text-center text-xs leading-relaxed text-zinc-400">
            <div>{pie.principal}</div>
            {pie.licencia ? <div className="mt-0.5 text-zinc-500">{pie.licencia}</div> : null}
            {/* Primero el de la CASA. El jugador que baja al pie suele venir
                con un problema, y lo primero que tiene que encontrar es a
                quien se lo resuelve -- no a nosotros. */}
            <div className="mt-1">
              <Link
                href="/contactanos"
                className="text-zinc-400 underline underline-offset-4 hover:text-zinc-200"
              >
                Quejas, reclamos y sugerencias
              </Link>
            </div>
            <a
              href={enlaceContacto("licencia")}
              target="_blank"
              rel="noopener noreferrer"
              className="mt-1 inline-block text-zinc-500 underline underline-offset-4 hover:text-zinc-300"
            >
              ¿Quieres tu propio remate? Escríbenos
            </a>
          </footer>
          {/* El menu de cliente en movil, una sola vez para toda la
              aplicacion. Ver components/NavegacionCliente.tsx */}
          <NavegacionCliente />
        </div>
        </SesionCliente>
        </RematesEnVivo>
        </ProveedorMarcaCasa>
      </body>
    </html>
  );
}
