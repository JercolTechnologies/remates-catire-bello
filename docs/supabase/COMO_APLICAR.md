# Cómo se aplican las migraciones

**Las migraciones no se corren una por una.** No abres el archivo y lo pegas en
el editor SQL. El CLI las aplica en orden y **lleva la cuenta** de cuáles ya
corrieron, en una tabla del propio proyecto: `supabase_migrations.schema_migrations`.

| Comando | Dónde | Qué hace |
|---|---|---|
| `pnpm db:reset` | **local** | Borra la base local y aplica **todas** las migraciones desde cero, en orden |
| `pnpm db:push:produccion` | **producción** | Compara la carpeta contra la tabla de control y aplica **solo las que faltan** |

---

> ## 🛑 ANTES DE TU PRIMER `db push` CONTRA PRODUCCIÓN
>
> Producción ya tiene el esquema, pero su tabla de seguimiento está vacía. Si
> corres `db push` sin más, el CLI intenta crear el esquema completo otra vez y
> revienta. **Pasó el 23/09/2026**, exactamente así:
>
> ```
> Applying migration 00000000000000_baseline.sql...
> ERROR: type "deposit_status" already exists (SQLSTATE 42710)
> ```
>
> No es grave — cada migración corre dentro de una transacción, así que esa se
> deshace entera y no queda nada a medias. Pero se evita con dos líneas:
>
> ```powershell
> npx supabase migration repair --status applied 00000000000000
> npx supabase migration repair --status applied 00000000000001
> ```
>
> **Esto se hace UNA sola vez en la vida del proyecto.** Después, `db push`
> aplica solo lo que de verdad falta. El detalle está más abajo, en "La trampa".
>
> Para comprobar en qué estado está producción antes y después:
> pega `docs/supabase/verificar_produccion.sql` completo en el SQL Editor de
> Supabase. Todo en `false` = solo el baseline. Todo en `true` = las seis
> migraciones aplicadas.

---

## Correr las pruebas

Son **dos archivos**, y el orden importa. Desde la raíz del repo, en PowerShell, con Docker levantado:

```powershell
pnpm db:reset
$db = docker ps --filter "name=supabase_db" --format "{{.Names}}"
Get-Content tests/pruebas_dinero.sql | docker exec -i $db psql -U postgres -d postgres
Get-Content tests/concurrencia.sql  | docker exec -i $db psql -U postgres -d postgres
```

La segunda línea averigua cómo se llama el contenedor de la base que levantó Supabase — el nombre lleva un hash y cambia por proyecto, por eso no se puede escribir a mano. Las dos siguientes le meten cada archivo de pruebas por la entrada estándar.

Si `$db` sale vacío, el contenedor no está arriba: `pnpm db:start` primero.

### `tests/pruebas_dinero.sql` — el arnés

75 pruebas de reglas de dinero, permisos y contabilidad. Corre con **una sola conexión**. Al empezar baja los mínimos de `ajustes_instalacion` a **1/1** y `pct_apostado_para_retirar` a **0**, porque sus escenarios están escritos sobre un incremento de 10 y un par de pruebas usan números aún más bajos a propósito; el arnés no mide mínimos, los miden P54 y P55, que se los ponen ellas mismas. Al terminar los devuelve a 50/100/50, los de producción. Si cortas el arnés a medias, revisa esa tabla antes de abrir la aplicación contra la base local. Al terminar imprime la tabla de resultados y **limpia los datos que creó**, para que la base quede vacía si después vas a abrir la aplicación contra ella.

### `tests/concurrencia.sql` — las carreras

4 pruebas de condiciones de carrera: el `for share` de `hacer_puja`, el candado de caja de `liquidar_remate` y el `unique` de `race_results`. Abre una **segunda conexión** con `dblink` para que dos sesiones se crucen de verdad.

