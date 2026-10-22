# Trabajar con Supabase en este proyecto

| Documento | Para qué |
|---|---|
| `COMO_APLICAR.md` | **Empieza aquí.** Cómo se aplican las migraciones, local y producción, y la trampa del `migration repair` |
| `COMO_HACER_EL_BASELINE.md` | Cómo se generó el volcado inicial y qué verificar si hay que rehacerlo |
| `INSTALACION_LICENCIATARIO.md` | Dar de alta una instalación nueva, incluido el único paso manual: fundar su primer super admin |
| `reset_instalacion_nueva.sql` | **Devolver al estado de instalación nueva un proyecto que ya se usó** (usuarios, dinero, marca y correo del fundador), sin reaplicar migraciones |

> `reset_instalacion_nueva.sql` no es una migración y por eso no vive en
> `supabase/migrations/`: ahí el CLI lo aplicaría en cada `db push`. Se corre a
> mano, una vez, en el SQL Editor del proyecto que se va a reutilizar —nunca en
> producción— y **conserva `supabase_migrations.schema_migrations`**, así que
> después del reset `db push` no reaplica nada ni hay que rehacer el baseline.

## Reglas de `supabase/migrations/`

**Esa carpeta es la única fuente de verdad del esquema, y solo admite archivos
`<timestamp>_nombre.sql`.** Cualquier otra cosa —un README, una nota— el CLI la
salta con un aviso en cada corrida. Por eso la documentación vive aquí.

1. Todo cambio de base de datos entra como archivo nuevo, numerado. Nunca se
   edita una migración ya aplicada.
2. Nada se aplica a mano desde el editor SQL de Supabase sin que exista antes el
   archivo. Ese fue exactamente el problema que llevó a tener tres versiones
   distintas de `liquidar_remate` circulando.
3. El orden lo da el nombre del archivo.

## Comandos del día a día

```powershell
npx supabase status   # ¿está corriendo la pila local?
npx supabase start    # levantarla
npx supabase stop     # apagarla y liberar RAM
npx supabase db reset # borrar la base local y reaplicar TODAS las migraciones
```

> **Corregido el 05/10/2026.** Aquí decía que el CLI estaba instalado como
> dependencia del proyecto. **Es falso**, y `COMO_APLICAR.md` ya lo había
> corregido el 25/09: `supabase` no está en `package.json` ni en el lock.
> `npx` lo descarga del registro, así que **sin versión fijada cada máquina
> corre el CLI que sea `latest` ese día**.
>
> Usa los scripts de `package.json`, que la fijan en 2.118.0:
> `pnpm db:start`, `pnpm db:stop`, `pnpm db:reset`, `pnpm db:push:produccion`.
>
> Dos documentos que se contradicen son peores que uno solo: el que lee acaba
> creyendo al equivocado.
