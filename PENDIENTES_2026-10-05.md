# Pendientes — al 5 de octubre de 2026

Sustituye a `PENDIENTES_2026-10-01.md`, que se queda como histórico. Lo cerrado
no se detalla aquí: está en `ADR.md` (28 decisiones) y en el arnés.

**Estado del proyecto:** 60/60 en `tests/pruebas_dinero.sql`, 4/4 en
`tests/concurrencia.sql`, 31 en `tests/fechas.mjs`, 32 en `tests/log.mjs`.
32 migraciones aplicadas en producción.

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

---

## 1 · Lo que yo haría primero

### 1.1 · `crear_remate_completo` transaccional — SIGUE ABIERTO desde el 01/10
Crear un remate son **cuatro escrituras separadas** (`races`, `remates`,
`horses`, `remate_price_rules`), sin transacción ni RPC.

El camino que falla hoy: `horses` tiene `UNIQUE (race_id, numero)` y el
formulario **no valida números repetidos**. Dos caballos con el número 3 → la
carrera y el remate se crean, el insert de caballos rebota con 23505, y queda un
**remate `abierto` visible al público con cero caballos**.

Dos arreglos, y el primero son minutos: validar repetidos en el formulario, y
después el RPC transaccional.

*Aceptación:* forzar el fallo en el paso de reglas y comprobar que no queda
ninguna carrera ni remate.

### 1.2 · `/reglas` no explica la regla del 50%
Comprobado el 05/10: esa página no la menciona. La base ya la aplica y el
jugador se la encuentra **al intentar retirar**, que es el peor momento para
enterarse. Jota: *«solo hay que explicarlo bien en las reglas y en los manuales
del licenciatario»*.

Es texto, no código, y es lo que separa una regla de una reclamación.

### 1.3 · Aviso al ganador cuando se liquida un remate
No existe. Pedido el 02/10: tiene que llegarle **tanto si está en línea como si
inicia sesión después**. El canal de realtime ya está; lo que falta es el aviso
persistente para el que no estaba mirando.

### 1.4 · Remates nuevos no aparecen solos en la lista del cliente
Causa localizada: `avisar_remate` es `after update on remates`, y **un alta es un
INSERT**. Además nadie puede estar suscrito al canal de un remate que todavía no
existe. Necesita un canal de lista (`remates:lista`) y su trigger. Es migración.

---

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