> **Necesita que el arnés haya corrido antes, sobre esta misma base.**
>
> Reutiliza su andamiaje — `_p.usuario`, `_p.escenario`, `_p.caballo`, `_p.actuar_como` — en vez de duplicarlo, que sería crear una segunda implementación del mismo escenario. El arnés deja esas funciones en la base al terminar; solo limpia los datos.
>
> Si lo corres solo, la prueba 0 sale en rojo diciendo que falta `_p.escenario`, y las otras tres se saltan en vez de reventar con un error opaco.

La prueba 0 comprueba además que la **segunda conexión** se pudo abrir, y en el detalle dice con qué cadena. Si ahí sale `NINGUNA CADENA FUNCIONÓ`, el detalle lleva el error exacto de cada intento. Por qué no sirve `127.0.0.1` y sí el nombre de red del contenedor está explicado en el ADR-019 y dentro del propio archivo; para diagnosticar hay `supabase/snippets/diagnostico_dblink.sql`.

> **`supabase start` y `supabase db start` no son lo mismo.**
>
> - `npx supabase start` levanta **todo el stack local** (Postgres, API, Studio,
>   Auth, Storage) y por eso imprime el banner con la API URL, los puertos y las
>   llaves `anon` / `service_role`.
> - `npx supabase db start` levanta **solo el contenedor de Postgres**. No
>   imprime banner porque no hay API ni llaves que anunciar. Si la base ya
>   estaba arriba responde `Postgres database is already running.` y no hace
>   nada más.
>
> Para correr el arnés basta con la base, así que `db start` sirve. Si quieres
> el banner o abrir Studio, es `start`.

**No se usa `psql` suelto** (no está instalado en Windows) ni `npx supabase db query` (no devuelve la tabla de resultados del arnés). El `psql` que corre es el que vive dentro del contenedor.

**Marcador esperado al 11/10/2026: 75 en verde, 0 en rojo, de 75** en el arnés, y **4 de 4** en concurrencia. Cualquier otro número significa que algo cambió — no lo des por bueno sin leer el detalle de la fila en rojo, que dice exactamente qué midió y con qué valores.

> **Y léelo ENTERO, no el principio.** El 07/10 P47 salió en rojo y se dio por el falso
> conocido de `pgcrypto`. No lo era: el detalle decía `sin declarar: 1` y nombraba una
> RPC nueva que no se había añadido al censo. El hallazgo real estaba detrás del ruido
> que sale siempre.

> **El arnés NUNCA se corre contra producción.** Su primera función es `_p.limpiar()`,
> que hace `delete` sobre wallets, bids, remates, profiles, `auth.users` y —desde P69—
> `admin_actions`. No tiene ninguna guarda que lo impida: solo un comentario en la
> línea 4 del archivo.

---

## Antes de empujar: el ensayo

```powershell
npx -y supabase@2.118.0 db push --dry-run
```

Dice **exactamente** qué migraciones aplicaría, sin aplicar ninguna:

```
Would push these migrations:
 • 20261007170000_registro_honesto.sql
```

Es el paso que faltaba entre «arnés en verde» y «push». Si ahí aparece algo que no
esperabas —una migración vieja que nunca llegó— te enteras antes y no después.

> **Si la migración QUITA permisos que el frontend desplegado todavía usa, el orden
> importa: primero la base, después el código.** Con la base aplicada y el frontend
> viejo aún en Vercel se rompe solo lo que use ese permiso, de forma ruidosa y sin
> escribir nada. Al revés, el frontend nuevo llamaría a RPC que todavía no existen y
> se rompería más. Pasó el 07/10 al cerrar `remate_price_rules`.

---

## Comprobar qué migraciones están aplicadas en producción

**Hazlo después de cada `db push`, antes de tocar el frontend.** El 01/10/2026
`db push` no llegó a aplicar `20261001130000_motivo_de_rechazo.sql` y el
despliegue de Vercel sí salió: la aplicación quedó pidiéndole a la base
columnas que no existían, y el primer aviso fue un `column
deposit_requests.motivo_etiqueta does not exist` en la cara del cliente.

