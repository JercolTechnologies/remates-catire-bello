# Suspender una licencia

**Qué es esto.** El interruptor que cierra una instalación cuando la casa no paga. Está en el
despliegue, no en la base, y no hay que tocar código para usarlo.

Cuando está activo, la aplicación **no se pinta**: en su lugar sale una pantalla que dice
*«Licencia suspendida por falta de pago»* y a quién escribir. Da igual la ruta que se abra
—portada, `/login`, `/admin`, `/admin/login`—: todas caen en la misma pantalla.

---

## 1 · Cómo se activa

En el panel de Vercel del proyecto de esa casa:

1. **Settings → Environment Variables**, entorno **Production**:

   | Variable | Valor | Para qué |
   |---|---|---|
   | `LICENCIA_SUSPENDIDA` | `1` | Cierra la instalación. |
   | `LICENCIA_AVISO` | *(opcional)* | Reemplaza el texto por defecto de la pantalla. |

2. **Deployments → ⋯ → Redeploy** (o un commit, que hace lo mismo).

3. Comprobar en una ventana de incógnito: la pestaña debe decir **«Servicio suspendido»**.

**El redespliegue no es opcional.** Las páginas se generan en el build, así que la variable se
lee al construir. Cambiarla sin desplegar no hace nada — y eso se nota tarde. Tarda alrededor de
un minuto.

Para **levantar** la suspensión: poner la variable en `0` (o borrarla) y redesplegar. El
comportamiento por defecto, con la variable ausente, es **licencia activa**: un error de dedo
nunca deja a un cliente que paga con la web en blanco.

---

## 2 · Qué hace y qué NO hace

**Hace:**

- Cierra el producto entero, para todos: el dueño no puede entrar a su panel, el cajero no puede
  cobrar, el jugador no puede pujar.
- No toca un solo dato. Saldos, remates, historial y bitácora quedan exactamente igual.
- No invalida sesiones. Al levantar la suspensión cada uno vuelve a su sitio sin reentrar.
- Marca la página como `noindex`, para que el buscador no guarde la pantalla de suspension como
  si fuera el contenido del dominio.

**NO hace — y conviene tenerlo claro antes de confiar el cobro a esto:**

- **No cierra la base.** El navegador habla con Supabase directamente, con la llave anónima. Quien
  tenga esa llave y sepa llamar a la API REST sigue leyendo y escribiendo lo que la RLS permita.
  Esto cierra **la puerta de la casa**, no la caja fuerte.
- **No saca al licenciatario de su panel de Supabase.** Si él administra el proyecto, entra cuando
  quiera. Si de verdad hay que cortar el dato, hay que **pausar el proyecto de Supabase** o rotar
  las llaves — y eso sí es irreversible en caliente: los jugadores no pueden retirar mientras dure.
- **No cancela la deuda ni libera al licenciatario** de pagarle a sus jugadores. El dinero es suyo
  y su responsabilidad; la pantalla solo lo dice en voz alta.
- **No es una muralla criptográfica.** Alguien con una sesión válida y `curl` podría seguir
  llamando a rutas de API. Es un corte de servicio, no un DRM.

---

## 3 · Cuándo usarlo, y cuándo no

**Sí:** la casa dejó de pagar la licencia y quieres que se note, sin destruir nada y pudiendo
volver atrás en un minuto.

**Antes de cortar, avisa.** Una carta con fecha —«el acceso se suspende el día X»— resuelve la
mayoría de los casos y es lo único que un juez mira con buenos ojos. Cortar sin aviso, con saldos
de jugadores dentro, es como se convierte un impago en un pleito.

**No lo uses** si sospechas que el licenciatario está vaciando la caja o desapareciendo: ahí la
herramienta es pausar Supabase, y se asume el coste.

**Y tenlo presente:** el día que cortas, sus jugadores no pueden retirar. Si la casa no ha pagado
lo que debe a su gente, el que queda en la foto es el negocio de él, pero la mano que apagó la luz
fue la tuya.

---

## 4 · Lo que queda pendiente

- **Bandera en base de datos** para suspender sin redesplegar (un `update`, efecto en un minuto).
  Hoy no se hizo porque el interruptor no debe vivir dentro de lo que quizá hay que apagar.
- **Modo degradado**: cortar solo lo nuevo (recargas, pujas, remates) y dejar entrar y retirar.
  Es la versión que protege mejor a los jugadores y peor al cobrador.
- **Bloquear solo `/admin`**, si alguna vez interesa que los jugadores sigan jugando mientras se
  arregla el pago. Hoy no se ofrece: dejar el negocio funcionando gratis no es una suspensión.

Ver **ADR-053**.
