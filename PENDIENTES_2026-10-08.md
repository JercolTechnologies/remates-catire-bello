# Pendientes — al 8 de octubre de 2026

Sustituye a `PENDIENTES_2026-10-07.md`, que queda como histórico. Lo cerrado no se
detalla aquí: está en `ADR.md` (49 decisiones) y en el arnés.

**Estado del proyecto:** 75/75 en `tests/pruebas_dinero.sql`, 4/4 en
`tests/concurrencia.sql`, 30 en `tests/fechas.mjs`, 33 en `tests/log.mjs`,
31 en `tests/aviso_puja.mjs`. 47 migraciones, 49 ADRs.

---

## Cerrado del 7 al 10 de octubre

| Qué | Dónde |
|---|---|
| **Aviso del incremento ANTES de pujar**: el botón lleva la cifra, cuadro con precio, incremento, total y saldo | ADR-035, `aviso_puja.mjs` |
| La comprobación de saldo del frontend pasa a céntimos enteros | ADR-035 |
| **`crear_remate_completo`**: crear deja de ser cinco escrituras sueltas | ADR-036, `20261007130000`, P67 → **cierra el 1.1** |
| **`guardar_escaleras`**: el reemplazo de escaleras es una transacción | ADR-037, `20261007150000`, P68 |
| `remate_price_rules` baja a **solo lectura** para `authenticated` | ADR-037, P48 |
| **La bitácora deja de anunciar lo que no pasó**, y dice qué cambió por caballo | ADR-038, `20261007170000`, P69 |
| `db push --dry-run` y `migration list` entran en el ciclo | `COMO_APLICAR.md` |
| Claude ejecuta los comandos locales; Jota conserva el push a la base y todo git | `CLAUDE.md` §1 |
| **`guardar_remate_completo`**: editar un remate es una transacción, y los cambios de un caballo dejan asiento | ADR-039, `20261008150000`, P70 |
| `races` y `horses` bajan a **solo lectura**: cerradas las tres tablas del catálogo | ADR-039, P48 |
| **Navegación del panel de admin**: barra lateral en pc, barra inferior con cajón en móvil; fuera los «Volver» | ADR-040 |
| **Navegación del lado cliente**: cabecera con marca, menú en pc y usuario + saldo arriba a la derecha | ADR-040 |
| **Los anchos dejan de ser de móvil en escritorio**: `Contenedor.tsx` y la lista de remates en rejilla | ADR-040 |
| El `©2026` del pie lo calcula `lib/marca.ts` | ADR-040 |
| **`/admin` deja de ser un menú duplicado** y pasa a «Estado de la casa»: cola de trabajo con antigüedad, balance y resultado | ADR-041 |
| **«Se debe» discriminado**: saldos de jugadores y retiros por pagar, por separado — y sin migración | ADR-041 |
| **Vectoriales de la marca**, sacados de los PNG: 7 SVG, versión mono recoloreable | `docs/MARCA.md`, `marca_vectorizar.py` |
| **La marca, cableada**: `lib/marca.ts` deja de ser una costura sin coser; SVG en toda la interfaz | ADR-042 |
| Los iconos se mudan a `app/`: favicon, icono de iOS y vista previa al compartir | ADR-042 |
| **Los números de dos caballos ya se pueden intercambiar**: la única pasa a diferible | ADR-043, `20261010140000`, P71 → **cierra el 1.1** |
| **El doble clic ya no crea dos remates**: clave de idempotencia con índice único detrás | ADR-044, `20261010150000`, P72 → **cierra el 1.2** |
| **`demo_seed.sql`**: monta una demo creíble con la contabilidad cuadrada, probado contra base limpia | `docs/supabase/demo_seed.sql` |
| **Corregido el instalador**: decía «dos variables» y son **diez**; la comprobación que daba no encontraba las de correo | `INSTALACION_LICENCIATARIO.md` |
| **`fundar_super_admin`**: el licenciatario funda su propia casa; Jercol deja de entrar a la base del cliente | ADR-045, `20261010193000`, P73 → **cierra el 5.3** |
| **`AvisoFundar`**: una instalación nueva ya sabe decirle a su dueño cómo empezar | ADR-045 |
| **El fundador ya encuentra el registro**: `/admin/login` enlaza a `/register` cuando la casa no tiene dueño — bloqueó la primera instalación real | ADR-046 |
| **Los errores de entrada dejan de ser los de Supabase en inglés**: `mensajeDeEntrada()`, por `code` y no por texto | ADR-046 |
| **Los datos de cobro salen del código**: nueve claves por instalación, `datos_de_cobro()` solo con sesión, y escribir deja asiento | ADR-047, `20261011011500`, P74 |
| Se cierra el `UPDATE` directo sobre `ajustes_instalacion`: todo pasa por `guardar_ajustes()` | ADR-047, P74 |
| **`/admin/super/ajustes`**: el dueño pone sus datos de cobro y el nombre de su casa, con vista previa de lo que verá el jugador | ADR-047 |
| **`/dashboard/recargar` deja de inventar**: lee de `datos_de_cobro()` y esconde el formulario si la casa no tiene dónde cobrar | ADR-047 |
| **Documentos legales versionados e inmutables**, con registro de quién aceptó qué versión y cuándo | ADR-048, `20261011023500`, P75 |
| **La marca de la casa manda donde la ve el jugador**; la plataforma, en el panel. `CASA` deja de ser constante y se lee de la base | ADR-049 |