La causa de fondo no fue el push: fue que **no había manera de comprobar que el
primer paso hubiera salido bien** antes de dar el segundo. Esta consulta es esa
manera. Se pega entera en el SQL Editor del panel, contra producción:

```sql
select version
from supabase_migrations.schema_migrations
order by version desc
limit 10;
```

La de arriba del todo tiene que ser la última que escribiste en
`supabase/migrations/`. Si no está, **el push no llegó**, y da igual lo que diga
el frontend: no despliegues encima.

Si quieres comprobar algo más fino que el nombre del archivo — que una función
concreta exista con su firma nueva, por ejemplo — eso es lo que mide el arnés,
y cada prueba que depende de una migración empieza comprobando que la función
existe. Una prueba que aprueba porque la función no existe es el peor resultado
posible; está explicado en P39.

---

### Las pruebas que no son de SQL

No necesitan Docker ni base: transpilan el archivo real y ejercitan sus funciones.

```powershell
pnpm test:fechas   # app/components/SelectorFechaHora.tsx  (31 comprobaciones)
pnpm test:log      # app/admin/log/page.tsx                (32 comprobaciones)
```

---

## ⚠️ La trampa: producción ya tiene el baseline, pero no lo sabe

El baseline **salió de producción**. Producción ya está en ese estado. Pero la
tabla `supabase_migrations.schema_migrations` está vacía, porque nunca se usaron
migraciones en este proyecto.

**Si corres `db push` tal cual, el CLI va a intentar aplicar el baseline sobre
producción**, que ya tiene todos esos objetos. Resultado: errores de "ya existe",
o peor, según el orden en que reviente.

**La solución** es marcar las dos primeras como ya aplicadas, sin ejecutarlas:

```powershell
npx supabase migration repair --status applied 00000000000000
npx supabase migration repair --status applied 00000000000001
```

`migration repair` **solo escribe en la tabla de control. No ejecuta ni revierte
SQL.** Es exactamente para este caso: adoptar una base que ya existía.

**Comprobado el 23/09/2026:** las seis migraciones del bloque 1 son
idempotentes. Se aplicaron dos veces seguidas sobre una base con solo el
baseline y la segunda pasada corrió limpia, dejando el arnés en 12/15. Así que
si el `repair` se hace de más o de menos, volver a aplicar no rompe nada.

Después de eso, `db push` aplica únicamente lo que de verdad falta.

---

## El orden completo, la primera vez

