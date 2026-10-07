# Remates Catire Bello — instrucciones para el agente

App de remates hípicos en vivo, **en producción**, que se va a **alquilar a terceros**.
Modelo: un solo repo, una base de datos por cliente, y el cliente es la casa (cobra
los depósitos, paga los premios, se queda la comisión; Jercol cobra la licencia).

> **Esto no es un proyecto de juguete: mueve dinero real de gente real, y lo va a
> operar alguien que no eres tú ni Jota.** Un error aquí no es un bug, es un saldo
> que no cuadra en la cuenta de un licenciatario. Cuando dudes entre rápido y
> correcto, correcto.

Stack: Next.js 16 (App Router) + Supabase (Postgres) + Vercel. Windows 11, VS Code, PowerShell.

---

## 1. Reglas inquebrantables

Estas no se negocian ni se interpretan. Si una te estorba, dilo y para; no la rodees.

1. **No toques git. Nunca.** Ni `add`, ni `commit`, ni `push`, ni `status`. Jota hace
   todo git él mismo. Tú le entregas el **mensaje de commit** y ya.
2. **No ejecutes comandos locales.** Ni `pnpm`, ni `supabase`, ni `docker`, ni el arnés.
   Los corre Jota en su máquina y te pega la salida. Tú escribes, verificas y explicas.
3. **Antes de ejecutar algo, consulta la documentación.** Cuesta segundos y evita
   repetir errores. Es regla, no sugerencia.
4. **Lo que es base de datos vive en la base; lo que es frontend, en el frontend.**
   Nunca las dos cosas. Es el ADR-015 y nació de un desastre real: la pantalla
   calculaba un mínimo y la base cobraba otro.
5. **Nunca imprimas credenciales, claves ni tokens en el chat.** Ni para mostrar que
   los tienes. Escríbelos a archivo si hace falta, sin mostrarlos.
6. **Comentarios y mensajes en castellano**, y explicando **por qué**, no qué.
   Un comentario que repite el código sobra; uno que cuenta qué pasó cuando no estaba,
   vale su peso.
7. **No asumas lo que no sabes. Pregunta.** Sobre todo mientras iteráis. Y
   **comprueba las fechas con un comando**, nunca de memoria: trabajas en UTC y
   Jota en Colombia (UTC−5), con la app en hora de Caracas (UTC−4).
8. **Si te equivocas, dilo claro y pronto.** Y si tienes argumentos, defiende tu
   posición: Jota no quiere que le den la razón por cortesía.

---

## 2. Qué leer, y cuándo

No leas todo. Lee lo que toca:

| Si vas a… | Lee primero |
|---|---|
| **cualquier cosa** | `ADR.md` — el índice de decisiones. Al menos los títulos. |
| tocar dinero, saldos, pujas o cierres | `ADR.md` completo + `tests/pruebas_dinero.sql` (el arnés dice la verdad) |
| escribir una migración | `docs/supabase/COMO_APLICAR.md` + las 3 migraciones más recientes |
| tocar permisos o RLS | ADR-018, ADR-020 y las pruebas P47/P48 del arnés |
| tocar realtime | ADR-024, ADR-025, ADR-026 + `lib/realtime.ts` |
| tocar contabilidad | ADR-022 + `supabase/migrations/20261005100000_descuadre_inexplicado.sql` |
| dar de alta un licenciatario | `docs/supabase/INSTALACION_LICENCIATARIO.md` |
| saber qué falta | `PENDIENTES_2026-10-05.md` (el 10-01 es histórico) y `BACKLOG_FASE1_FIXES.md` |

`ADR.md` son 34 decisiones con su contexto, su alternativa descartada y qué las
revertiría. **Casi siempre la pregunta que te estás haciendo ya está contestada ahí.**
Si tomas una decisión de arquitectura nueva, añade su ADR al final.

---

## 3. Mapa

