# Pendientes — al 5 de octubre de 2026

Sustituye a `PENDIENTES_2026-10-01.md`, que se queda como histórico. Lo cerrado
no se detalla aquí: está en `ADR.md` (31 decisiones) y en el arnés.

**Estado del proyecto:** 63/63 en `tests/pruebas_dinero.sql`, 4/4 en
`tests/concurrencia.sql`, 31 en `tests/fechas.mjs`, 32 en `tests/log.mjs`.
35 migraciones, 31 ADRs.

---

## Cerrado entre el 1 y el 5 de octubre

| Qué | Dónde |
|---|---|
| Motivo de rechazo, con lista y nota, visible al cliente | `20261001130000`, P56 |
| Regla del 50% apostado para poder retirar | `20261001120000`, P55 |
| Hora de apertura opcional, y los horarios se pueden **quitar** | ADR-021, P57 |
| El panel de contabilidad deja de dar una alarma falsa | ADR-022, P58 |
| **Registro de transacciones** (movimientos, libro, acciones) | ADR-023, `/admin/log` |
| Realtime que se supervisa, reconecta y recarga al volver | ADR-025 |
| El aviso de caja vive en el panel, no en una pantalla | ADR-026 → **cierra el 2.1** |
| **Identidad de los admins**: código, nombre, alta y baja | ADR-027, P59 |
| Nadie procesa su propia solicitud | ADR-028, P60 |
| `CLAUDE.md` en el repo | **cierra el 6.1** |
| Runbook de alta de licenciatario | `docs/supabase/INSTALACION_LICENCIATARIO.md` |
| Números de caballo repetidos: el formulario ya no deja guardarlos | **tapa el agujero del 1.1** |
| `/reglas` reescrita: lee de la base y describe el modelo real | ADR-029, P63 |
| **Aviso al ganador** al liquidar, en vivo y al iniciar sesión | ADR-030, P61 |
| **Canal de la colección**: un remate nuevo aparece solo | ADR-031, P62 |

---

## 1 · Lo que yo haría primero

### 1.1 · `crear_remate_completo` transaccional — el agujero está tapado, la causa no
Desde el 05/10 el formulario **no deja guardar dos caballos con el mismo
número**, que era el único camino conocido que dejaba un remate abierto con
cero caballos. Pero crear un remate siguen siendo **cuatro escrituras separadas**
(`races`, `remates`, `horses`, `remate_price_rules`) sin transacción: cualquier
otro fallo a mitad vuelve a dejar basura visible al público.

Lo que falta es el RPC transaccional. Ya no es urgente; sigue siendo correcto.

*Aceptación:* forzar el fallo en el paso de reglas y comprobar que no queda
ninguna carrera ni remate.

### 1.2 · Las notificaciones que faltan, que ahora son una línea cada una
La tabla, el canal por usuario y el popup ya están (ADR-030). Quedan por
enganchar, llamando a `_notificar` donde corresponde:

- recarga aprobada → en `aprobar_recarga`
- recarga rechazada, **con su motivo** → en `rechazar_recarga`
- retiro pagado o rechazado → en `procesar_retiro`

Es la mitad del punto 3 de este documento, y la barata.

### 1.3 · El `ClientBottomNav` pegado a mano en 6 pantallas
Con 3 condiciones distintas; en `/remates` se oculta para admins. Cualquier
pantalla nueva nace sin él. El patrón correcto ya existe dos veces en el repo:
el layout de `/admin` (ADR-026) y el popup de avisos en el layout raíz.

## 2 · Dinero y operación

- **1.3 del documento viejo — estado del remate: dos fuentes para un hecho.** El
  formulario escribe `estado: "abierto"` siempre, aunque `opens_at` sea futuro.
  Hoy no se cuela nadie porque `hacer_puja` compara `opens_at` aparte, pero el
  estado guardado es falso. ADR-015.
- **Pantalla de solicitudes rechazadas.** `/admin/log` ya deja ver los rechazos
  en la pestaña de Acciones, pero no hay una lista de solicitudes por estado.
- **Campos de recarga según el método de pago.** Regla fijada por Jota: titular y
  **últimos 4 dígitos, nunca el número completo**.
- **Modal de confirmación al crear un remate**, con los tres números de dinero a
  la vista antes de escribir nada.
- **Aviso del incremento ANTES de pujar**, no al pujar: *«ahí el usuario decide
  si puja con el incremento o lo deja ahí»*.
- **Reglas propias: aceptarlas explícitamente**, y que se vea en la ficha del
  caballo que las tiene, no solo la casilla marcada.
- **`remate_minimos.soy_lider` devuelve NULL** para un visitante sin sesión. Un
  `coalesce(..., false)`.