> ### Siempre `npx supabase`, nunca `supabase` a secas
>
> **Corregido el 25/09/2026.** Este bloque decía que el CLI estaba instalado
> como dependencia del proyecto. **Es falso:** `supabase` no está en
> `package.json` ni en `pnpm-lock.yaml`. Nunca lo estuvo.
>
> Lo que pasa de verdad: `npx` no lo encuentra en `node_modules`, así que lo
> **descarga del registro**. Por eso a veces aparece
> `Need to install the following packages: supabase@2.x.x`. Cuando no aparece
> es porque quedó en la caché de npx, no porque esté en el proyecto.
>
> **Esto importa:** sin versión fijada, cada máquina —y cada licenciatario—
> corre el CLI que sea `latest` ese día. Un cambio de versión mayor puede
> cambiar cómo se aplican las migraciones.
>
> **Se decidió NO meterlo como devDependency**, aunque eso arreglaría el pin:
> el paquete `supabase` descarga un binario de ~40 MB al instalarse, y Vercel
> instala las devDependencies en cada build. Sería pagar ese peso en cada
> deploy por una herramienta que solo se usa desde el escritorio y que el
> build no toca jamás.
>
> **La regla entonces es fijar la versión en el comando**, no en el
> `package.json`. La versión con la que se aplicó todo el bloque 1 y 2 es la
> **2.118.0**. Si necesitas reproducir exactamente:
>
> ```powershell
> npx supabase@2.118.0 db reset
> ```
>
> **Resuelto el 25/09/2026 con scripts en `package.json`.** La versión queda
> fijada donde se usa, sin meter el CLI como dependencia:
>
> ```json
> "db:start": "npx -y supabase@2.118.0 start",
> "db:stop": "npx -y supabase@2.118.0 stop",
> "db:reset": "npx -y supabase@2.118.0 db reset",
> "db:push:produccion": "npx -y supabase@2.118.0 db push"
> ```
>
> **Úsalos siempre**, en vez de escribir `npx supabase ...` a mano:
>
> | comando | qué hace |
> |---|---|
> | `pnpm db:start` | Levanta el stack local completo, con banner de llaves y puertos |
> | `pnpm db:stop` | Lo apaga |
> | `pnpm db:reset` | Borra la base local y reaplica todas las migraciones |
> | `pnpm db:push:produccion` | **Toca producción.** Aplica las migraciones que falten |
>
> Tres detalles que no son capricho:
>
> - **El `-y`** salta el prompt `Ok to proceed?` de npx. Sin él, el script se
>   queda colgado esperando una respuesta que nadie le va a dar.
> - **El nombre largo de `db:push:produccion`** es a propósito. Pinear la
>   versión de `db push` es lo más importante de todo, pero convertir el
>   comando que toca producción en algo de ocho letras baja la fricción justo
>   donde la fricción es sana. No se escribe por accidente ni se confunde con
>   `db:reset`.
> - **Pinear la versión no te protege de una migración rota.** Si el SQL está
>   mal, falla con la 2.118.0 igual que con cualquier otra. Lo que evita es que
>   *el CLI* cambie de comportamiento entre versiones: que el `db push` de
>   dentro de seis meses no haga algo distinto al de hoy con los mismos
>   archivos.
>
> El arnés no tiene script porque la línea que busca el contenedor de Docker es
> PowerShell (`$db = docker ps --filter ...`) y los scripts de npm corren por
> `cmd`. Se queda como está, más arriba en este documento.

```powershell
# 1. Regenerar el baseline SOLO con public (ver COMO_HACER_EL_BASELINE.md)
npx supabase db dump -f supabase/migrations/00000000000000_baseline.sql --schema public

# 2. Crear supabase/config.toml (una sola vez, si no existe)
npx supabase init

# 3. Levantar la pila local. LA PRIMERA VEZ TARDA VARIOS MINUTOS:
#    descarga las imagenes Docker de Postgres, GoTrue, PostgREST, Studio...
#    Al terminar imprime las URLs y las claves locales.
pnpm db:start

# 4. Probar TODO en local: borra y reaplica TODAS las migraciones
pnpm db:reset

# 5. Correr las pruebas contra la base local (ver "Correr las pruebas" arriba).
#    Los dos archivos, y en este orden: concurrencia.sql reutiliza el
#    andamiaje que deja el arnes.
$db = docker ps --filter "name=supabase_db" --format "{{.Names}}"
Get-Content tests/pruebas_dinero.sql | docker exec -i $db psql -U postgres -d postgres
Get-Content tests/concurrencia.sql  | docker exec -i $db psql -U postgres -d postgres

# ---- hasta aqui TODO es local y no toca nada de produccion ----

# 6. RESPALDO de produccion desde el panel de Supabase  <-- no saltarse

# 7. Adoptar produccion: marcar las dos primeras como ya aplicadas
npx supabase migration repair --status applied 00000000000000
npx supabase migration repair --status applied 00000000000001

# 8. Aplicar lo que de verdad falta (hoy: solo el fix del enum)
pnpm db:push:produccion
```

De aquí en adelante el ciclo es siempre el mismo: escribir la migración,
`db reset` + arnés en local, respaldo, `db push`.

---

## Por qué esto importa para el licenciamiento

Este es el mecanismo con el que vas a mantener N bases de clientes. Cada
instalación nueva arranca con `db push` sobre un proyecto vacío y queda idéntica
a las demás. Y cuando corrijas algo, la misma migración viaja a todos.

Sin esto, cada cliente sería una base distinta que nadie puede reproducir — que
es exactamente el estado del que venimos saliendo.