---

## 1 · Lo que yo haría primero

### 1.1 · `guardar_soporte` — la última tabla del panel que se escribe directo
`support_settings` sigue con `insert`, `update` y `delete` para `authenticated`, y
`/admin/super/soporte` la escribe con un `delete` de los que sobran más un `insert` y
un `update` por fila: el mismo patrón que ya corregimos dos veces. Es la única tabla
del panel que queda abierta, y sus datos son los que ve el público en `/contactanos`.

Estuvo agrupada con las tres del catálogo del remate hasta el 08/10 por un error de
la nota de P48; no tiene nada que ver con `crear_remate_completo` ni con
`guardar_remate_completo`.

### 1.2 · Cerrar `remates.insert`
El `GRANT` sigue puesto aunque ya nadie lo use: desde el ADR-036 crear un remate pasa
por la RPC. P36 lo documenta pero no lo comprueba, a propósito, para no ponerse roja
por algo que decidimos dejar así. Es una línea de migración y apretar P36.

---

## 2 · Dinero y operación

- **Estado del remate: dos fuentes para un hecho.** Se guarda `'abierto'` aunque
  `opens_at` sea futuro, porque el enum `remate_status` tiene cuatro valores y ninguno
  es `'programado'`. Hoy no se cuela nadie porque `hacer_puja` compara `opens_at`
  aparte, pero el estado guardado es falso. ADR-015.
- **El reloj del NAVEGADOR decide si un remate está abierto.** `app/remates/[id]/page.tsx`
  hace `Date.now()` y lo compara con `opens_at`/`closes_at` para enseñar «no está
  abierto para pujar». La base lo comprueba aparte y bien, así que **no hay riesgo de
  dinero**; pero a un jugador con la hora desfasada le pasa una de dos: ve cerrado algo
  abierto y no puede pujar sin explicación, o ve abierto algo cerrado y se come un error
  del servidor. Para un licenciatario son llamadas de soporte imposibles de diagnosticar.
- **Cambiar una escalera no emite señal de realtime.** No hay ningún trigger sobre
  `remate_price_rules`, así que las pantallas abiertas siguen enseñando el mínimo viejo
  hasta que alguien recargue.
- **«Se debe» discriminado: hecho en `/admin`, pendiente en `/admin/contabilidad`.**
  La suma `obligaciones = saldos + retiros pendientes` **es correcta y está
  comprobada** (09/10): `solicitar_retiro` descuenta el saldo al pedir el retiro,
  así que un retiro pendiente ya salió de `saldos` y no se cuenta dos veces. Que
  nadie «arregle» un defecto que no existe. El desglose ya se ve en «Estado de la
  casa» (ADR-041) usando `saldo_usuarios` y `retiros_pendientes` de
  `admin_contabilidad_resumen`, **sin tocar la base**. La tarjeta de contabilidad
  sigue enseñando solo el total: es el mismo cambio de dos líneas, cuando se pula
  esa pantalla.
- **Pantalla de solicitudes rechazadas.** `/admin/log` ya deja verlas en Acciones, pero
  no hay una lista de solicitudes por estado.