---

## 3 · Notificaciones fuera de la app

Lo de dentro ya está (ADR-026). Falta lo de fuera, que es lo que sirve cuando el
admin cerró el navegador:

- **Al cliente:** recarga aprobada o rechazada (con su motivo), retiro procesado,
  remate nuevo.
- **Correo, WhatsApp y Telegram.** Intención de Jota a medio hacer.
- **`NOTIFY_EMAIL_TO` como lista**, desde los ajustes de instalación.

---

## 4 · Interfaz

- **Navbar arriba.** Decisión de forma pendiente de Jota.
- **Nombre de usuario visible en todas las secciones, y debajo el saldo**, como
  en las casas de apuestas.
- **`ClientBottomNav` está pegado a mano en 6 pantallas con 3 condiciones
  distintas** (en `/remates` se oculta para admins). Cualquier pantalla nueva
  nace sin él. El patrón correcto ya existe: un layout de cliente, como el que
  se hizo para `/admin`.
- **Ver incremento y pozo por caballo** desde la pantalla de admin.
- **`/contactanos`**: la información está, los enlaces no son activos.
- **`©2026` clavado** en el pie.
- **El logo «parece muy IA»** — criterio de Jota.

---

## 5 · Bloque de licenciamiento

### 5.1 · Permisos por área — **el momento es la ventana entre firmar el primer licenciatario y que arranque**
Hoy todos los admins pueden todo. La identidad (ADR-027) y la separación de
funciones (ADR-028) hacen que eso sea **auditable y sin autoservicio**, que es lo
que compra el tiempo. Lo que falta es decidir quién aprueba recargas, quién paga
retiros, quién liquida y quién mete asientos en el libro.

Ni antes —sería adivinar la lista sin haber visto operar a nadie— ni después
—sería editar las guardas de todas las funciones de dinero con clientes en
marcha—.

### 5.2 · Los intentos fallidos no se registran — **apuntado el 05/10, decisión diferida**
`aprobar_recarga` tiene un `exception when others → log_admin_action(success :=
false) → raise`. **No registra nada.** Medido ejecutándolo: al re-lanzar,
PostgreSQL aborta la transacción y se lleva el propio asiento. `admin_actions`
no puede contener ni una fila con `success = false`. Cero.

Dos consecuencias: el filtro «solo las que fallaron» de `/admin/log` devuelve
siempre vacío —tranquilidad falsa—, y un admin puede intentar veinte veces algo
que no le toca sin dejar rastro.

PostgreSQL no tiene transacciones autónomas. Las salidas: `dblink` (descartado
por ADR-020) o que el frontend, al capturar el error, llame a una RPC aparte —esa
sí persiste, pero el dato lo aporta el cliente, así que vale como ayuda de
auditoría y no como control—. **Decisión de Jota, diferida a este bloque.**

### 5.3 · `fundar_super_admin` para quitar el único paso manual del alta
Hoy el primer super admin se funda con un `update` a mano (documentado en
`INSTALACION_LICENCIATARIO.md`). Con N clientes son N oportunidades de
equivocarse.

La forma limpia lleva **dos** candados: que solo funcione si no existe ningún
super admin —se cierra sola para siempre— y que el correo coincida con uno puesto
en `ajustes_instalacion` durante la instalación. Sin el segundo, cualquiera que
se registre antes que el dueño se queda con la casa.

### 5.4 · Resto del bloque
- **Ajustes de instalación completos**: datos bancarios, % de la casa por
  defecto, SMTP, marca. Hoy la tabla tiene tres claves.
- **Marca configurable**: `BrandLogo.tsx`, textos y assets están fijos a
  «Catire Bello».
- **Guarda en `reset_datos_prueba.sql`**: que aborte si detecta dinero real.
  El script existe y está mantenido; lo que le falta es el freno.
- **Panel de licencias**, separado y de Jercol.
- **Estados Unidos en la lista de países**, y una API pública de resultados.

---

## 6 · Herramientas

- **`herramientas/quien_usa.py`.** Enumeraría dónde aparece un identificador en
  `supabase/migrations/`, `tests/`, `app/` y `lib/` antes de cerrar o cambiar
  algo. Lo que falló tres veces el 01/10 fue exactamente eso, con un grep mal
  escrito.
- **La lección que se confirmó otra vez entre el 1 y el 5:** lo que atrapa
  defectos son los controles que **se ejecutan** —el arnés, los censos, el
  chequeo de tipos, `tests/log.mjs`, levantar un Postgres y correr la migración—.
  Las reglas escritas no atraparon ninguno. Preferir siempre un control
  ejecutable a una regla escrita.