```
app/
  admin/              panel del licenciatario
    layout.tsx        monta CajaEnVivo: UNA suscripcion realtime para todo el panel
    CajaEnVivo.tsx    aviso de caja + contadores en vivo (ADR-026)
    page.tsx          panel, contabilidad/, crear-remate/, log/, recargas/,
                      remates/[id]/, retiros/, super/
  dashboard/          cliente: saldo, recargar/, retirar/
  remates/[id]/       pujar
  reglas/             las reglas que acepta el jugador (incluye la del 50%)
  components/         BrandLogo, ClientBottomNav, SelectorFechaHora
lib/
  escalera.ts         escalera de precios: PRESENTACION. Si discrepa de la base, manda la base
  realtime.ts         useSenal: suscripcion supervisada (ADR-025)
  motivos.ts          motivos de rechazo
  supabaseClient.ts
supabase/
  migrations/         30 archivos. El 00000000000000 es el baseline sacado de produccion
  snippets/           consultas de diagnostico para el SQL Editor del panel
tests/
  pruebas_dinero.sql  66 pruebas. UNA conexion. Es el juez.
  concurrencia.sql    4 pruebas de carreras. Necesita que el arnes haya corrido antes
  fechas.mjs          31 comprobaciones de SelectorFechaHora  (pnpm test:fechas)
  log.mjs             32 comprobaciones de /admin/log          (pnpm test:log)
  aviso_puja.mjs      31 comprobaciones del aviso de puja      (pnpm test:aviso)
docs/supabase/
  COMO_APLICAR.md     el ciclo de migraciones. Leelo entero antes de la primera
  INSTALACION_LICENCIATARIO.md  alta de una instalacion nueva. OJO: ahi NO va
                      `migration repair` -- eso era para adoptar la base vieja
  reset_datos_prueba.sql   vaciar datos dejando el esquema
```

**La base manda.** Las reglas de dinero viven en funciones `security definer`:
`hacer_puja`, `cerrar_remate`, `liquidar_remate`, `solicitar_retiro`, `procesar_retiro`,
`rechazar_recarga`, `casa_resumen`, `requisito_apuesta`. El frontend **pregunta**, no calcula.

---

## 4. El ciclo, en orden, sin saltarse pasos

1. Escribir la migración (nueva, nunca editar una ya aplicada: no se vuelve a ejecutar).
   **El prefijo es una clave de orden, no una fecha: solo tiene que ser creciente.**
   Numérala con la hora de **Caracas** (`TZ=America/Caracas date`), no con la del
   entorno: tu reloj puede ir en UTC y adelantar un día respecto a Jota, que está
   en Colombia. Y escribe la fecha real, en hora de Caracas, en la cabecera.
2. Jota corre `pnpm db:reset` + el arnés en local. **Marcador esperado: 66/66 y 4/4.**
3. Jota hace respaldo y `pnpm db:push:produccion`.
4. **Comprobar que llegó**, antes de desplegar nada:
   `select version from supabase_migrations.schema_migrations order by version desc limit 5;`
   Si tu migración no está arriba del todo, **el push no llegó**. No despliegues encima.
   Esto no es paranoia: pasó el 01/10 y el cliente vio el error en su pantalla.
5. Commit y deploy a Vercel.

Cambio solo de frontend: pasos 1–4 no aplican, pero el typecheck sí.

---

## 5. Cómo se trabaja aquí

- **Una prueba por defecto corregido.** Si arreglas algo y no hay forma de que el arnés
  lo cace, no está arreglado: está escondido.
- **Una prueba que aprueba porque la función no existe es el peor resultado posible.**
  Toda prueba que dependa de una migración empieza comprobando que la función existe.
  Está explicado en P39.
- **Un entorno de prueba más permisivo que el real no prueba nada** (ADR-020). Y uno más
  pobre tampoco: si el camino que te importa no se ejecuta, "cero filas" no es "funciona".
- **Verifica antes de afirmar.** Lee el archivo, ejecuta la consulta, corre el script.
  Las hipótesis descartan un sospechoso si aciertas y ninguno si fallas; una medida
  descarta uno siempre (ADR-024).
- **Un instrumento que miente es peor que no tenerlo.** Una alarma que salta cuando no
  pasa nada (ADR-022), un canal que se cayó y parece vivo (ADR-025), un botón sin acuse
  de recibo (ADR-023). Si lo construyes, tiene que decir la verdad sobre su propio estado.
- Antes de cerrar una puerta, busca quién la usa (ADR-018) **y comprueba quién
  queda encerrado** (ADR-033).
- **`now()` es la hora de la TRANSACCIÓN, no del reloj.** Dentro de un `do $$`
  todo comparte instante: dos filas creadas «una después de otra» tienen el mismo
  `created_at`, y `order by created_at` o `>` no distinguen. Ha mordido tres
  veces (P56, P61, P66). En una prueba que dependa del orden temporal, mueve las
  fechas explícitamente; `pg_sleep` no sirve porque la hora no avanza.

## 6. Lo que NO se hace

- No borrar ni editar migraciones ya aplicadas en producción.
- No meter lógica de dinero en TypeScript.
- No `create extension` en migraciones (ADR-020).
- No tocar `estado` de un remate con un UPDATE directo: va por RPC.
- No inventar datos de producción. Si hace falta mirar, se escribe una consulta de
  solo lectura en `supabase/snippets/` y la corre Jota — **SQL puro, sin metaórdenes de
  psql** (`\echo`, `\set`) porque el SQL Editor del panel no las entiende.
