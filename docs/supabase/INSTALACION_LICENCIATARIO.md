# Dar de alta una instalación nueva

Una instalación nueva es **un proyecto de Supabase nuevo + un despliegue de
Vercel nuevo, con el mismo repositorio**. Nada de código se bifurca: lo único
que cambia por cliente son las variables de entorno y los ajustes de la tabla
`ajustes_instalacion`.

> **Aviso de honestidad.** Este procedimiento está escrito a partir del
> repositorio, no de haberlo ejecutado contra un cliente real. La primera alta
> de verdad es también su prueba: si algún paso no sale como dice aquí, lo que
> hay que corregir es este documento, antes de que haya un segundo cliente que
> lo herede mal.

---

## 1. El proyecto de Supabase

Crear el proyecto en el panel de Supabase. Anotar la URL y la clave `anon`.

**La clave `service_role` no se usa en ninguna parte de esta aplicación y no
debe salir del panel.** Si en algún momento un procedimiento te pide
configurarla en algún sitio, para y pregunta: es acceso total por encima de
toda la RLS (ver ADR-027).

---

## 2. Aplicar el esquema

```powershell
npx supabase@2.118.0 link --project-ref <ref-del-proyecto-nuevo>
pnpm db:push:produccion
```

> ### ⛔ Aquí NO se hace `migration repair`
>
> `COMO_APLICAR.md` explica que hubo que marcar las dos primeras migraciones
> como aplicadas **sin ejecutarlas**. Eso fue para **adoptar** la base de
> producción de Catire Bello, que ya tenía el esquema de antes de que
> existieran las migraciones.
>
> **Un proyecto nuevo está vacío y necesita que el baseline se ejecute de
> verdad.** Si corres `migration repair` aquí, el CLI va a creer que el esquema
> está puesto cuando no hay ni una tabla, y la aplicación va a fallar en el
> primer clic sin que nada diga por qué.

Comprobar que llegaron **todas**, en el SQL Editor del proyecto nuevo:

```sql
select count(*) as cuantas,
       min(version) as la_primera,
       max(version) as la_ultima
from supabase_migrations.schema_migrations;
```

`la_primera` tiene que ser `00000000000000`. `cuantas` tiene que coincidir con
el número de archivos de `supabase/migrations/`.

---

## 3. El despliegue de Vercel

Un proyecto de Vercel nuevo apuntando al mismo repositorio.

> ### ⛔ NO uses la integración «Connect Supabase» de Vercel
>
> **Descubierto el 10/10/2026, en la primera instalación real.** Conectar
> Supabase desde Vercel es un botón y parece lo correcto. Lo que hace es
> inyectar **catorce variables** en el proyecto, y tres de ellas son las llaves
> del reino:
>
> | Variable | Qué entrega |
> |---|---|
> | `SUPABASE_SERVICE_ROLE_KEY` · `SUPABASE_SECRET_KEY` | acceso total **por encima de toda la RLS** (ADR-027) |
> | `SUPABASE_JWT_SECRET` | permite **firmar un token de cualquier usuario**, incluido un super admin |
> | `POSTGRES_PASSWORD` y los cuatro `POSTGRES_URL*` | la **conexión directa** a la base, con contraseña |
>
> Ninguna de las catorce la lee esta aplicación. No rompen nada, y ese es
> justo el problema: **no se nota**. Quedan ahí ampliando el daño de
> cualquier fallo futuro — una ruta nueva mal escrita, un `console.log` en el
> servidor, una dependencia comprometida, o simplemente darle acceso al panel
> de Vercel a alguien. Sin ellas, el peor caso es lo que la RLS permita; con
> ellas, el peor caso es la base entera.
>
> **Este documento ya lo decía en el paso 1** —*«Si en algún momento un
> procedimiento te pide configurarla en algún sitio, para y pregunta»*— y la
> regla funcionó: lo que no se había previsto es que quien la pusiera no fuera
> un procedimiento, sino **un botón que no pregunta**.
>
> Las variables se ponen **a mano**, una por una. Si ya conectaste la
> integración, bórralas todas menos las dos públicas y **vuelve a mirar la
> lista al día siguiente**: la documentación de Supabase dice que los proyectos
> conectados se «sincronizan automáticamente» y no aclara si las repone. Si
> vuelven, desconecta la integración.