- **Campos de recarga según el método de pago.** Regla de Jota: titular y **últimos 4
  dígitos, nunca el número completo**.
- **Reglas propias: aceptarlas explícitamente**, y que se vea en la ficha del caballo.
- **`remate_minimos.soy_lider` devuelve NULL** para un visitante sin sesión. Un
  `coalesce(..., false)`.
- **El arnés no tiene guarda contra producción.** Solo un comentario en la línea 4, y
  desde P69 además borra `admin_actions`. Cobra importancia con un agente por CLI que
  puede tener una cadena de conexión de producción a mano.

---

## 3 · Notificaciones fuera de la app

Lo de dentro ya está. Falta lo de fuera, que es lo que sirve cuando el admin cerró el
navegador: recarga aprobada o rechazada, retiro procesado y remate nuevo, por **correo,
WhatsApp y Telegram**; y `NOTIFY_EMAIL_TO` como lista desde los ajustes de instalación.

---

## 4 · Interfaz

Lo de la navegación y los anchos se cerró el 09/10 (ADR-040). Queda:

- **Un intercambio de números correcto se ve igual que uno que no hizo nada.**
  Al guardar, la pantalla recarga los caballos con `.order("numero")`, así que la
  columna de números vuelve a leerse 1, 2, 3… y lo único que se movió son los
  nombres. Jota lo dio por fallido el 10/10 cuando en realidad había funcionado;
  lo zanjó `/admin/log`, que sí lo dice (`Caballo 1 numero: 1 → 2`). No es un
  defecto de datos, es de acuse de recibo: el guardado no cuenta qué cambió.
  Lo barato sería que el mensaje de «Cambios guardados» resumiera lo que la base
  devolvió.

- **`/dashboard/retirar` enseña «Saldo total», que es la misma cifra de la cabecera.**
  Por el criterio que dio Jota —no repetir el mismo dinero dos veces en una pantalla—
  debería entrar en la lista de pantallas que lo ocultan. Él nombró dos (su panel y la de
  pujar), así que lo dejo preguntado, no decidido. Es una línea en `yaEnsenaElSaldo`,
  en `components/CabeceraCliente.tsx`.
- **`/reglas` no está en el menú.** La barra inferior ya lleva cinco botones y un sexto en
  un móvil estrecho los deja ilegibles. Hoy se llega desde el enlace de la lista de
  remates y del registro. Si Jota la quiere en el menú, hay que sacar otra.
- **Ver incremento y pozo por caballo** desde la pantalla de admin.
- **`/contactanos`**: la información está, los enlaces no son activos.
- **El logo «parece muy IA»** — criterio de Jota. Los vectoriales ya **no** dependen
  del diseñador: se sacaron de los propios PNG el 10/10 (`herramientas/marca_vectorizar.py`,
  siete SVG, el isotipo de 1.008 KB a **4,3 KB**). Al diseñador le sigue conviniendo
  pedirle el suyo para tener **el metal en vector**, pero no bloquea nada. Y si lo que
  molesta es el aspecto «IA», el culpable es el biselado 3D con destellos: la versión
  plana de estos SVG lo quita sin tocar el dibujo.
- ~~**La marca del licenciatario todavía es una constante.**~~ **Cerrado el 11/10**
  (ADR-049). Sale de `ajustes_instalacion`, se lee en el servidor y baja por contexto. Y
  la jerarquía se invirtió: **la casa manda donde la ve el jugador; la plataforma, en el
  panel, donde la ve el dueño.** Se tocó en seis archivos y en ninguna pantalla — lo que
  ADR-042 compró.
- ⚠️ **Subir el logo de la casa, no pegar una URL.** `casa_logo_url` es un campo de texto.
  Un dueño de remates tiene un PNG en el teléfono, no una URL. Con la casa ya dominante
  en la pantalla del jugador esto dejó de ser un detalle: Supabase Storage, un bucket,
  política de subida solo para super admin, y un control de archivo en
  `/admin/super/ajustes`. Mientras tanto el respaldo es digno — el nombre bien
  tipografiado — pero no es lo que se promete al enseñar el producto.
- **El isotipo se usa en versión con degradado, no `-mono`.** Las piezas `-mono`
  (`currentColor`) existen y están listas, pero nadie las usa todavía. Son las que harán
  falta el día que un licenciatario quiera su color.

---

## 5 · Bloque de licenciamiento

