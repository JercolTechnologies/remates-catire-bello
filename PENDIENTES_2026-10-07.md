# Pendientes — al 7 de octubre de 2026

Sustituye a `PENDIENTES_2026-10-05.md`, que queda como histórico. Lo cerrado no se
detalla aquí: está en `ADR.md` (38 decisiones) y en el arnés.

**Estado del proyecto:** 69/69 en `tests/pruebas_dinero.sql`, 4/4 en
`tests/concurrencia.sql`, 30 en `tests/fechas.mjs`, 33 en `tests/log.mjs`,
31 en `tests/aviso_puja.mjs`. 41 migraciones, 38 ADRs.

---

## Cerrado el 7 de octubre

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

---

## 1 · Lo que yo haría primero

### 1.1 · `guardar_remate_completo` — lo que queda de la pantalla de editar
El guardado de un remate siguen siendo **16 o 17 escrituras sueltas** para una carrera
de 12 caballos: `races` (1) + `editar_remate` (1) + borrado de caballos (1) + **un
UPDATE o INSERT por caballo** (12) + las escaleras (ya atómicas desde el ADR-037).

Dos cosas dependen de esto, y la segunda es la que pidió Jota el 07/10:

- un fallo a mitad del bucle de caballos deja la carrera medio aplicada;
- **los cambios de un caballo no dejan NINGÚN rastro.** Nombre, jinete, precio de
  salida, retirado, altas y bajas son `UPDATE` directos: no hay trigger ni línea que
  escriba `admin_actions` por `horses`. Cambiar el precio de salida de un caballo es
  invisible, y eso roza el dinero porque es lo que se lleva la casa si nadie puja por él.

El día que exista, `races`, `horses` y `support_settings` bajan a solo lectura y se
aprietan P36 y P48, como ya se hizo con `remate_price_rules`.

*Aceptación:* forzar un fallo en el caballo 7 de 12 y comprobar que no cambió ninguno;
y que cambiar el nombre de un caballo deja un asiento que lo dice.

### 1.2 · No se pueden intercambiar los números de dos caballos
Medido el 07/10: `horses_race_id_numero_key` **no es diferible**, así que cambiar el
caballo 3 a 5 cuando ya existe un 5 rebota con `23505` en el primer UPDATE. El admin
recibe un `duplicate key` en crudo. Una transacción sola no lo arregla: hace falta
hacerlo en dos pasos (a números temporales y luego a los definitivos) o declarar la
restricción `deferrable initially deferred`.

### 1.3 · Clave de idempotencia al crear un remate
Un doble clic sigue creando dos remates. La transacción arregló el fallo **a mitad**,
no el doble clic: dos clics son dos llamadas completas y correctas. Las dos guardas del
formulario son la única defensa y son del navegador.

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

- **Navbar arriba.** Decisión de forma pendiente de Jota.
- **Nombre de usuario visible en todas las secciones, y debajo el saldo.**
- **La ficha del remate vive en un `max-w-md` (448 px) también en escritorio**, así que
  la tabla de 5 columnas se aprieta. Anterior al 07/10, pero se nota.
- **Ver incremento y pozo por caballo** desde la pantalla de admin.
- **`/contactanos`**: la información está, los enlaces no son activos.
- **`©2026` clavado** en el pie.
- **El logo «parece muy IA»** — criterio de Jota.

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

### 5.3 · `fundar_super_admin` para quitar el único paso manual del alta
Dos candados: que solo funcione si no existe ningún super admin, y que el correo
coincida con uno puesto en `ajustes_instalacion` durante la instalación. Sin el segundo,
cualquiera que se registre antes que el dueño se queda con la casa.

### 5.4 · Resto del bloque
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