> ### ⚠️ Corregido el 10/10/2026
>
> Este apartado decía que eran **dos** variables y que se comprobaba con
> `findstr /s /c:"process.env"`. **Las dos cosas eran falsas**, y de la peor
> manera: la comprobación *pasaba* mientras el dato era incorrecto.
>
> `app/api/notify/recarga/route.ts` no lee `process.env.SMTP_USER`. Lee
> `env("SMTP_USER")`, con un ayudante que hace `process.env[name]`. El
> `findstr` encuentra esa línea pero **no revela ni un solo nombre**, así que
> daba una sensación de completitud sin dar la lista.
>
> Consecuencia si no se corrige: el licenciatario instala, todo parece
> funcionar, y el día que un admin aprueba una recarga el correo de aviso
> devuelve `500 Missing SMTP env` sin que nada explique por qué.

**Las dos imprescindibles.** Sin ellas la aplicación no arranca:

```
NEXT_PUBLIC_SUPABASE_URL       = https://<ref>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY  = <la clave anon del proyecto nuevo>
```

**Las del correo de aviso.** Sin ellas todo lo demás funciona, pero
`/api/notify/recarga` devuelve `500` y **nadie se entera por correo** de que
hay una recarga esperando:

```
SMTP_USER        = la cuenta que envía
SMTP_PASS        = su contraseña de aplicación, NO la del correo
NOTIFY_EMAIL_TO  = a quién avisar (si falta, se usa SMTP_USER)
SMTP_HOST        = opcional, por omisión smtp.gmail.com
SMTP_PORT        = opcional, por omisión 465
```

> **El `SMTP_PASS` de Gmail es una «contraseña de aplicación»**, no la del
> correo. Y es del licenciatario, no tuya: su casa manda sus correos.

**Opcionales:**

```
APP_URL          = https://<su-dominio>   (enlaces absolutos en los correos)
NEXT_PUBLIC_SITIO= https://<su-dominio>   (vista previa al compartir el enlace)
```

`VERCEL_PROJECT_PRODUCTION_URL` la pone Vercel sola; no se configura.

**La comprobación que SÍ sirve** —busca los dos patrones, el directo y el del
ayudante:

```powershell
findstr /s /r /c:"process\.env\.[A-Z_]*" /c:"env(\"" app\*.ts* lib\*.ts
```

Al 10/10/2026 la lista completa es: `NEXT_PUBLIC_SUPABASE_URL`,
`NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_SITIO`,
`VERCEL_PROJECT_PRODUCTION_URL`, `SMTP_USER`, `SMTP_PASS`, `NOTIFY_EMAIL_TO`,
`SMTP_HOST`, `SMTP_PORT`, `APP_URL`.

> **Las variables NO van al repositorio.** `.gitignore` incluye `.env*`, así
> que ningún `.env` viaja a GitHub ni a ningún despliegue. El `.env.local` de
> tu máquina apunta a **tu** producción y no tiene nada que ver con la
> instalación del cliente: las suyas se ponen **solo** en su panel de Vercel.

---

## 4. El licenciatario se registra

**En su propia aplicación**, en `/register`, como cualquier jugador. Nada
especial: nombre de usuario, correo y contraseña.

---

## 5. ⭐ Fundar el primer super admin

**Este es el único paso que se hace a mano, y solo ocurre una vez por
instalación.**

En una base recién creada no hay ningún administrador, y `nombrar_admin` exige
un super admin para funcionar. Huevo y gallina a propósito: si el primer super
admin se pudiera crear desde la pantalla, **el primero que se registrara se
quedaría con la casa**. El único portero aceptable para ese nombramiento es
tener las llaves de la base de datos.