### 5.1 · Permisos por área — el momento es la ventana entre firmar el primer licenciatario y que arranque
Hoy todos los admins pueden todo. La identidad (ADR-027) y la separación de funciones
(ADR-028) lo hacen auditable y sin autoservicio, que es lo que compra el tiempo. Falta
decidir quién aprueba recargas, quién paga retiros, quién liquida y quién mete asientos.

### 5.2 · Los intentos fallidos no se registran
`exception when others → log_admin_action(success := false) → raise` **no registra
nada**: al re-lanzar, PostgreSQL aborta la transacción y se lleva el propio asiento.
`admin_actions` no puede contener ni una fila con `success = false`. El filtro «solo las
que fallaron» de `/admin/log` devuelve siempre vacío — tranquilidad falsa. PostgreSQL no
tiene transacciones autónomas. **Decisión de Jota, diferida.**

### 5.3 · Lo que es «de la casa» y sigue clavado en el código
Es el bloque que queda antes de poder entregarle una instalación a alguien que cobre
dinero de verdad. Todo va a `ajustes_instalacion`:

- ~~⛔ **Datos bancarios de recarga.**~~ **Cerrado el 11/10** (ADR-047, `20261011011500`,
  P74). Viven en `ajustes_instalacion`, los pone el dueño desde `/admin/super/ajustes`, y
  si faltan la pantalla de recargar lo dice en vez de inventarlos.
- ~~**Nombre de la casa.**~~ **Cerrado el 11/10** (ADR-049). Queda solo la subida del
  logo, anotada en el 4.
- **Quién responde por el dinero.** `/reglas` no lo dice. La marca que ve el jugador es
  la de la plataforma (decisión del 09/10), así que el jugador que pierda dinero va a
  reclamarle a la plataforma. Tiene que leer, con nombre y apellido, de quién es la casa.
- **Correo de avisos.** `SMTP_USER` y `NOTIFY_EMAIL_TO` en Vercel: si quedan los del
  proveedor, los avisos de recarga del cliente llegan a la bandeja equivocada.
- **Zona horaria.** `America/Caracas` clavada en `SelectorFechaHora.tsx` y
  `buildCaracasTs()`. Un licenciatario fuera de Venezuela crearía remates con horas
  corridas y no se enteraría hasta que un jugador se queje.

### 5.4 · Resto del bloque
- **Ganancias por remates discriminadas** (decisión de Jota pendiente, y es de negocio,
  no técnica). Hoy salen en una sola cifra. El reparto YA existe dentro de
  `admin_contabilidad_resumen`: el CTE `calc` distingue `ganador_user_id is null`
  → la casa se queda el pozo entero, si no → `pozo * pct/100`. Sale sumado en
  `remates_casa_total`. Son **dos claves más en el jsonb**, sin cambio de tipo de
  retorno — migración trivial. Lo que hay que decidir primero: las categorías
  honestas son **tres**, no dos. (1) Comisión sobre pozos que ganó un jugador.
  (2) Pozos completos que ganó la casa. (3) **Los caballos que nadie pujó**, que la
  casa banca por su `precio_salida` y entran al pozo sin que nadie ponga ese dinero
  — hoy mezclados dentro de (1) y (2). ¿Es (3) una categoría propia?
- **Ajustes de instalación completos**: datos bancarios, % de la casa por defecto, SMTP,
  marca. Hoy la tabla tiene tres claves.
- **Marca configurable**: `BrandLogo.tsx`, textos y assets están fijos a «Catire Bello».
- **Guarda en `reset_datos_prueba.sql`**: que aborte si detecta dinero real.
- **Panel de licencias**, separado y de Jercol.
- **Estados Unidos en la lista de países**, y una API pública de resultados.

---

## 6 · Herramientas

- **`herramientas/quien_usa.py`.** Enumeraría dónde aparece un identificador en
  `supabase/migrations/`, `tests/`, `app/` y `lib/` antes de cerrar o cambiar algo.
- **La lección, confirmada otra vez el 07/10:** lo que atrapa defectos son los controles
  que **se ejecutan**. El arnés encontró el `42702`; el censo P47 encontró la RPC sin
  declarar; la medición encontró que la restricción de números repetidos ya existía
  cuando yo afirmaba lo contrario. Las reglas escritas no atraparon ninguno.