En el SQL Editor del proyecto del cliente, cambiando los cuatro valores:

```sql
update public.profiles
set es_admin      = true,
    es_super_admin = true,
    admin_codigo  = 'DUE1',
    admin_nombre  = 'Nombre del dueño'
where id = (select id from auth.users where email = 'correo-del-licenciatario');
```

Y **comprobar que afectó a una fila**:

```sql
select admin_codigo, admin_nombre, es_admin, es_super_admin
from public.profiles
where es_super_admin;
```

Si devuelve cero filas, el correo no coincide: el licenciatario no se registró
todavía, o se registró con otro. No inventes el `id` a mano.

A partir de aquí **él se arregla solo** y tú no vuelves a tocar su base: desde
`/admin/super/admins` nombra a sus cajeros, les pone código y nombre, y les
quita el cargo cuando se vayan.

> **Los cajeros NO llevan la casilla de super admin.** Super admin significa
> «puede repartir y quitar poder», y eso es del dueño. Un admin normal opera la
> caja pero no puede nombrar ni quitar a nadie (lo mide P59).

---

## 6. Los ajustes de la instalación

Los valores de arranque son los de Catire Bello. Revisarlos con el cliente
**antes** de que opere:

```sql
select clave, valor, descripcion from public.ajustes_instalacion order by clave;
```

| clave | arranca en | qué es |
|---|---|---|
| `minimo_incremento` | 50 | lo mínimo que puede subir una puja |
| `minimo_precio_salida` | 100 | precio de salida mínimo de un caballo |
| `pct_apostado_para_retirar` | 50 | % de lo recargado que hay que apostar antes de poder retirar; en `0` la regla no aplica |

Se cambian desde la base (`update public.ajustes_instalacion set valor = '...'
where clave = '...'`) hasta que exista la pantalla de ajustes, que está en
pendientes.

**Si cambias `pct_apostado_para_retirar`, hay que cambiar también el texto de
`/reglas`.** Esa página le promete al jugador un porcentaje concreto, y una
regla que no coincide con lo que dice la pantalla es una reclamación.

---

## 7. Comprobación final, antes de entregar

Con el licenciatario delante:

1. Entra en `/admin` y ve sus dos contadores en cero.
2. Abre `/admin/super/admins`: se ve a sí mismo con su código, y **no** sale el
   aviso ámbar de «administrador sin código».
3. Abre `/admin/contabilidad`: todo en cero y **sin** franja ámbar de descuadre.
4. Abre `/admin/log`: las tres pestañas vacías.
5. Crea un remate de prueba, puja desde otra cuenta, ciérralo y liquídalo.
   Después **borra los datos de prueba** con
   `docs/supabase/reset_datos_prueba.sql` para que arranque en cero de verdad.

> ### Si es una DEMO y no una entrega
>
> Una instalación vacía no enseña nada. Para una demo, en vez del paso 5 corre
> `docs/supabase/demo_seed.sql`: deja tres remates (uno en vivo, uno
> adelantado y uno liquidado), 14 caballos con escaleras, tres jugadores con
> saldo y pujas, **y la contabilidad cuadrada**. El dinero entra por la puerta
> —solicitud de recarga y aprobación del admin—, no con un `update` a las
> carteras, justamente para que `/admin/contabilidad` no salga descuadrada en
> la primera pantalla que abre el que mira.
>
> Ese guion **se niega a correr** si la instalación ya tiene remates o
> recargas aprobadas.

---

## Lo que queda pendiente de automatizar

El paso 5 es el único manual, y con N clientes son N oportunidades de
equivocarse. La forma limpia de quitarlo es una función `fundar_super_admin`
con dos candados: que **solo funcione si no existe ningún super admin todavía**
—se cierra sola para siempre tras el primer uso— y que exija que el correo
coincida con uno que tú dejes puesto en `ajustes_instalacion` durante la
instalación. Sin ese segundo candado, cualquiera que se registre antes que el
dueño se queda con la casa.

Está apuntado para el bloque de licencias.
