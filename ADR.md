# Registro de decisiones de arquitectura

Cada entrada anota una decisión que costó pensar, **por qué** se tomó, y **qué la revertiría**. Ese último campo no es estándar en un ADR y es el que más vale: una decisión sin condición de salida se convierte en dogma, y dentro de un año nadie se acuerda de si seguía teniendo sentido.

Las decisiones no se borran. Si una se cambia, se marca como reemplazada y se escribe una nueva debajo.

**Última actualización:** 27 de septiembre de 2026.

---

## ADR-001 · Un repo, una base de datos por cliente

**Contexto.** La app se va a licenciar a terceros. Las opciones eran multi-tenant (todos los clientes en una base, separados por columna) o una instalación por cliente.

**Decisión.** Código único en un solo repo; **base de datos separada por cliente**.

**Por qué.** En multi-tenant, un error en una política de RLS expone el dinero de un cliente a otro. Con bases separadas, ese error es imposible por construcción. Y el cliente es "la casa" —maneja dinero real de sus usuarios— así que el aislamiento no es una comodidad, es el requisito.

**Consecuencias.** Cada alta de cliente es un aprovisionamiento, no un `INSERT`. Hay que automatizarlo (Fase 2). Una migración se aplica N veces, una por instalación.

**Qué la revertiría.** Que el número de clientes crezca hasta que aprovisionar y migrar a mano sea el cuello de botella. Ese día se automatiza el despliegue, no se junta la base.

---

## ADR-002 · Las migraciones son la fuente de verdad, no producción

**Contexto.** Hasta septiembre de 2026 la base de producción estaba **por delante del repo**: había correcciones aplicadas a mano en Supabase que no existían en `sql/`, y al menos un script del repo que revertía una de ellas. Se encontraron **tres generaciones distintas** de la lógica de liquidación circulando a la vez.

**Decisión.** `supabase/migrations/` es la fuente de verdad. Nada se aplica a producción sin pasar por una migración versionada.

**Por qué.** Cuando la verdad vive en producción, no hay forma de saber qué está corriendo sin mirarlo, y no hay forma de reproducirlo en otra instalación — que es justo lo que exige el ADR-001.

**Consecuencias.** Se volcó el esquema real a un baseline y se adoptó producción con `migration repair`. `app/SUPABASE_CONTEXT.md`, que era la foto a mano, quedó marcado como **legacy**.

**Qué la revertiría.** Nada. Si esto se rompe, se rompe todo lo demás.

---

## ADR-003 · El compromiso se calcula, no se guarda

**Contexto.** El modelo original apartaba el dinero al pujar: `saldo_disponible −monto`, `saldo_bloqueado +monto`. Si te superaban, se te devolvía y se le apartaba al siguiente. Cada puja eran cuatro escrituras de dinero que tenían que salir bien las cuatro.

**Decisión.** El compromiso de un usuario es **la suma de las pujas que lidera ahora mismo**, calculada en el momento en que se pregunta. Durante el remate no se escribe nada en `wallets`.

**Por qué.** Un número guardado hay que mantenerlo sincronizado, y cada sincronización es una oportunidad de que aparezca o desaparezca dinero. Un número calculado no puede desincronizarse de sí mismo. El caso de subir tu propia puja —que en el modelo viejo exigía calcular un "delta" a mano— sale gratis.

**Consecuencias.** `hacer_puja` escribe una fila en `bids` y nada más. `wallets.saldo_bloqueado` vale 0 siempre; **la columna se conserva a propósito y el arnés verifica que sea 0**, en vez de borrarla a ciegas y perder la red. El coste es una consulta por puja, cubierta con dos índices.

**Qué la revertiría.** Que `compromiso_usuario()` se vuelva lenta con volumen real. Ahí se cachearía — pero con una prueba que compare el caché contra el cálculo, no reemplazándolo.

---

## ADR-004 · El dinero se cobra al cerrar, no al liquidar

**Contexto.** Terminar un remate son dos momentos separados por un hueco indefinido: se acaban las pujas, y más tarde se sabe quién ganó la carrera. En el modelo viejo el dinero seguía en `saldo_bloqueado` entre los dos: ya no era gastable, pero seguía contando como patrimonio del usuario y todavía no había entrado al pozo.

**Decisión.** **Cerrar** cobra a cada líder de puja. **Liquidar** solo paga el premio.

**Por qué.** Deja el dinero en un solo sitio en cada momento, sin limbo. Y hace que el estado `cerrado` signifique algo concreto: la plata ya salió.

**Consecuencias.** `cerrar_remate()` delega en `_cerrar_remate_interno(uuid)` porque el cron corre sin `auth.uid()` y **tiene que pasar por el mismo camino que el botón**. Antes no lo hacía: el cron cerraba con un `UPDATE` plano y no cobraba a nadie, lo que escondió un defecto grave durante meses.

**Qué la revertiría.** Nada previsto.

---

## ADR-005 · Candado consultivo por usuario, siempre en el mismo orden

**Contexto.** Sin candado, dos operaciones simultáneas del mismo usuario leen el mismo saldo y las dos pasan. **Verificado con dos conexiones reales**, no es teoría: un usuario con 500 que puja 300 a dos caballos a la vez termina con 600 comprometidos; y una puja de 800 simultánea con un retiro de 1000 pasan las dos.

**Decisión.** `pg_advisory_xact_lock(1, hashtext(user_id))` en las cinco funciones que mueven dinero. **Espacio de usuario (1) siempre antes que espacio de caballo (2)**, y los bucles ordenados por `user_id`.

**Por qué.** El invariante `saldo_disponible >= compromiso_usuario()` solo se sostiene si nadie puede leer y escribir en paralelo sobre el mismo usuario.

**Consecuencias.** El orden fijo no es estética: es lo que evita el interbloqueo. Cualquier función nueva que toque dinero **tiene que respetarlo**, y eso hay que recordarlo al escribirla — el compilador no ayuda aquí.

**Qué la revertiría.** Nada. Si hay contención medible, se afina el alcance del candado, no se quita.

---

## ADR-006 · La guarda va dentro de la función, no solo en la tabla

**Contexto.** `house_ledger` tenía RLS activa con una política `using (is_admin())`. Aun así, cualquier usuario logueado podía leer el patrimonio de la casa llamando a `casa_resumen()` desde la consola del navegador.

**Decisión.** Toda función `security definer` expuesta a `authenticated` comprueba **dentro** quién la llama.

**Por qué.** Una función `definer` lee la tabla **por encima** de la RLS. La política de la tabla no protege el dato que una función devuelve sumado.

**Consecuencias.** Se auditaron las 31 funciones con grant a `authenticated` o `anon` y se encontraron cuatro agujeros más, dos graves: `auto_cerrar_remates()` y `log_admin_action()` estaban abiertas a **`anon`**. Y una lección de fondo: **`CREATE OR REPLACE FUNCTION` no toca los permisos**, así que los grants de la baseline sobrevivieron intactos a todas las migraciones que reescribieron los cuerpos. Revisar el cuerpo no basta — hay que mirar el ACL aparte. La prueba P33 lo comprueba con `has_function_privilege()`.

**Qué la revertiría.** Nada.

---

## ADR-007 · El libro de la casa tiene un asiento que el admin no puede escribir

**Contexto.** La casa aporta al pozo los caballos que nadie puja, pero esa contribución nunca entraba como efectivo: `dinero_casa_disponible()` daba negativo siempre y la guarda de solvencia bloqueaba casi toda liquidación.

**Decisión.** `house_ledger` con cuatro tipos de asiento. Tres los escribe el admin (capital, utilidad, ajuste). El cuarto —`resultado_remate`— **lo escribe el sistema al liquidar y `registrar_movimiento_casa()` lo rechaza a propósito.**

**Por qué.** Esta fue una corrección de Jota, y tenía razón. La propuesta inicial era no registrar la comisión para no contarla dos veces. Estaba mal planteada: el libro no es *otra fuente del mismo número*, es una **fuente independiente que tiene que cuadrar**. Si el admin pudiera escribir ese asiento, las dos fuentes dejarían de ser independientes y el cuadre no significaría nada.

**Consecuencias.** `casa_resumen()` expone `descuadre`, que debe ser 0 siempre. El panel avisa en ámbar si no lo es. Verificado: la prueba P31 detecta un asiento falso.

**Qué la revertiría.** Nada.

---

## ADR-008 · Una sola fuente para los mínimos de puja

**Contexto.** El frontend reimplementaba en TypeScript la escalera de precios que la base ya calculaba dentro de `hacer_puja`. El 23/09 se demostró que las dos implementaciones se habían separado sin que nadie se enterara: **la pantalla mostraba un número y la base cobraba otro.**

**Decisión.** `_incremento_aplicable()` es el único sitio donde se elige la regla. `remate_minimos()` devuelve por caballo todo lo que la pantalla necesita. **El frontend muestra, no calcula.**

**Por qué.** Dos implementaciones de la misma regla siempre acaban separándose. La única pregunta es cuándo te enteras.

**Consecuencias.** El defecto que lo destapó (1.10) era de una línea: `NULL = uuid` devuelve NULL y `ORDER BY DESC` pone los NULL **primero**, así que la regla por caballo **nunca** ganaba sobre la general.

**Qué la revertiría.** Nada. Cualquier cálculo de dinero nuevo nace en la base.

---

## ADR-009 · Una prueba que pasa antes del arreglo no prueba nada

**Contexto.** Varias pruebas escritas de buena fe resultaron no estar midiendo lo que decían. Una comparaba 0 contra 0. Otra dejó de ejercitar su escenario cuando cambió el modelo y siguió en verde sin probar nada.

**Decisión.** Toda prueba nueva se verifica **en rojo contra el código roto** antes de darla por buena. Si no se puede poner roja, no es una prueba.

**Por qué.** Una prueba verde da una confianza que puede ser falsa, y una prueba falsa es peor que ninguna: impide buscar el fallo donde sí está.

**Consecuencias.** El arnés es SQL puro (`tests/pruebas_dinero.sql`), sin dependencias, y corre completo en segundos. Distingue pruebas que detectan **divergencia** de las que detectan que algo está **mal**.

**Corolario añadido el 28/09, después de violar este mismo ADR dentro del arnés.** Cuando el éxito de una prueba consiste en "saltó una excepción", hay que comprobar **cuál**. P39 pasaba en verde sin la migración aplicada: llamaba a una función inexistente, saltaba `undefined_function`, y su `exception when others` lo contaba como el rechazo que buscaba. Las dos mitades aprobaban porque no había nada que probar. La prueba debe **(a)** comprobar primero que existe lo que va a ejercitar, **(b)** exigir el SQLSTATE correcto —`P0001` para un rechazo nuestro, no `42883`— y **(c)** verificar además que no se escribió nada.

**Qué la revertiría.** Nada.

---

## ADR-010 · El CLI de Supabase se fija en scripts, no como dependencia

**Contexto.** `npx supabase` sin versión descarga lo que sea `latest` ese día. La documentación afirmaba que estaba instalado como dependencia del proyecto; **era falso**, nunca lo estuvo.

**Decisión.** Scripts en `package.json` con la versión escrita: `db:start`, `db:stop`, `db:reset`, `db:push:produccion`, todos con `npx -y supabase@2.118.0`.

**Por qué.** Meterlo como `devDependency` lo fijaría, pero Vercel instala las devDependencies en cada build y el paquete baja un binario de ~40 MB que el build no usa jamás. La idea de moverlo a scripts fue de Jota y es mejor que la alternativa que yo proponía (escribir la versión a mano cada vez, que nadie sostiene).

**Consecuencias.** El `-y` es obligatorio: sin él, el prompt de npx cuelga el script. El nombre largo de `db:push:produccion` es deliberado — toca producción y no debe escribirse por accidente.

**Qué la revertiría.** Que el CLI pase a hacer falta en el build. No se ve cómo.

---

## ADR-011 · El autocierre es opcional y viene apagado

**Contexto.** Hay dos tipos de remate. El **en vivo** dura horas el día de la carrera. El **adelantado** se monta días antes y puede seguir abierto hasta el sábado.

**Decisión.** El cierre automático por horario es una casilla que el admin marca si quiere, **apagada por defecto**. La apertura automática sí queda siempre activa.

**Por qué.** Cerrar solo es correcto para un remate en vivo. En un adelantado, `closes_at` es una hora estimada, y cerrar automáticamente ahí **cobra** a gente que el admin quería seguir dejando pujar.

**Consecuencias.** Con el autocierre apagado, `closes_at` queda como informativa, pero `hacer_puja` sigue rechazando pujas pasada esa hora. **Pendiente de implementar**: hoy `auto_cerrar_remates()` cierra todo lo vencido sin mirar ninguna casilla.

**Qué la revertiría.** Que en la práctica todos los remates sean en vivo. Entonces el valor por defecto cambia, no la opción.

---

## ADR-012 · La app no custodia dinero

**Contexto.** El cliente es la casa: cobra las recargas, paga los retiros y se queda su comisión. El dinero se mueve entre personas, por fuera.

**Decisión.** La plataforma es un **registro contable**, no un medio de pago. No tiene cuenta bancaria, no recibe pagos y no transfiere nada. Refleja lo que la casa confirma haber recibido y pagado.

**Por qué.** Es lo que de verdad hace. Documentarlo de otra forma sería describir mal el producto.

**Consecuencias.** Está escrito así en `docs/MODELO_DE_SALDO.md` y en `docs/licencia/COMO_FUNCIONA_EL_DINERO.md`. Los dos documentos dicen además que **los requisitos legales de operar así cambian según el país y son consulta con un abogado de esa jurisdicción** — ni del desarrollador ni del proveedor de la licencia.

**Riesgo estructural anotado, sin resolver:** nada impide hoy que una casa pague un premio con dinero que en realidad es del saldo de sus usuarios. El sistema lo **detecta** y avisa en rojo, pero no lo puede impedir: no controla la cuenta bancaria. La mitigación es la recomendación de tener dos cuentas separadas, y es una recomendación, no una garantía.

**Qué la revertiría.** Integrar una pasarela de pago de verdad (Fase 2). Eso cambiaría el modelo entero y exigiría rehacer esta decisión desde cero, con asesoría legal.

---

## ADR-013 · El borrado de un usuario lo frena una clave foránea, no un trigger

**Contexto.** La cadena `auth.users → profiles → wallets → wallet_movements`, más `profiles → bids / deposit_requests / withdraw_requests`, estaba entera en CASCADE. Borrar un usuario desde el panel de Auth de Supabase se llevaba su saldo, su historial de dinero y sus pujas — y borrar pujas de un remate abierto cambia en silencio quién va ganando, o sea el pozo y el compromiso de los demás.

**Decisión.** RESTRICT en los eslabones que **son** un dato (`wallet_movements`, `bids`, `deposit_requests`, `withdraw_requests`, `race_results→races`). CASCADE en los que **no** lo son (`profiles→auth.users`, `wallets→profiles`, `remate_price_rules→*`).

**Por qué así y no de otra forma.** Se consideró un log de auditoría que registrara el borrado para que el admin ajustara después. **No funciona, y no por falta de esfuerzo:** el cuadre de `casa_resumen()` se calcula desde `deposit_requests`, `withdraw_requests` y `wallets`, que son justo las tablas borradas — no queda un descuadre que ajustar, desaparece un sumando. Y las pujas de un remate abierto no son un asiento contable: para deshacerlas habría que reinsertarlas, o sea que el log tendría que ser una copia completa de las filas. Peor todavía: si borrar usuarios puede causar descuadres legítimos, la alarma ámbar deja de significar "hay un bug" y pasa a significar "revisa el log" — que es como se muere una alarma.

**Consecuencias.** El comportamiento sale del orden en que Postgres resuelve las cascadas, **sin un solo trigger ni lógica que mantener**: un usuario con cualquier rastro de dinero o pujas no se puede borrar; uno que se registró y nunca hizo nada sí. Esto último no es un detalle: `handle_new_user` crea un wallet al registrarse, así que un RESTRICT a secas sobre `wallets` habría bloqueado hasta las cuentas de prueba.

El costo es que el admin ve un error crudo de Postgres en el panel de Supabase. Un `desactivar_usuario()` con mensaje decente queda para el ADR de roles.

**Qué la revertiría.** Que aparezca una obligación legal de borrado real de datos personales en alguna jurisdicción donde opere un licenciatario. Eso exigiría separar el dato personal del dato contable —anonimizar en vez de borrar— y sería una decisión nueva, con asesoría legal.

---

## ADR-014 · Los avisos al jugador los escribe el sistema, no el admin

**Contexto.** Se decidio (27/09) que el admin pueda cambiar el incremento de un remate en marcha —un remate estancado puede necesitar subir mas rapido— y el porcentaje de la casa antes de la primera puja. Los dos cambian lo que el jugador esperaba cuando entro.

**Decision.** Tabla `remate_avisos`, escrita **desde dentro de las RPC de edicion**. El admin no redacta el aviso ni puede omitirlo: si el cambio ocurre, el aviso existe. Lectura publica (`anon` incluido), escritura solo por RPC.

**Por que.** Es el mismo razonamiento del asiento `resultado_remate` del ADR-007: **un aviso que depende de que alguien se acuerde de escribirlo no es un aviso, es una intencion.** Si el admin pudiera elegir si anunciar o no, el jugador no tendria forma de distinguir "no cambio nada" de "cambio y no me lo dijeron".

**Consecuencias.** El texto del aviso lo compone la funcion a partir del valor anterior y el nuevo, asi que dice siempre la verdad y siempre en el mismo formato. `detalles` guarda los dos valores en jsonb para poder auditar sin parsear texto.

**Qué la revertiría.** Nada previsto. Si aparecen mas campos editables en marcha, se suman al mismo mecanismo.

---

## ADR-015 · Una regla se implementa una vez, y vive donde vive el dato

**Regla de Jota, 28/09/2026, literal:** *"Erradica todo lo que se haga en la DB y en el frontend y que son la misma cosa. Ya vemos que eso trae confusión y desastre. Lo que es DB que sea solo allá y lo que debe ser FE solo ahí."*

**Contexto.** La auditoría del 28/09 encontró la misma regla implementada en varios sitios, tres veces:

- **El pozo y la comisión de la casa:** en `liquidar_remate`, en `admin_contabilidad_resumen`, y en TypeScript en tres pantallas. Cinco implementaciones. Las del admin no filtraban caballos retirados y una tenía el 25% clavado, así que el admin aprobaba pagos viendo cifras que no eran las que se iban a pagar.
- **Los mínimos de puja:** en `hacer_puja` y en el frontend. Divergieron el 23/09 y la pantalla mostraba un número mientras la base cobraba otro. Se resolvió con `remate_minimos()`.
- **Quién va ganando un caballo:** en cuatro funciones SQL y en tres pantallas. Hoy coinciden. Es cuestión de tiempo.

**Decisión.** Toda regla de negocio —lo que se cobra, lo que se paga, quién gana, qué cuenta y qué no— se implementa **una sola vez, en la base**, y se expone por RPC. **El frontend muestra, no calcula.**

El criterio para decidir dónde va algo: *si el número tiene consecuencias en el dinero, va en la base.* Si es presentación —formato, colores, orden de una lista, qué se ve primero— va en el frontend y solo ahí.

**Por qué.** No es preferencia de arquitectura: es que **dos implementaciones de la misma regla siempre acaban separándose, y la única pregunta es cuándo te enteras.** En este proyecto nos enteramos tres veces, y las tres por casualidad: mirando un número que no cuadraba. El caso del pozo llevaba desde enero.

Y tiene una consecuencia que importa para licenciar: un licenciatario que configure el 20% y una pantalla que calcule el 25% no producen un error — producen un pago incorrecto con una interfaz que lo confirma.

**Consecuencias.**
- Las pantallas que hoy calculan el pozo pasan a consumir una RPC `remate_totales(p_remate_id)` que devuelva pozo, porcentaje, casa y neto **desde la misma consulta que `liquidar_remate`**. Cuatro copias → una.
- `remate_minimos()` es el precedente y el patrón: devuelve por caballo todo lo que la pantalla necesita dibujar.
- Ningún valor de negocio se escribe a mano en el frontend. Los que hoy lo están —el porcentaje por defecto, el precio de salida por defecto, el incremento— pasan a los ajustes de instalación.
- Cuando una regla cambie, cambia en un sitio. Si hay que tocar dos archivos para cambiar una regla, la regla está mal puesta.

**Qué la revertiría.** Un cálculo de presentación pura que necesite ser interactivo sin ida y vuelta al servidor — por ejemplo la simulación de la escalera al elegir el ritmo, que no mueve dinero y tiene que responder al teclear. Esos casos existen y son legítimos; la prueba para distinguirlos es si el número que sale puede diferir del que se cobra. Si puede, va en la base.

---

## ADR-016 · Los permisos son un inventario declarado, no una consecuencia

**Contexto.** El 29/09, al probar A6, se descubrió que `ALTER DEFAULT PRIVILEGES` no es una rareza de este proyecto: la imagen de Supabase trae, antes de cualquier migración, `GRANT ALL ON TABLES TO anon, authenticated` para todo lo que cree `postgres` en `public`. Su propio `config.toml` lo llama *"matching the cloud default"*. Las quince tablas del esquema nacieron abiertas sin que ninguna migración lo escribiera, y por tanto sin que apareciera en ningún diff.

Cerrarlo desde la base resultó imposible para las funciones. PostgreSQL concede `EXECUTE` a `PUBLIC` de fábrica, y su documentación dice literalmente que un revoke con `IN SCHEMA` **no hace nada**: *"per-schema default privileges can only add privileges to the global setting, not remove privileges granted by it."* La entrada global sí funciona, pero aplica a todos los esquemas: comprobado en un Postgres real, tras ponerla un `create extension citext` deja sus 23 funciones sin `EXECUTE` para `authenticated`, lo que rompe hasta un `where columna = 'x'`. En una base que opera un licenciatario, eso es una mina.

**Decisión.** La base **no** falla cerrada en funciones. El arnés falla ruidoso.

- `P47` enumera todas las funciones de `public` y las compara contra una lista blanca declarada. Una función que nadie declaró se pone roja.
- `P48` hace lo mismo con las tablas, verbo por verbo, para `anon` y para `authenticated`.
- Toda RPC nueva necesita dos cosas: su `grant execute` y su línea en el censo. Con solo una de las dos, el arnés está rojo.

**Por qué.** El defecto real no era que algo naciera abierto: era que **nadie se enteraba**. Un censo que enumera el estado completo y falla ante lo no declarado convierte un silencio en un rojo, y no deja minas en casa de nadie.

**Y una segunda razón, del mismo día.** `TRUNCATE` no pasa por la RLS — doc 17, 5.9: *"Operations that apply to the whole table, such as TRUNCATE and REFERENCES, are not subject to row security."* `anon` y `authenticated` tenían ese privilegio sobre las quince tablas. Ninguna política lo frenaba porque **ninguna política puede frenarlo**. Un modelo de seguridad que solo mira las políticas es ciego a esa clase entera de permisos. El censo mira el privilegio.

**Consecuencias.**
- Los revokes se escriben siempre en la forma completa: `from public, anon, authenticated`. Doce funciones llevaban `=X/postgres` y sobrevivieron a revokes que solo nombraban a `anon` — `mi_wallet_resumen` entre ellas, revocada el 25/09 y todavía ejecutable por `anon` el 29/09.
- Los permisos no se prueban ejercitándolos: el arnés corre como `postgres` y se salta cualquier ACL. Se consultan con `has_table_privilege` y `has_function_privilege`.
- Como el arnés no puede ver una rotura de permisos en la aplicación, **toda tanda que quite permisos se clica a mano contra la base local** antes de subir. De ahí sale `.env.development.local`.

**Qué la revertiría.** Que Supabase permita fijar `auto_expose_new_tables = false` también en el proyecto alojado, no solo en el CLI local. Entonces la base sí podría fallar cerrada sin el coste de la entrada global, y el censo pasaría de ser la defensa a ser la comprobación de que la defensa sigue puesta.

---

## ADR-017 · El licenciatario manda sobre las reglas, no sobre la aritmética

**Contexto.** Al cerrar la escritura directa de las tablas de dinero, Jota planteó la objeción correcta: *"tampoco puedo imponerle el porcentaje de utilidad a nadie"*. La pregunta de fondo es qué le queda en las manos a quien alquila la aplicación.

**Decisión.** La línea que separa lo que se cierra de lo que no:

> **Un parámetro de negocio es una ENTRADA que el licenciatario fija antes de que el dinero se mueva. Un saldo es una SALIDA que el sistema calcula después. Él manda sobre las reglas; no manda sobre la aritmética.**

**Queda abierto, con guardia** — suyo, por RPC, con reglas y con aviso a los jugadores: porcentaje de la casa, precio de salida, incremento, escalera por caballo, textos de soporte, datos bancarios.

**Queda cerrado** — nadie lo escribe a mano, tampoco el dueño: `wallets`, `wallet_movements`, `bids`, `race_results`, `profiles`, `withdraw_requests`, `deposit_requests`, `admin_actions`.

**Por qué.** Cerrar el saldo no le quita poder al licenciatario: **le da la única defensa que va a tener el día que un jugador lo acuse de haberle tocado la cuenta.** Mientras un admin pueda escribir `wallet_movements` —que es justo lo que lee el cuadre— puede falsear los libros y la auditoría que comprueba los libros con la misma sesión, y por tanto no puede demostrar que no lo hizo. Es un argumento de venta, no una restricción.

**Consecuencias.**
- Las políticas `*_admin_all` sobre tablas de dinero pasan de `FOR ALL` a `FOR SELECT`. El admin sigue viendo todo; deja de poder escribirlo.
- El porcentaje se fija remate a remate y se congela con la primera puja. Falta el valor por defecto de la instalación (A1), para que el número de arranque sea suyo y no el 25 que trae el código.
- Al crear un remate se muestra siempre una confirmación con los tres números que mandan sobre el dinero —porcentaje, precio de salida, incremento— antes de guardar.

**Qué la revertiría.** Un caso legítimo de corrección manual sobre un saldo. Existe: un error operativo que hay que deshacer. La respuesta no es reabrir la tabla, sino darle su propia RPC con motivo obligatorio y asiento en el libro, como `registrar_movimiento_casa`. Si algún día hace falta, se añade así.

---

## ADR-018 · Antes de cerrar una puerta, buscar quién la usa

**Contexto.** El 30/09, la migración que puso `remate_price_rules.horse_id` en `NOT NULL` dejó dos pruebas en rojo —P13 y P28— porque montaban sus escenarios insertando reglas generales. La migración era correcta; lo que faltó fue un `grep remate_price_rules tests/` de dos segundos antes de escribirla.

Fue la tercera vez el mismo día. Las otras dos: `alter default privileges ... in schema public revoke ... from public`, escrito sin leer la página del comando que lo declara inútil; y el `revoke select` sobre `deposit_requests` para `anon`, afirmado a partir de leer la baseline en vez de consultar la base real, donde el permiso sí estaba.

**Decisión.** Antes de quitar un permiso, añadir una restricción o borrar una capacidad, se enumeran sus usos. No se deduce: se busca.

- **En el repositorio:** `grep` del nombre del objeto en `app/`, `lib/`, `tests/` y `supabase/migrations/`, antes de escribir la migración.
- **En la base:** el estado real se consulta, no se infiere del código que debería haberlo producido. Para eso existen `tests/diagnostico_acl.sql` y `supabase/snippets/diagnostico_remate.sql`.
- **En la documentación:** si la migración usa un comando poco frecuente, se lee su página antes de escribirlo.

**Por qué.** Las tres equivocaciones del 30/09 tienen la misma forma: **afirmar el estado de algo en vez de consultarlo.** Cuestan minutos cuando las caza el arnés y cuestan dinero cuando no. La de `ALTER DEFAULT PRIVILEGES` habría dejado el agujero A6 abierto creyéndolo cerrado, y solo la destapó una prueba escrita antes del arreglo.

**Consecuencias.**
- El orden de despliegue se decide mirando quién escribe qué. Cuando la migración cierra algo que el frontend todavía usa, **el frontend va primero** — al revés de lo habitual. Pasó con la escalera: `crear-remate` mandaba `horse_id: null` hasta que se desplegó el cambio.
- Una prueba que se pone roja por una migración nueva no se parchea para que pase. Se mira qué medía: si medía el defecto que se acaba de eliminar, se reescribe para medir lo que queda en pie. P13 probaba la precedencia de la regla general sobre la del caballo, que era exactamente el agujero; reescrita, mide la precedencia de la escalera del caballo sobre el incremento del remate.

**Qué la revertiría.** Nada previsible. Es una regla de método, no de arquitectura; su coste es de segundos y su fallo se paga en producción.

---

## ADR-019 · Una carrera se prueba con dos sesiones, o no se prueba

**Contexto.** Tres de los nueve arreglos de la auditoría del 28/09 son condiciones de carrera: el `for share` de `hacer_puja` (A2), el candado de caja de `liquidar_remate` (A4) y el `unique` de `race_results` (D1). Los tres se desplegaron a producción el 29/09 con el arnés en verde. Pero el arnés corre con **una sola conexión**, y una carrera no se reproduce con una conexión: P45 comprobaba que un `insert` a mano rebota contra el `unique`, no que dos admins simultáneos no puedan insertar.

Es una distinción que se pierde con facilidad porque el resultado se parece: la prueba de la valla y la prueba de la carrera salen las dos verdes. La diferencia aparece el día que la valla no estaba y nadie se enteró.

**Decisión.** `tests/concurrencia.sql`. La sesión principal toma un candado dentro de una transacción abierta y no la cierra; una segunda conexión, abierta con `dblink` desde el mismo psql, lanza la operación real de forma asíncrona. `dblink_is_busy` dice si se quedó esperando. Las funciones son las de producción; lo único simulado es el momento.

La contraprueba es lo que le da valor: sin el `unique`, la segunda sesión **no espera**, entra, y quedan dos filas para la misma carrera. Verificado antes de escribir el archivo.

**Lo que costó hacerlo funcionar, y que vale para el paquete del licenciatario.**

- En Supabase el rol `postgres` **no es superusuario** (`rolsuper = f`).
- La documentación de dblink: *"Only superusers may use `dblink_connect` to create non-password-authenticated and non-GSSAPI-authenticated connections."*
- El `pg_hba` del contenedor confía en las conexiones locales, así que por socket o por `127.0.0.1` la contraseña **no se usa** aunque se mande, y dblink lo rechaza con `2F003`. No es que la clave sea incorrecta: es que no se llegó a pedir.
- `dblink_connect_u`, la variante para no-superusuarios, tiene el ACL `{supabase_admin=X/supabase_admin}`: `postgres` no puede ejecutarla ni concederse el permiso.
- **Lo que funciona:** conectar al nombre de red del contenedor (`host=db`). Esa conexión sale por una dirección que no es loopback, ahí el `pg_hba` exige `scram`, la contraseña se usa, y la comprobación de seguridad pasa.

**Consecuencias.**
- El archivo depende del andamiaje `_p` del arnés en vez de duplicarlo. Una segunda implementación del mismo escenario es exactamente el defecto que persigue el ADR-015.
- Después de un `dblink_send_query` hay que **drenar** con `dblink_get_result` hasta que devuelva cero filas. Sin drenar, la conexión queda con el comando a medias y la siguiente operación falla con *"another command is already in progress"* — y el síntoma aparece en una prueba distinta de la que lo causó, que es la peor forma de fallar. Cada escenario abre además su propia conexión, como segunda red.
- Todo arreglo futuro que dependa de un candado lleva su prueba aquí, no en el arnés.

**Qué la revertiría.** Que `pg_hba` cambie y la conexión por nombre de red deje de exigir contraseña. Entonces haría falta que un superusuario conceda `dblink_connect_u`, o pasar a dos procesos `psql` coordinados desde fuera de la base.

---

## ADR-020 · Una extensión en `public` se declara, porque cerrarla no está en nuestras manos

**Contexto.** El censo de funciones (P47, ADR-016) se puso rojo con **41 funciones sin declarar**, todas `dblink*`, ejecutables por `anon` y `authenticated`. No las trae ninguna migración: las trae `create extension if not exists dblink` de `tests/concurrencia.sql`, y nacen abiertas por dos motivos a la vez — PostgreSQL le da `EXECUTE` a `PUBLIC` de fábrica (doc 17, §5.8) y la imagen de Supabase tiene `ALTER DEFAULT PRIVILEGES ... GRANT ALL ON FUNCTIONS TO anon, authenticated`.

Con `dblink` deja de ser un detalle de permisos: `dblink` abre conexiones **de red desde el servidor de la base**.

**El error que hubo que corregir por el camino.** La primera versión de este ADR decidía "quien abre, cierra": `concurrencia.sql` revocaría sobre las funciones de la extensión justo después de crearla. Se verificó en un Postgres 16.13 —41 → 0— y se dio por bueno. Contra la base real no hizo nada, y la base lo dijo con dos mensajes que no dejan lugar a dudas:

```
WARNING: no privileges could be revoked for "dblink"
ERROR  42501: permission denied for function dblink_connect_u
```

El primero es lo que PostgreSQL emite cuando **quien revoca no es quien concedió**. El segundo, que `postgres` **no es el dueño**. En Supabase, `supautils` intercepta `CREATE EXTENSION` y la crea con un rol privilegiado, así que desde `postgres` la extensión no se puede revocar, ni mover de esquema, ni borrar. Se va con el próximo `db reset` y no antes.

La causa del error no fue la decisión sino el entorno de prueba: en un Postgres pelado `postgres` es dueño de todo, y ahí cualquier cosa funciona. **Un entorno de prueba más permisivo que el real no prueba nada**; es la misma lección que ADR-019 ya había aprendido con `pg_hba`, aplicada mal al día siguiente.

**Decisión.** Ninguna de las dos tentaciones.

No cerrarla, porque no se puede — y una prueba que exige lo imposible termina comentada, que es la peor forma de perder una prueba. Y no esconderla moviéndola al esquema `extensions`: ahí dejaría de verla el censo, pero `anon` tiene `usage` sobre ese esquema, así que seguiría pudiendo ejecutarla. Eso sería teatro.

Se **declara**, igual que las dos excepciones vivas de P48: con su razón y su alcance escritos al lado. `dblink` está en la lista `extensiones_toleradas` de P47 con cuatro hechos comprobables: que la instala `tests/concurrencia.sql`, que ninguna migración la crea —y por tanto producción no la tiene—, que la crea `supabase_admin` vía supautils, y que desaparece en el próximo `db reset`.

Cualquier **otra** extensión que aparezca en `public` pone la prueba en rojo, esté abierta o cerrada: una extensión sin declarar en `public` ya es el hallazgo. Y el detalle de la prueba reporta el **dueño**, que es el dato que decide si se puede hacer algo al respecto.

**Consecuencias.**
- El censo sigue contando cuántas funciones de extensión están abiertas y lo dice en el detalle. Tolerada no es invisible.
- `supabase/snippets/diagnostico_extensiones.sql` responde las tres preguntas —qué hay, de quién es, quién la ve— incluida la que faltó: *¿puedo hacer algo desde este rol?*
- Lo que de verdad protege producción no es el censo sino que no exista ningún `create extension` en `supabase/migrations`. Verificado el 01/10 y comprobable en un comando: `grep -ri "create extension" supabase/migrations/`.

**Qué lo revertiría.** Que `concurrencia.sql` deje de necesitar `dblink` —dos procesos `psql` coordinados desde fuera de la base harían el mismo trabajo sin instalar nada— o que Supabase permita al rol `postgres` gestionar las extensiones que él mismo pidió crear. Lo primero está en nuestra mano y es la salida limpia el día que moleste.

---

## ADR-021 · Un parámetro opcional no puede significar «quítalo» y «no lo toques» a la vez

**Fecha.** 02/10/2026

**Contexto.** Jota pidió que la hora de apertura de un remate fuera opcional, como ya lo era la de cierre: *«que lo programen si quieren y si lo dejan vacío el remate queda activo apenas se cree»*.

La base ya lo soportaba. `hacer_puja` compara contra la apertura con guarda de nulo (`if v_remate.opens_at is not null and now() < v_remate.opens_at`), la pantalla pública hace lo mismo, y el cierre automático solo mira los remates que tienen `closes_at`. Un remate sin apertura ya estaba activo desde su creación. Por ADR-015 —lo que es FE se queda en FE— el formulario de **crear** se arregla sin tocar la base.

Buscando eso apareció un defecto que no era el que se buscaba. `editar_remate` decide si toca el horario con `p_opens_at is not null`. Con ese contrato **NULL significa «no lo cambies»**, así que una vez puesto un horario **no había forma de quitárselo desde la aplicación**: el admin borraba la hora de cierre, guardaba, no salía ningún error, y el cierre seguía ahí. La pantalla decía una cosa y la base guardaba otra, en silencio.

No fue un descuido de la migración del 28/09. Con parámetros opcionales y un solo centinela, *«sin valor»* y *«quitar el valor»* son literalmente el mismo valor. No se puede distinguir desde dentro.

**Decisión.** Una bandera explícita por campo: `p_limpiar_opens_at`, `p_limpiar_closes_at`. Tres caminos, y ninguno ambiguo:

| entrada | efecto |
|---|---|
| `p_opens_at = null`, bandera `false` | no se toca |
| `p_opens_at = valor` | se pone ese valor |
| bandera `true` | queda en `NULL` |

Si llegan las dos a la vez —valor y bandera— se **rechaza** en vez de adivinar cuál gana. Una orden contradictoria es un error del cliente, y tragárselo es cómo se vuelve a llegar al silencio del que venimos.

**Dos detalles que no son adorno.**

*El `drop` antes del `create`.* PostgREST resuelve las RPC por **nombre de argumento**. Añadir dos parámetros con `default` sin borrar la firma vieja deja dos funciones `editar_remate`, y la llamada de seis argumentos se vuelve ambigua (PGRST203). Es la misma piedra de `rechazar_recarga` y `procesar_retiro` del 01/10, y `create or replace` no la evita porque no borra la firma anterior.

*El cuerpo no se retecleó.* Se generó a partir del archivo del 28/09 cambiando solo la firma, la guarda nueva y el bloque de horarios. En el primer intento sí lo escribí a mano y perdí por el camino el `pg_advisory_xact_lock(2, ...)`, cambié dos mensajes de error y me inventé un estado `'programado'` que no existe. Reescribir a mano un cuerpo que ya funciona es una forma barata de introducir defectos que nadie va a buscar ahí.

**Consecuencias.**
- `P57` mide las cinco cosas: que haya **una sola** firma, que `null` siga sin borrar, que la bandera borre apertura y cierre, que un remate sin apertura **se pueda pujar**, y que poner y quitar a la vez se rechace con `P0001`.
- Las dos pantallas dejan de rellenar un horario vacío con `created_at` y medianoche. Media fecha es peor que ninguna: antes, elegir el día y olvidar la hora programaba el remate a las 00:00 sin avisar. Ahora se exige el par completo o nada, en los dos campos.
- La regla general que queda: **cuando un parámetro opcional tenga que poder borrar, el borrado se pide aparte.** Vale para cualquier RPC de edición que venga después.

**Qué lo revertiría.** Pasar a un contrato de parches explícitos —un `jsonb` con solo las claves que cambian— donde la ausencia de una clave y su valor `null` ya son cosas distintas sin necesidad de banderas. Es más limpio y más caro; hoy no lo paga nadie.

---

## ADR-022 · Una alarma que suena cuando no pasa nada no es una alarma

**Fecha.** 05/10/2026

**Contexto.** `/admin/contabilidad` llevaba días mostrando en ámbar: *«El libro no cuadra con los saldos. Diferencia de −1.380,00 Bs. Esto no debería pasar nunca: avisa antes de seguir operando.»*

Perseguí ese número tres turnos. Primero dije que faltaba liquidar. Luego me retracté y dije que era un desfase fijo y antiguo, porque el descuadre no se había movido entre dos capturas. Luego me retracté de la retractación al hacer la aritmética: cerrar baja el descuadre en lo cobrado y liquidar lo sube en lo mismo, así que un ciclo cerrar+liquidar lo deja igual — mi "prueba" de que era fijo no probaba nada. Jota llegó a la respuesta buena mientras tanto, de memoria: *«tengo muchos remates cerrados mas no liquidados»*.

Medido contra producción: **descuadre −1.380,00 y cobrado sin asentar 1.380,00**, al céntimo, con 8 remates cerrados sin liquidar. Reconstruidos desde `wallet_movements`, los saldos daban 6.370,00 exactos contra los 6.370,00 de `wallets`. **No faltaba un céntimo en ninguna parte.** La contabilidad estaba intacta. La alarma estaba mal.

Y tenía que estarlo, porque la secuencia es así por diseño: **cerrar le cobra a los líderes, liquidar escribe el asiento.** Entre una cosa y la otra el libro va por detrás de los saldos. Un remate cerrado el viernes y liquidado el lunes tiene tres días de descuadre legítimo.

**La decisión.** `casa_resumen()` devuelve dos columnas nuevas y la pantalla alarma con la segunda:

```
pendiente_de_liquidar = -SUMA(apuesta_cobro + apuesta_devolucion + premio)
                        de los remates que aún no tienen asiento
descuadre_inexplicado = descuadre + pendiente_de_liquidar
```

Es una **identidad**, no una aproximación. Desarrollando: `perdida_usuarios` es exactamente `resultados_asentados + pendiente_de_liquidar`, así que `descuadre = -pendiente_de_liquidar` y el inexplicado da cero. El desarrollo descansa en un supuesto que conviene ver escrito: que `ajuste_manual` solo se usa para devolver un retiro rechazado. **Si alguien mueve un saldo a mano por otro motivo, la identidad se rompe — y eso es exactamente lo que la alarma tiene que cazar.**

El instrumento nuevo no es más permisivo: es más afilado. Antes, 500 Bs aparecidos de la nada se escondían dentro de un −1.380 que ya nadie miraba. Ahora salen con su nombre y su importe.

**El riesgo de este tipo de arreglo, y cómo se evita.** Una implementación que devolviera `descuadre_inexplicado = 0` siempre habría apagado la alarma y pasado cualquier prueba que solo comprobara que se apaga. Por eso **P58 tiene tres fases**: cerrado sin liquidar (descuadre ≠ 0 pero inexplicado = 0), liquidado (todo a cero) y **un saldo movido a mano, donde el inexplicado tiene que valer exactamente ese importe**. La tercera es la que impide que esto sea cosmética. No se mide que la alarma se calle; se mide que siga sonando cuando toca.

Verificado antes de entregarlo, en un Postgres 16.13 con un escenario que reproduce los números de producción al céntimo: devuelve descuadre −1.380,00, pendiente 1.380,00, inexplicado 0,00 y 8 remates; y metiendo un `ajuste_manual` de 500 sin respaldo, inexplicado 500,00.

**Consecuencias.**
- `descuadre` **se queda** en la función y en la pantalla. Deja de alarmar, no de mostrarse: borrar un número porque hay otro mejor es cómo se pierde la capacidad de comparar contra las capturas de la semana pasada.
- Aparece un bloque gris, informativo: *«8 remates cerrados sin liquidar · 1.380,00 Bs pendientes de asentar»*. Informa sin asustar, y le dice al licenciatario qué tiene que hacer.
- `drop function` antes del `create`: `create or replace` no puede cambiar el tipo de retorno (42P13).
- La regla general: **antes de escribir una alarma, hay que saber decir en qué estado normal NO debe encenderse.** Si no se sabe, la alarma todavía no está diseñada.

**Qué lo revertiría.** Que liquidar deje de ser un paso manual y ocurra dentro de la misma transacción que cierra. Entonces no habría ventana, el descuadre volvería a ser siempre anómalo y `descuadre_inexplicado` sería redundante. Hoy la ventana existe a propósito: entre cerrar y liquidar hay un humano mirando el resultado de la carrera.

---

## ADR-023 · El registro solo lee, y el texto que escribe el admin no es sintaxis

**Fecha.** 05/10/2026

**Contexto.** Jota: *«Hay que tener un log de transacciones URGENTE… vercel no lo crea? Quizás lo podamos consumir de ahí»*. Vercel no: registra peticiones HTTP e invocaciones de función, con retención corta, y no sabe nada de dinero.

El registro ya existía, en tres tablas, con sus políticas de admin puestas desde el 29/09. Lo que faltaba era la pantalla. `admin_actions` en particular llevaba desde el principio guardando quién aprobó, quién rechazó, con qué motivo y si falló — **y no lo leía absolutamente nadie**. Una bitácora que nadie puede abrir no es una bitácora: es un coste de escritura.

**Decisión 1: tres pestañas, no una línea de tiempo mezclada** (elegido por Jota). Cada fuente responde una pregunta distinta y se audita por separado: `wallet_movements` qué le pasó al dinero de un jugador, `house_ledger` qué le pasó al de la casa, `admin_actions` qué hizo un admin y si le salió bien.

**Decisión 2: cero migraciones.** Las tres tablas tienen `grant select to authenticated` y una política `using (is_admin())`. Las claves foráneas para resolver los nombres también estaban. Añadir una RPC `security definer` para esto habría sido ampliar la superficie privilegiada sin ganar nada.

**Decisión 3: la pantalla no calcula.** Lee y muestra. Es el ADR-015 llevado hasta el final: si aquí se sumara o se dedujera algo habría una segunda contabilidad escrita en TypeScript, que podría discrepar de la de la base — justo el defecto que este registro existe para poder detectar. Lo dice la propia pantalla al pie: *«si alguna vez discrepa de la contabilidad, el que tiene razón es el libro»*.

**Lo que apareció escribiéndola: inyección de FILTRO.** El buscador construye el filtro así:

```ts
q.or(`descripcion.ilike.%${t}%,ref_externa.ilike.%${t}%`)
```

PostgREST lee **esa cadena como sintaxis**: la coma separa condiciones y los paréntesis agrupan. Un admin que busque `pago movil, 0412` parte el filtro en tres trozos; con paréntesis puede sustituirlo por otro. No es inyección de SQL —PostgREST no concatena SQL— pero el efecto práctico es el mismo y **en un registro de auditoría es el peor posible**: devuelve algo distinto de lo que se pidió, sin avisar, y quien lo mira se queda convencido de que no hay nada.

De ahí `limpiarBusqueda`, que saca `, ( ) * " % \` antes de construir el filtro. El admin escribe palabras, no sintaxis.

**Consecuencias.**
- `tests/log.mjs` (`pnpm test:log`), con el mismo método que `tests/fechas.mjs`: transpila el archivo **real** y ejercita sus funciones, sin copias que se despeguen del original. **32 comprobaciones**, incluida una que exige que **ningún** carácter de sintaxis sobreviva, otra que mide que el rango de un día dure exactamente un día menos un milisegundo — dos días seguidos no pueden devolver la misma fila dos veces — y las de legibilidad del apartado siguiente.
- Las horas se pintan en la zona del navegador, como el resto de la aplicación, **y la pantalla dice cuál es**. En un registro de auditoría una hora sin zona no sirve de nada; cambiar la convención en una sola pantalla habría creado la inconsistencia que estamos evitando.
- `max-w-3xl` en vez del `max-w-md` del resto del panel: fecha, actor, importe, descripción y referencia no caben en ancho de teléfono sin partir cada fila en cuatro líneas. Es la única pantalla que se sale, y se sale a propósito.
- El CSV exporta **lo que está cargado en pantalla**, y el botón lo dice con el número de filas. Un CSV que promete "todo" y trae 50 filas es peor que no tenerlo.

**Lo que hubo que rehacer el mismo día: de JSON a castellano.** La primera versión pintaba `details` con un `JSON.stringify` y ya. Jota lo vio y lo dijo en una línea: *«¿eso no está como muy complicado?»*. Lo estaba — y un registro de auditoría que hay que descifrar no se lee, que es exactamente el defecto que esta pantalla venía a arreglar.

El criterio: lo que se busca al abrir una fila es **qué cambió**. Eso va primero y en palabras (`pendiente → pagado`), lo demás en etiquetas cortas (`Monto: 500,00 Bs`, `Motivo: Los datos de destino no son correctos`), los UUID recortados a ocho caracteres — que siguen sirviendo para buscar, porque el filtro usa `ilike` — y el JSON completo detrás de un `ver todo`, porque para auditar de verdad a veces hace falta el dato crudo.

Degrada bien a propósito: una acción o una clave que no esté en los diccionarios sale legible igual (guiones bajos por espacios, primera en mayúscula) en vez de desaparecer o romper la fila. Una tabla de traducción que hay que mantener al día acaba desactualizada; esta no puede.

**Y el botón que «no se podía clicar».** El «Comprobar» de la barra de caja leía los contadores y, si no habían cambiado, no pasaba nada en pantalla. Jota: *«no funciona, no se puede ni clicar, es como si fuera simple texto»*. El botón sí hacía su trabajo; lo que no hacía era decirlo. **Un control sin acuse de recibo es un control roto**, aunque el código de debajo esté bien. Ahora pasa por «Comprobando...» y «Al día».

Y de paso quedó comprobado que la manito **no** era el problema: la regla de `cursor: pointer` para Tailwind v4 ya estaba en `globals.css` desde el 25/09. Lo verifiqué leyendo el `preflight.css` de tailwindcss 4.3.3 instalado — cero `cursor: pointer` en todo el archivo — antes de afirmar nada.

**Qué lo revertiría.** Que el volumen crezca hasta que paginar desde el cliente deje de servir — ahí haría falta una RPC con la consulta ya resuelta y un índice por fecha. Con dos dígitos de operaciones al día, todavía no.

---

## ADR-024 · Una cadena se diagnostica eslabón por eslabón, y el eslabón barato primero

**Fecha.** 05/10/2026 · **Cerrado**

**Contexto.** Durante días el canal `admin:caja` parecía no funcionar: las recargas y los retiros solo aparecían recargando la página, mientras `remate:*` iba perfecto. Perseguí la causa por hipótesis —la política con `is_admin()`, los permisos del emisor, la retención de `realtime.messages`— y ninguna era.

**Lo que lo resolvió fue partir la cadena en eslabones y medir cada uno por separado**, empezando por el más barato:

| eslabón | cómo se midió | coste |
|---|---|---|
| ¿el disparador existe y está activo? | `pg_trigger.tgenabled` | una consulta |
| ¿la política existe? | `pg_policy` sobre `realtime.messages` | la misma consulta |
| ¿el oyente está autorizado? | `[realtime] admin:caja: SUBSCRIBED` en la consola | diez segundos |
| ¿el emisor puede escribir? | `realtime.send(...)` llamado a mano | una consulta |
| ¿la entrega llega al navegador? | esa emisión impresa en la consola | la misma prueba |
| ¿el disparador real se dispara? | `update ... set estado = estado` | una consulta |

El último dio `payload: {id: ..., estado: 'pendiente'}` en la consola del admin — exactamente lo que construye `tr_avisar_recarga`, no el payload de prueba. **El camino real funciona entero.**

**La causa de lo observado.** Las solicitudes de prueba son del 30/09; la migración `20260930120000_realtime_senales` también. Los eventos que no llegaron no llegaron porque no había disparador todavía. El único evento de caja real en la tabla, un `retiro` del 02/10, sí se emitió solo.

**La lección, que es de método y no de realtime.** Me costó tres turnos porque estuve proponiendo explicaciones en vez de cortar el problema. Una cadena de seis eslabones tiene seis sospechosos; una hipótesis descarta uno si aciertas y ninguno si fallas, mientras que medir un eslabón descarta uno **siempre**. Con seis eslabones y seis medidas baratas, el caso se cierra en una sesión.

Y el corolario incómodo: **el `exception when others` de `_avisar` me escondió el eslabón del emisor durante todo ese tiempo.** Está bien que esté —una notificación perdida no puede tumbar una puja— pero significa que para diagnosticar hay que llamar a `realtime.send` **sin** el envoltorio. Eso ahora está escrito en `supabase/snippets/diagnostico_02oct.sql`. Un `raise warning` que nadie lee es un fallo silencioso con buena intención.

**Lo que faltaba, medido ese mismo día.** Jota dejó `/admin/retiros` en una pestaña de atrás, creó dos solicitudes desde otra, y la lista no se movió. La consola:

```
[realtime] admin:caja: SUBSCRIBED
[realtime] admin:caja <- retiro
[realtime] admin:caja <- retiro
[realtime] admin:caja: CLOSED
```

**Los dos eventos llegaron.** El séptimo eslabón —el que va del evento a la pantalla— era el único que quedaba, y era el roto. Ver ADR-025.

---

## ADR-025 · Una suscripción en tiempo real no es «suscribirse»

**Fecha.** 05/10/2026

**Contexto.** Con la cadena de realtime ya probada entera (ADR-024), los eventos llegaban al navegador y la pantalla seguía sin moverse. La consola lo dijo en cuatro líneas: `SUBSCRIBED`, dos `<- retiro`, y un `CLOSED` que **no pidió nadie**.

Dos cosas que el navegador hace a propósito, y que la primera versión del hook ignoraba:

1. **Una pestaña de atrás se congela.** Chrome estrangula los `setTimeout` de una pestaña oculta y, pasados unos minutos, la congela entera. El temporizador de 250 ms que agrupa las señales puede no dispararse nunca: el evento entra y la recarga no sale.
2. **El socket se cierra.** Ese `CLOSED` lo cerró el navegador, y el hook no hacía nada con él. La pantalla se quedaba muda para siempre **con pinta de estar escuchando**.

Lo segundo es lo grave. Es el mismo defecto que ADR-022 en otro disfraz: un instrumento que miente sobre su propio estado. El admin cree que está viendo la caja en vivo y está mirando una foto — y a diferencia de una alarma que grita de más, esta calla de más, que es la dirección peligrosa. Al otro lado hay un jugador esperando que le aprueben un retiro.

**Decisión.** `useSenal` deja de ser una suscripción y pasa a ser una suscripción **supervisada**:

- `CLOSED`, `CHANNEL_ERROR` y `TIMED_OUT` programan una reconexión con espera creciente y techo de 30 s. Insistir cada segundo no levanta un servicio caído y sí gasta batería y datos del admin.
- Al reconectar **se recarga**, siempre. Los eventos perdidos no se reenvían: la única forma de ponerse al día es preguntar.
- `visibilitychange` y `online` recargan y rehacen el canal. **No se comprueba antes si el canal seguía vivo**: comprobarlo exigiría leer un estado interno de la librería, y equivocarse ahí deja al admin mirando una foto. Una consulta de más no le cuesta nada a nadie; una solicitud de retiro que el admin no ve, sí.
- Cada aviso comprueba que su canal **sigue siendo el vigente** (`if (canal !== c) return`). Sin eso, el `CLOSED` del canal viejo puede llegar después de haber abierto el nuevo, tirarlo, y repetir — una pantalla que se desconecta sola cada pocos segundos, que para quien la mira es lo mismo que no funcionar.
- Una bandera `cerrandoAProposito` evita que nuestro propio `removeChannel` se interprete como una caída.

**Consecuencias.**
- Vale para los cuatro canales a la vez: las pujas y los remates usan el mismo hook. Ese `remate:*` que «funcionaba bien» tenía exactamente el mismo agujero; no se notaba porque esas pantallas se miran de frente, no se dejan de fondo.
- La consola sigue registrando **todo** estado, no solo los fallos, y ahora también el motivo y la espera de cada reintento.
- Lo que no se arregla aquí: un remate **nuevo** sigue sin avisar, porque `avisar_remate` es `after update on remates` y un alta es un INSERT. Es otro defecto, de la base, y necesita un canal de lista.

**La regla.** Una suscripción en tiempo real no es «suscribirse». Es suscribirse, **darse cuenta de que se cayó**, volver a levantarla, y **recargar al volver**. Las tres últimas son el trabajo; la primera es la parte fácil, y es la única que estaba escrita.

**Qué lo revertiría.** Que la librería del cliente garantice la reconexión y el relleno de huecos por su cuenta. Hoy reconecta el socket, pero el canal privado que se cayó no vuelve solo, y ningún evento perdido se reenvía.

---

## ADR-026 · El aviso vive en el panel, no dentro de la pantalla que avisa

**Fecha.** 05/10/2026

**Contexto.** Jota, después de dos turnos míos midiendo el realtime:

> *«La idea es que cuando alguien solicite recarga o retiro, al admin le aparezca la notificación en tiempo real **sin importar la pantalla** de la app en la que esté, porque si el realtime funciona solamente dentro de /recargas - /retiros, entonces eso es prácticamente como que no existiera ningún realtime.»*

Tenía razón, y el código lo confirma sin margen: de once pantallas de `/admin`, **exactamente dos** se suscribían a `admin:caja`, y eran las dos de gestión. `/admin` —el panel con los contadores de pendientes, que es donde un admin se queda esperando— no se suscribía a nada. Sus dos números se leían al montar la página y ahí se quedaban.

**El error de método, que es mío.** Diseñé la prueba parándome dentro de `/admin/retiros`, que resulta ser el único sitio donde el mecanismo existía. La prueba pasaba y el producto seguía roto. Es el mismo defecto que ADR-022 y ADR-025 en una tercera cara: **un instrumento que mide donde no está el problema**. Y es peor que los otros dos, porque allí el instrumento mentía solo; aquí lo apunté yo.

Jota recordaba que «creo recordar que se movía» estando en ese panel. Es muy posible y no es contradictorio: al **entrar** en `/admin` desde otra pantalla, el `load` del montaje vuelve a contar. Visto desde fuera parece que el número se actualizó solo.

**Decisión.** Un `app/admin/layout.tsx` que envuelve todo `/admin/*` y monta `CajaEnVivo`:

- **UNA sola suscripción a `admin:caja` por sesión de navegador**, no una por pantalla. Dos canales con el mismo tópico son dos uniones al mismo sitio: ruido en el servidor y dos fuentes de la misma verdad en el cliente.
- Un layout de Next.js **no se vuelve a montar al navegar** entre las rutas que cubre, así que el canal sobrevive a los saltos: del panel a contabilidad y de ahí al registro sin reconectar el socket ni perder el aviso.
- Los **contadores viven ahí**, y el panel los consume del contexto. No puede haber una barra diciendo 2 y un panel diciendo 0, porque es el mismo número. Contar también en la pantalla habría sido el ADR-015 en pequeño: dos implementaciones de lo mismo que acaban discrepando.
- El contexto expone `version`, que sube con cada señal. Cualquier pantalla que quiera recargarse pone un efecto sobre `version`. Nadie vuelve a suscribir nada.
- Barra fija arriba, visible desde cualquier pantalla del panel, con el número y el enlace. Se destaca en ámbar con un `NUEVO` durante seis segundos **solo cuando el número sube**, y nunca en la primera lectura: abrir el panel con tres pendientes de ayer no es una novedad.
- En `/admin/login` no hace nada. No hay a quien avisar, y una consulta sin sesión solo llena la consola de errores.

**Consecuencias.**
- `/admin/recargas` y `/admin/retiros` dejan de suscribirse por su cuenta y reaccionan a `version`. Menos código y una sola fuente.
- La reconexión y la recarga al volver al frente las sigue dando `useSenal` (ADR-025), ahora para todo el panel de una vez.
- Lo que **no** cubre: si el admin cierra el navegador, no hay aviso. Eso es notificación fuera de la aplicación —correo, WhatsApp, Telegram— y sigue pendiente. Esta barra resuelve «estoy en la app pero en otra pantalla», que era el caso real.

**La regla.** Un aviso que solo existe en la pantalla que lo muestra no es un aviso: es un detalle de esa pantalla. Si tiene que llegar «estés donde estés», vive por encima de las pantallas.

**Qué lo revertiría.** Que el panel deje de ser una sola aplicación de cliente —por ejemplo, si la administración se partiera en aplicaciones separadas—. Entonces el canal volvería a necesitar un dueño por aplicación, no por pantalla.

---

## ADR-027 · Un admin no es una casilla booleana: es una persona con nombre

**Fecha.** 05/10/2026

**Contexto.** Jota abrió el registro recién hecho y vio que **todas** las filas decían «Super Admin». No es estética: con un único usuario administrador, `admin_actions` puede decir *qué pasó* pero no *quién lo hizo* — que es literalmente para lo que existe una bitácora.

Y para alquilar la aplicación es peor. El licenciatario va a tener dos o tres personas en caja. Si comparten cuenta, el día que falte dinero no hay forma de saber de quién fue la mano, y ahí el software deja de protegerlo: justo lo que se le está vendiendo.

**Decisión 1: se promueve, no se crea.** La persona se registra como cualquier jugador y un super admin la promueve. La alternativa —una Edge Function con `service_role` que cree el usuario de una vez— es más cómoda y se descartó: obliga a tener esa clave configurada en **cada** instalación de licenciatario, y esa clave es acceso total por encima de toda la RLS. Un secreto que se reparte N veces se filtra una vez. El camino elegido no necesita ningún secreto nuevo: cuatro RPC `security definer` con guarda de super admin, todas auditadas.

**Decisión 2: el código lo escribe una persona.** De 2 a 6 caracteres. `JOTA` o `C01` le dicen algo a quien lee el registro tres meses después; `X7K` generado al azar, no.

**Decisión 3: un código no se reutiliza nunca.** `quitar_admin` baja las banderas pero **conserva código y nombre**. Si se reciclara, las filas viejas del registro pasarían a apuntar a otra persona — y una bitácora que cambia de versión del pasado no vale nada.

**Decisión 4: la bitácora guarda una foto, no una referencia.** `admin_actions` copia código y nombre tal como estaban en el momento. Si alguien cambia de apellido o se le corrige el código, lo que pasó en marzo se sigue leyendo como se leía en marzo. Mismo criterio que `motivo_etiqueta` el 01/10, y por la misma razón.

**Dos guardas que no son burocracia.** Nadie se quita el cargo a sí mismo —un clic deja al licenciatario fuera de su propio panel sin nadie que se lo devuelva— y siempre tiene que quedar un super admin.

**Una guarda que resultó inalcanzable, y se queda.** La del «último super admin» no puede dispararse desde la aplicación: para que salte, el que sobra tiene que ser el único super admin, y entonces quien llama solo puede ser él mismo, a quien ya para la primera guarda. **P59 no la mide a propósito**: una prueba para una rama inalcanzable aprobaría por el motivo equivocado, que es lo que P39 enseñó a no hacer. La guarda se queda en la base como segunda línea: el día que alguien relaje la primera, esa es la que impide dejar la instalación sin dueño.

**Lo que cazó ejecutarlo, y no se habría visto leyendo.** `returns table (... es_super_admin boolean ...)` convierte esos nombres en **variables** de plpgsql, y a partir de ahí un `select es_super_admin from public.profiles` sin cualificar es ambiguo (42702). Dos de las cuatro funciones abortaban. Se corrigió poniendo alias de tabla en las cuatro, incluidas las dos que no lo necesitaban: una regla que se aplica a veces es una regla que se olvida.

**Consecuencias.** `P59` mide las seis cosas. El registro muestra `C01 · María Pérez` y cae al perfil solo para las filas anteriores a esta migración. La pantalla `/admin/super/admins` avisa en ámbar si hay un admin sin código — que es el estado del super admin original hasta que se ponga el suyo.

---

## ADR-028 · Quien pide y quien autoriza no pueden ser la misma persona

**Fecha.** 05/10/2026

**Contexto.** Preparando lo anterior encontré que `aprobar_recarga`, `rechazar_recarga` y `procesar_retiro` solo comprobaban que quien llama fuera admin. **De quién era la solicitud no preguntaban.**

Con un único administrador —que además es el dueño— da igual: aprobarse una recarga es moverse dinero de un bolsillo al otro. En cuanto hay dos, es la vía de fraude más corta que tiene la aplicación:

1. el admin pide una recarga de 50.000 para su propia cuenta
2. el admin se la aprueba
3. el saldo es real: puja, gana, o pide el retiro y se lo paga él mismo

Tres clics, sin tocar la base y sin saber SQL, dejando en la bitácora una secuencia que parece normal salvo que alguien se fije en que el que aprueba y el que cobra son el mismo.

**Decisión.** Las tres funciones rechazan la solicitud propia. Va **en el mismo bloque** que la identidad de los admins: entregar la posibilidad de tener varios administradores sin esta guarda sería abrir la puerta y dejar la llave puesta.

Es separación de funciones, no desconfianza. Lo cumple cualquier caja del mundo, y ninguna lo hace porque sus empleados sean ladrones: lo hace para que nadie quede bajo sospecha cuando falta dinero.

**Lo que no impide, y hay que verlo escrito.** Dos admins compinchados se aprueban el uno al otro. Contra eso el software no puede hacer nada y no se pretende. Lo que sí consigue es que la bitácora diga con nombre y código quién autorizó cada cosa.

**UN HALLAZGO QUE SALE DE AQUÍ Y QUE HAY QUE DECIDIR APARTE.**

`aprobar_recarga` tiene un `exception when others → log_admin_action(..., success := false) → raise`. La intención es registrar los intentos fallidos. **No registra nada.** Lo comprobé ejecutándolo: al re-lanzar la excepción, PostgreSQL aborta la transacción entera y se lleva por delante el propio asiento de auditoría. Resultado: **`admin_actions` no puede contener ni una sola fila con `success = false`.** Cero, medido.

Dos consecuencias:

- El filtro «solo las que fallaron» del registro (ADR-023) devuelve siempre vacío. Es un instrumento que da una tranquilidad falsa: «no hay fallos» cuando en realidad es «no se pueden ver».
- Un admin puede intentar veinte veces algo que no le corresponde y no queda rastro.

No se arregla aquí porque la solución no es obvia. PostgreSQL no tiene transacciones autónomas; las salidas son `dblink` —descartado por ADR-020— o que el frontend, al capturar el error de la RPC, llame a una RPC aparte que registre el intento. Esa segunda transacción sí persiste, pero el dato lo aporta el cliente, así que sirve como ayuda de auditoría y no como control. **Es una decisión de Jota, no mía.**

**Consecuencias.** `P60` mide las tres puertas y, sobre todo, que **otro** admin sí pueda: un candado que bloquea la operación normal se acaba quitando.

---

## ADR-029 · Las condiciones que acepta el jugador no se escriben en el HTML

**Fecha.** 05/10/2026

**Contexto.** Fui a añadir la regla del 50% a `/reglas` y me encontré con que esa página describía un modelo de dinero que la base había dejado de implementar. Comprobado contra las migraciones, punto por punto:

| decía | la realidad, desde |
|---|---|
| «cada puja bloquea saldo» | **no.** 24/09, `puja_sin_bloqueo` |
| «tu saldo no se libera hasta el cierre» | no hay nada que liberar |
| «manual mínimo = auto mínimo + 10 Bs» | **no.** 23/09, `reglas_primera_puja` |
| «la casa retiene 25%» | es `porcentaje_casa`, por remate |
| «incrementos por rangos por defecto» | **no.** 30/09, escalera solo por caballo |
| *(nada sobre la regla del 50%)* | **sí se aplica**, desde el 01/10 |

Lo último era lo peor: la base aplicaba una condición que la página no mencionaba, así que el jugador se enteraba **al intentar retirar**. El peor momento posible para leer una condición.

**La causa no fue descuido, fue el formato.** Un número escrito en el HTML no tiene forma de enterarse de que la base cambió. Cada migración que toca una regla deja esa página un poco más falsa, y nadie lo nota porque nada falla.

**Decisión 1: los números se leen de la base.** `ajustes_publicos()` devuelve una **lista blanca** sobre `ajustes_instalacion`. Un licenciatario que ponga el porcentaje en 30 tiene esta página diciendo 30, sin tocar código.

**Decisión 2: una lista blanca, no un `GRANT ... TO anon`.** `ajustes_instalacion` está cerrada a `anon` a propósito, y va a crecer: en el bloque de licencias le entran datos bancarios, SMTP y la marca. Abrir la tabla entera para que una página pública lea un porcentaje sería dejar la puerta abierta a todo lo que llegue después. Lo que no esté nombrado dentro de la función no sale, aunque alguien lo añada a la tabla mañana. **Es la diferencia entre una puerta y una ventanilla.**

**Decisión 3: si no se puede leer, no se inventa.** Cuando `ajustes_publicos()` falla, el apartado afectado dice que no se pudo cargar y que pregunten antes de recargar. Una página de condiciones que rellena huecos con suposiciones es peor que una que admite que le falta un dato.

**Consecuencias.** `P63` comprueba tres cosas: que responde **sin sesión** —las reglas se leen antes de abrir la cuenta—, que trae el porcentaje, y que **NO** devuelve una clave que no esté en la lista. Esa tercera existe para el día que alguien meta el SMTP en esa tabla: se pone en rojo antes de que la clave salga por la página pública.

La página reescrita dice explícitamente lo que más se malentiende: **pujar no descuenta saldo**, el cobro es al cerrar y solo por lo que te quedaste, y al que pierde nunca se le quitó nada.

---

## ADR-030 · Un aviso que se emite y se pierde no es un aviso

**Fecha.** 05/10/2026

**Contexto.** Jota, liquidando un remate el 02/10: *«aquí tiene que salir un popup avisando al ganador, tanto si está en línea como si no estaba e inició sesión»*.

Esas dos mitades deciden el diseño entero:

- *«si está en línea»* → hace falta una señal en tiempo real.
- *«si inició sesión»* → hace falta que el aviso **persista** y sepa si ya se leyó.

**La segunda es la que manda.** Un toast que se emite y se pierde no sirve: el ganador puede estar durmiendo cuando se liquida su remate.

**Decisión: una tabla de notificaciones, no un popup de premio.** La lista de pendientes ya tiene cuatro avisos más esperando —recarga aprobada, recarga rechazada con su motivo, retiro procesado, remate nuevo— y todos tienen exactamente esta forma: un usuario, un texto, una referencia, y si ya lo vio o no. Construir el del premio a medida y rehacerlo como notificaciones dentro de dos semanas es trabajo tirado dos veces. **Añadir cada uno de los otros es ahora una línea.**

**Un canal privado por usuario**, `usuario:<uuid>`, con la política comparando el tópico contra `auth.uid()`. No hace falta confiar en el cliente: puede pedir suscribirse al canal de otro, y la base no le entrega nada.

**La señal no lleva el texto.** Dice «tienes algo nuevo» y la pantalla vuelve a preguntar. ADR-015: si el mensaje viajara en el evento, viviría en dos sitios.

**El popup va en el layout raíz**, no dentro de una pantalla — ADR-026 aplicado antes de volver a tropezar. Cubre la aplicación entera y sobrevive a la navegación. Sin sesión no consulta, no se suscribe y no pinta.

**Un aviso perdido no puede tumbar una liquidación.** `_notificar` se traga sus propios errores, como `_avisar`. Y se lo puede permitir: cuando corre, el premio ya está en el saldo y en `wallet_movements`. **El registro de verdad es ese; esto es la cortesía de avisar.** Lo mismo al revés en la pantalla: si falla marcar como leído, el aviso se queda. Verlo dos veces es mejor que perderlo.

**Consecuencias.** `P61` mide que liquidar con ganador usuario deja una fila sin leer con el importe del premio, que el perdedor no recibe nada, que **otro usuario no puede marcarla** y que el dueño sí.

Su primera versión ponía `v_ajeno_no_marca := true` a mano, sin ejecutar nada. Eso no es una prueba, es una afirmación — y la habría entregado en verde.

---

## ADR-031 · Para enterarse de que algo apareció hace falta un canal de la colección

**Fecha.** 05/10/2026

**Contexto.** *«Los remates nuevos no le aparecen a los clientes a menos que actualice»*, reportado el 01/10. La causa inmediata es de una línea: `avisar_remate` es `after update on remates`, y **un alta es un INSERT**.

Pero arreglar el trigger no habría servido, y eso es lo que importa: emite al canal `remate:<id>`, y **nadie puede estar suscrito al canal de un remate que todavía no existe**. No era un disparador mal puesto: faltaba el canal.

**La regla general:** un canal por objeto sirve para **seguir** un objeto que ya tienes delante. Para enterarte de que **apareció** uno nuevo hace falta un canal de la colección. Son dos necesidades distintas y ninguna sustituye a la otra.

**Decisión.** `remates:lista`, público —la lista de remates abiertos es la portada—, con **dos disparadores y una sola función** detrás.

Dos y no uno porque la cláusula `WHEN` de un trigger no puede mirar `OLD` en un INSERT ni consultar `TG_OP`: «siempre al insertar, y al actualizar solo si cambió algo que se ve en la lista» no cabe en un disparador. Y el `WHEN` no es pulcritud: sin él, cada `closed_at` o cada marca interna despertaría a todos los navegadores conectados.

**Consecuencias.** `P62` mide las tres cosas, y la tercera es la que impide que el arreglo sea peor que el problema: el alta emite, un cambio de estado emite, y **tocar una columna que la lista no muestra NO emite**.

La pantalla pública recarga en silencio: solo la primera carga enseña «Cargando remates...». Una recarga disparada por una señal no puede dejar en blanco una lista que el usuario está mirando.

---

## ADR-032 · El menú de cliente vive en el layout, y la regla es una sola

**Fecha.** 06/10/2026

**Contexto.** `ClientBottomNav` estaba importado a mano en **seis** pantallas, con **tres** condiciones distintas:

| pantalla | condición |
|---|---|
| `/contactanos` | siempre |
| `/dashboard` y sus dos hijas | si hay sesión |
| `/remates` y `/remates/[id]` | si hay sesión **y no es admin** |

Las consecuencias no eran teóricas. `/reglas` —la página que el jugador abre justo antes de poner dinero— **no lo tenía**: entraba a leer las condiciones y se quedaba sin menú. Cualquier pantalla nueva nacía sin él y nadie se enteraba. Y la regla de «los admins no lo ven» se aplicaba en dos pantallas de seis, que es lo mismo que no tener regla.

**Es el tercer caso de la misma forma esta semana**, y por eso merece quedar escrito como patrón y no como arreglo: el aviso de caja (ADR-026), el popup de avisos al usuario (ADR-030) y ahora el menú. Los tres empezaron pegados dentro de pantallas concretas; los tres tenían que estar por encima.

**Decisión.** Un `NavegacionCliente` en el layout raíz que decide él solo si toca pintarse: **rutas de cliente, con sesión iniciada**.

**Los admins también lo ven.** Tienen cartera y pueden recargar y retirar como cualquiera. Era ya el comportamiento de cuatro de las seis pantallas, así que esto unifica hacia donde estaba la mayoría en vez de inventar una regla nueva.

**Las rutas se declaran por lo que NO son** — `/admin`, `/login`, `/register`, `/auth`, `/api`, y la portada. Una lista blanca habría que ampliarla con cada pantalla nueva, y la siguiente volvería a nacer sin menú: exactamente el defecto que se está cerrando. La lista negra es corta y estable.

**El hueco lo pone el propio componente.** La barra es `fixed` y no ocupa sitio en el flujo; antes cada pantalla se acordaba de poner `pb-24`. Ahora el componente pinta la barra y su espaciador juntos: una pantalla nueva que se olvide del padding ya no acaba con el último botón tapado.

**Consecuencias.** Seis importaciones y siete usos menos, los `pb-24` fuera, y `/reglas` con menú por primera vez. La regla de quién lo ve está escrita en un sitio y se lee en diez segundos.

**Y una predicción de ayer que se cumplió.** ADR-030 decía que, con la tabla de notificaciones hecha, añadir los avisos que faltaban sería «una línea cada uno». Lo fue: cuatro llamadas a `_notificar` —recarga aprobada, recarga rechazada con su motivo, retiro pagado, retiro rechazado— en la migración `20261006100000`, sin tocar nada más. `P64` comprueba que existen **y** que los textos dicen lo que tienen que decir: una prueba que solo contara filas pasaría con los mensajes vacíos.

---

## ADR-033 · La casa no juega, y eso incluye la cartera

**Fecha.** 5 de octubre de 2026, 22:40 hora de Caracas *(el archivo de la migración va numerado `20261006110000`; ver la nota del final)*

**Contexto.** Jota preguntó, sobre el menú que acababa de unificar: *«no entendí muy bien lo de que al admin le saldrá para recargar/retirar, ¿eso no lo habíamos quitado cuando quitamos también lo de que podía pujar en un remate?»*

Tenía razón, y la pregunta destapó bastante más que una decisión de interfaz.

**Lo que encontré al comprobarlo.** La regla «los admins no participan en remates» vivía en la base desde el 30/09, pero **solo en `hacer_puja`**. Ni `solicitar_recarga` ni `solicitar_retiro` miraban el rol.

Hasta ayer eso era raro pero inofensivo. Con la separación de funciones del ADR-028 —nadie procesa su propia solicitud— se convirtió en una trampa sin salida:

1. el admin pide un retiro
2. `solicitar_retiro` **le descuenta el saldo en el acto**
3. nadie puede procesarlo: él mismo no, por el ADR-028; y si es el único admin de la instalación, no hay nadie más
4. la solicitud queda pendiente **para siempre**, con el dinero descontado, y `casa_resumen` la cuenta como obligación de la casa a perpetuidad

**Lo introduje yo ayer y no lo vi.** El ADR-028 cerró una puerta sin comprobar quién estaba dentro de la habitación. Y no lo encontró ninguna prueba: lo encontró una pregunta sobre un menú.

**Decisión.** Un administrador no puede pedir recargas ni retiros. Es la regla que ya estaba escrita para las pujas, extendida a donde faltaba: **el administrador es el operador del sistema, no un usuario con saldo.**

**La salida para quien ya tenía dinero.** Un jugador con saldo al que ascienden a admin no puede sacarlo. No se anula ni se mueve nada —mismo criterio que `20260930110000` con las pujas viejas: tocar dinero ya comprometido por un cambio de rol es peor que el problema—. Lo que se hace es **decirlo en el propio mensaje de error**: que un super admin le retire el cargo, haga la operación, y se lo devuelva. El código queda reservado (ADR-027), así que recupera su misma identidad en el registro.

**Y la corrección del ADR-032.** Allí decidí que los admins vieran el menú de cliente, argumentando que «tienen cartera como cualquiera» y que eso unificaba hacia el comportamiento de cuatro de las seis pantallas. Las dos cosas estaban mal: la casa no juega, y **unificar hacia la mayoría era mal criterio** — cuatro pantallas hacían una cosa y dos hacían la correcta. Peor: le ofrecía a un admin dos botones que la base ahora le rechaza. Los admins no ven el menú de cliente.

**Consecuencias.**
- `P65` mide las tres cosas, y la tercera es la que importa: **que un usuario normal sí pueda**. Una guarda que además bloquea la operación legítima no es una guarda, es una avería.
- `P60` hubo que reconstruirla, y el escenario nuevo es mejor: su admin ahora **pide siendo jugador y lo ascienden después**, que es el único camino por el que un admin puede tener una solicitud propia. Más realista que el anterior, no menos.
- La lección: **al cerrar una puerta, comprobar quién queda encerrado.** Es el ADR-018 —antes de cerrar una puerta, buscar quién la usa— aplicado al revés y aprendido dos semanas después.

**Sobre el número del archivo.** El prefijo de una migración es una **clave de orden**, no una fecha: lo único que la base exige es que sea creciente. Yo trabajo en UTC y Jota en Colombia (UTC−5), con la aplicación en hora de Caracas (UTC−4), así que a partir de las 19:00 suyas yo ya estoy en el día siguiente. La migración anterior salió numerada `20261006` cuando allí todavía era 5. **No se renumera** —ya está aplicada en producción y renombrarla descuadraría `schema_migrations`— y de aquí en adelante la fecha real va escrita en la cabecera, en hora de Caracas.

---

## ADR-034 · Un aviso que se dispara de más destruye el valor de los que importan

**Fecha.** 5 de octubre de 2026, 23:10 hora de Caracas *(migración `20261006120000`)*

**Contexto.** Jota, probando el modal de confirmación: *«el detalle: no avisó en la cuenta cliente cuando lo creé»*. El remate aparecía solo en la lista —eso ya funcionaba desde el canal de la colección (ADR-031)— pero no había ningún aviso.

La maquinaria para avisar existe desde el ADR-030 y añadir uno más es una línea. La pregunta era si debía ser un popup.

**Decisión: indicador discreto, no popup.** El popup es para lo que te pasa **a ti** —ganaste un premio, te aprobaron la recarga, te rechazaron un retiro—. Un remate nuevo no es personal: es un anuncio, y los anuncios no interrumpen.

Pero el argumento que decide es el flujo real que Jota describió el 01/10: *«un admin debería ponerse a crear todas las carreras del sábado y domingo el martes noche»*. Con un popup por remate, eso son **doce ventanas seguidas**. Y el jugador que aprende a cerrar ventanas sin leerlas cierra también, sin leer, la que le dice que ganó un premio.

**Un aviso que se dispara de más no es ruido inofensivo: devalúa a los demás.** Es la misma lección del ADR-022 —la alarma de contabilidad que saltaba cuando no pasaba nada— en el lado del jugador.

**Cómo se sabe qué es nuevo: una marca por usuario**, `profiles.remates_vistos_at`. Todo remate abierto creado después es nuevo para él; abrir la lista mueve la marca.

Se eligió una marca y no una tabla `remates_vistos (user_id, remate_id)`: la tabla sabría cuáles abrió uno por uno, a cambio de una fila por jugador y por remate, para responder una pregunta que nadie hace. Lo que el jugador quiere saber es *«qué hay desde la última vez que miré»*, y eso es una fecha.

**Y va en la base, no en `localStorage`.** Habría salido gratis, pero quien mira en el teléfono y luego en la computadora vería los mismos remates marcados como nuevos otra vez. La marca es del usuario, no del aparato.

**La marca nace puesta, y eso no es un detalle.** La primera versión la dejaba nula para quien nunca había mirado, y eso obligaba a elegir entre dos respuestas, las dos malas: *nulo = todo es nuevo* llena la pantalla del recién llegado de etiquetas y le enseña a ignorarlas; *nulo = nada es nuevo* deja sin aviso para siempre a quien se registró y no abrió la lista, justo el que habría que atraer. Con `not null default now()` el caso no existe.

**Una sola suscripción para los tres consumidores.** La lista pública, el contador del menú y la lista del admin necesitan el mismo canal. `RematesEnVivo` en el layout raíz lo escucha una vez y reparte `version`; tres suscripciones al mismo tópico serían tres canales y tres versiones de la misma verdad. ADR-026 aplicado antes de repetir el error.

**Consecuencias.** `P66` mide que lo anterior a tu marca no cuenta, que el contador es **por usuario** —una prueba que mirara a uno solo pasaría aunque la marca fuera global— y que mirar lo pone a cero.

**Y una trampa que mordió por tercera vez.** `now()` en PostgreSQL es la hora de la **transacción**, no del reloj: dentro de un `do $$` todo comparte instante, así que un remate creado «después» de marcar tiene el mismo `created_at` que la marca y `>` da falso. Dormir no arregla nada porque la hora no avanza. Ya había pasado en P56 el 01/10 y en P61 anteayer. **La forma de escribir una prueba que dependa del orden temporal es mover las marcas explícitamente, nunca esperar a que pase el tiempo.**

---

## ADR-035 · El precio se dice antes de cobrarlo, no después

**Fecha.** 7 de octubre de 2026 *(solo frontend: `app/components/ConfirmarPuja.tsx`, `app/remates/[id]/page.tsx`, `tests/aviso_puja.mjs`)*

**Contexto.** Jota, sobre el aviso del incremento: *«ahí el usuario decide si puja con el incremento o lo deja ahí»*. El aviso existía, pero llegaba tarde.

Lo que había: el botón decía **«Ponerle»**, sin cifra. El jugador leía «Va ganando 1.500 Bs», apretaba, y quedaba comprometido con 1.650 Bs sin que nadie le hubiera dicho nunca ese número. El único sitio donde aparecía era un renglón gris de 11 px rotulado *«Puja manual mínima»*, debajo del campo de monto manual: se lee como la etiqueta de ese campo, no como el precio del botón de al lado. Y si el monto escrito a mano no llegaba al mínimo, el aviso salía **después** de apretar, como error rojo arriba de la pantalla.

Peor: `app/reglas/page.tsx` ya prometía, textual, que *«el mínimo siguiente siempre está a la vista antes de pujar»*. La pantalla no cumplía su propia letra pequeña.

**Decisión.** Tres cambios, ninguno en la base:

1. **El botón dice el precio.** «Ponerle / 1.650,00 Bs» en dos líneas.
2. **Un cuadro de confirmación que enseña la cuenta**, no que pregunta «¿estás seguro?»: precio actual y quién va ganando, incremento, total, y cómo queda el saldo después. Los botones son «Pujar 1.650,00 Bs» y **«Dejarlo así»** —las palabras de Jota.
3. **El problema del monto manual se dice mientras se escribe**, en rojo bajo el campo, con el botón desactivado. Nunca después del intento.

**Lo que no se toca: la regla sigue siendo de la base.** Cada cifra del cuadro llega de `remate_minimos()`. La única aritmética del frontend es sumar lo que la base ya dijo para enseñar el saldo resultante (ADR-008, ADR-015).

**El cuadro no guarda las cifras, las deriva.** Primera versión: el estado guardaba precio e incremento al abrirse, y un `useEffect` los corregía cuando llegaba señal. Mal por dos motivos. Uno de estilo —`setState` dentro de un efecto, que el propio linter de React marca—. El otro de fondo: **en la puja automática `hacer_puja` ignora el monto que manda la pantalla** y cobra `v_minimo_permitido`, el mínimo que exista en ese instante. Un cuadro con cifras congeladas haría que el jugador confirme 1.650 y le cobren 1.800. Ahora el estado guarda **solo la intención** (qué caballo, cuánto quiso ofrecer, si fue manual) y el cuadro se recalcula de `minimos` en cada pintada: si alguien pujó mientras miraba, las cifras se corrigen solas y el cuadro lo dice.

**La aritmética va en céntimos enteros.** En la base el dinero es `numeric(12,2)`, exacto. En JavaScript son dobles: `1,10 + 2,20` da `3,3000000000000003`, así que con 3,30 de saldo justo la comprobación `saldo < comprometido + puja` daba **«Saldo insuficiente»** y botón desactivado a alguien a quien la base se lo habría aceptado. Y el «te faltan» salía `-0,00 Bs`. Pasar a céntimos antes de sumar hace que esta cuenta sea la misma que la de la base, al céntimo. **No era un error teórico: la resta a mano que vivía en `placeBid` lo tenía desde el primer día** y ahora usa la misma función que el cuadro.

**Una sola implementación del formulario.** Móvil y escritorio tenían **dos copias** del input, el botón y el renglón de ayuda. El ADR-015 habla de DB contra frontend, pero la lección es la misma dentro de un archivo: ahora el bloque de acción se construye una vez y las dos maquetas lo pintan.

**Consecuencias.** `tests/aviso_puja.mjs`, 31 comprobaciones (`pnpm test:aviso`), que transpila los archivos reales y ejecuta sus funciones —sin copias, mismo método que `tests/fechas.mjs`—. Cubre el caso que no se ve mirando: **el jugador que ya lidera el caballo**, donde subir la propia puja la *reemplaza* y no la suma. Ese error ya se cometió aquí una vez (defecto R4: se restaba la puja más alta histórica en vez de la que lidera ahora) y ahora hay una prueba que falla si vuelve.

---

## ADR-036 · Crear un remate es una transacción, o no es nada

**Fecha.** 7 de octubre de 2026 *(migración `20261007130000`)*

**Contexto.** Crear un remate eran **cinco llamadas** desde el navegador, cada una su propia transacción ya confirmada: `races`, `remates`, `horses`, un `select` para recuperar los ids, y `remate_price_rules`. El `catch` del formulario hacía exactamente una cosa: `setError(...)`. Ni un `delete`, ni un intento de limpieza.

Medido en el arnés, con el admin repitiendo el número 5:

```
 carrera_huerfana | remate_huerfano | estado  | caballos | senales_a_los_jugadores
------------------+-----------------+---------+----------+-------------------------
                1 |               1 | abierto |        0 |                       1
```

**La restricción de la base no es la víctima: es el gatillo.** `horses_race_id_numero_key UNIQUE (race_id, numero)` viene en el baseline, línea 2050, y rechaza el duplicado con 23505 — correctamente. Lo que faltaba era que ese rechazo ocurriera **dentro** de una transacción. Y desde el ADR-031 el remate roto no se queda esperando a que alguien lo encuentre: la señal ya salió a la lista de todos los jugadores conectados.

**La segunda víctima, que no se ve.** Entre el insert de caballos y el de reglas el remate ya está abierto y los caballos existen, pero **las escaleras todavía no**. Un jugador que puje en esos milisegundos recibe `remates.incremento_minimo` en vez de la escalera configurada. Dentro de una transacción es imposible: en READ COMMITTED nadie ve filas sin confirmar.

**Decisión: `crear_remate_completo(jsonb, jsonb, jsonb)`.** Una función PL/pgSQL es una transacción, así que **no hay que escribir ningún rollback**: lo da el motor. Tres `jsonb` porque las escaleras cuelgan de su caballo y eso no se aplana sin mentir. El `select` para recuperar los ids desaparece: dentro se usa `insert ... returning`.

**No añade ni una regla de negocio.** Los `NOT NULL`, la restricción de números repetidos y los tres disparadores de mínimos ya estaban; lo único que cambia es **cuándo** se aplican. Lo que sí pone, dicho en voz alta en la cabecera del archivo: un remate sin caballos se rechaza —el esquema lo permitía y es justo la basura que esto viene a impedir— y el `23505` se traduce a una frase que el admin entienda.

**Un error mío que vale documentar.** Propuse llevar la validación de números repetidos «del formulario a la base» y Jota dio luz verde sobre esa premisa. **Era falsa**: ya estaba en la base desde el primer día, y el propio `crear-remate/page.tsx` lo decía en un comentario. Lo afirmé sin ejecutarlo. La luz verde se corrigió antes de escribir nada.

**Consecuencias.** `P67`, seis fases: el camino bueno escribe las cuatro tablas y cuelga cada escalera de su caballo; una guarda, un `NOT NULL`, un número repetido, cero caballos o un jugador rechazan **sin dejar nada** —`basura=0` y `senal=0`—. Queda fuera a propósito el estado del remate con `opens_at` futuro y la clave de idempotencia: un doble clic sigue creando dos remates, igual que antes.

---

## ADR-037 · Las escaleras se reemplazan de una vez, y la tabla se cierra

**Fecha.** 7 de octubre de 2026 *(migración `20261007150000`)*

**Contexto.** La pantalla de editar guardaba las escaleras con un `delete` de todas las del remate y un `insert` de las nuevas, **en dos llamadas sueltas**. Entre las dos, el remate no tenía ninguna escalera: en vivo, y con dinero ya comprometido.

**Lo peor no era la pérdida.** Si se interrumpía ahí, el admin leía «Error guardando cambios» y deducía que no se había tocado nada, cuando el borrado ya estaba hecho. Un fallo que miente sobre su propio alcance.

**Lo que NO era: un problema de dinero.** El monto que se cobra siempre es el que la pantalla mostró, porque `remate_minimos()` y `hacer_puja` leen el mismo `_incremento_aplicable`. Nadie paga un número distinto del que vio y el descuadre sigue en cero. El daño es comercial: la subasta avanza con incrementos que no son los anunciados.

**Decisión: `guardar_escaleras(uuid, jsonb)`** — el borrado y la inserción en una transacción. Se eligió **esto y no el `guardar_remate_completo` entero** porque cierra la única ventana que falla *en silencio* con un cambio de 30 líneas, en vez de reescribir el guardado de una pantalla que funciona. El resto de ese guardado siguen siendo 16 o 17 escrituras sueltas, una por caballo.

**Tres cosas que la función pone y no son «arreglar la transacción»**, dichas en voz alta para que nadie las descubra leyendo el cuerpo: una escalera solo puede ser de un caballo **de esta carrera** —la FK ataba `horse_id` a `horses`, pero nada al remate, y como esta función pasa a ser la puerta, sin eso el agujero lo abriría ella—; un candado por remate, porque sin él dos admins guardando a la vez mezclan las dos escaleras; y asiento en la bitácora, que las escrituras directas no podían dejar.

**Y se cierra la puerta de atrás.** `remate_price_rules` baja a **solo lectura** para `authenticated`: crear pasa por `crear_remate_completo` y editar por `guardar_escaleras`, las dos `security definer`. Es la primera de las cuatro tablas del catálogo que se cierra; `races`, `horses` y `support_settings` siguen abiertas porque la pantalla de editar todavía las escribe. P48 lo declara, así que el día que alguien vuelva a poner un `.insert()` directo **dejará de funcionar en vez de funcionar a medias**.

**El beneficio de seguridad es menor de lo que parece, y conviene decirlo:** las políticas RLS ya exigían `is_admin()` para escribir esas tablas. Ningún jugador podía colarse. Lo que se gana es que ni siquiera un admin pueda escribirlas sin dejar rastro.

**Consecuencias.** `P68`, seis fases. La que importa: cuando una escalera nueva no pasa una guarda, **las viejas siguen ahí** (`quedan=2`). Si el borrado no se deshiciera, ese número sería 0.

---

## ADR-038 · Una bitácora que anuncia lo que no pasó enseña a no leerla

**Fecha.** 7 de octubre de 2026 *(migración `20261007170000`)*

**Contexto.** Jota, mirando `/admin/log` el mismo día:

```
1:11:31  Guardar escaleras   Tramos ahora: 0 | Tramos antes: 0
1:11:31  Remate editado      Incremento: 50 → 150
1:09:23  Guardar escaleras   Tramos ahora: 0 | Tramos antes: 5
1:09:22  Remate editado      (sin una sola etiqueta)
```

A las 1:11 cambió el incremento y **no** tocó las escaleras; a las 1:09 cambió las escaleras y **no** tocó el remate. Las dos entradas sobrantes son falsas.

**La causa es la misma en las dos.** La pantalla de editar llama a `editar_remate` **y** a `guardar_escaleras` en todos los guardados, toque el admin lo que toque. Antes del ADR-037 eso no se notaba porque las escaleras se escribían directo y no dejaban asiento. **Al darles auditoría, una llamada inútil se convirtió en una entrada falsa.**

Es el ADR-022 —la alarma que saltaba cuando no pasaba nada— y el ADR-034 —el aviso que se dispara de más devalúa a los demás— en la bitácora. Y aquí duele más: el registro de acciones es lo que un licenciatario enseña cuando alguien discute una decisión de la casa. Uno lleno de entradas que no ocurrieron no se lee, y el día que importe una se pasará por encima.

**Decisión: compara la BASE, no la pantalla.** Habría sido más fácil que el frontend no llamara a la RPC si nada cambió, y habría sido el ADR-015 otra vez: la regla de «qué cuenta como un cambio» viviría en una pantalla, y la siguiente que llame a esa RPC tendría que acordarse de repetirla. `guardar_escaleras` calcula una firma del conjunto de tramos y, si coincide con la guardada, **no borra, no inserta y no deja asiento** — P69 lo comprueba verificando que los `id` de las filas no cambian. `editar_remate` no deja asiento cuando `v_cambios` viene vacío.

**Y el asiento dice qué pasó, no cuánto.** Una línea por caballo **que haya cambiado**: `Caballo 5: sin escalera → 1 tramo (sube 75,00)`. La forma `{antes, despues}` no es casual: es la que `resumirDetalles` de `/admin/log` ya sabe pintar, así que no hubo que tocar el frontend.

**Por qué no dice «cambió de suave a agresiva», que era lo que Jota pidió.** Porque la base no sabe que existe «suave»: el ritmo vive en `lib/escalera.ts` y es un **generador** — produce los tramos y desaparece. Comprobado: la palabra `ritmo` no aparece en ninguna migración. Guardar la etiqueta además de los tramos sería tener dos fuentes para el mismo hecho, y empezaría a mentir en cuanto alguien editara un tramo a mano (ADR-015). El asiento describe los tramos reales, que es lo que se puede afirmar siempre.

**Lo que sigue sin registrarse, y no se arregla aquí.** Los cambios de un **caballo** —nombre, jinete, precio de salida, retirado, altas y bajas— son `UPDATE` directos desde el navegador: no hay trigger ni línea que escriba `admin_actions` por `horses`. Cambiar el precio de salida de un caballo no deja ningún rastro, y eso roza el dinero porque es lo que se lleva la casa si nadie puja por él. Para registrarlo hace falta `guardar_remate_completo`.

**`editar_remate` se regeneró entera**, extraída de `20261002100000` con un script y parcheada en un solo sitio. No se retipea un cuerpo PL/pgSQL a mano: el 02/10 hacerlo perdió un `pg_advisory_xact_lock` e inventó un estado que no existe (ADR-021).

**Consecuencias.** `P69`, siete condiciones, incluida la que da nombre al ADR: guardar las mismas escaleras no deja asiento **y no toca las filas**.

---

## ADR-039 · Editar un remate es una transacción, y cada cambio deja asiento

**Fecha.** 8 de octubre de 2026 *(migración `20261008150000`)*

**Contexto.** Jota, el 07/10 mirando `/admin/log`: *«ahí debería decir que editaron el incremento de tanto a tanto y así con cada acción que se edite, el cambio de nombre de un caballo y cualquier otra cosa que se pueda editar en un remate ya creado»*.

No se podía. Los cambios de un caballo —nombre, jinete, precio de salida, retirado, altas y bajas— eran `UPDATE` directos desde el navegador: **no había trigger ni línea que escribiera `admin_actions` por `horses`**. Cambiar el precio de salida de un caballo era invisible, y eso roza el dinero, porque es lo que se lleva la casa si nadie puja por él.

Y el guardado seguía siendo **16 o 17 escrituras sueltas** para una carrera de 12 caballos: `races`, `editar_remate`, el borrado de caballos, **un UPDATE o INSERT por caballo**, y las escaleras. Un fallo a mitad del bucle dejaba unos caballos con los datos nuevos y otros con los viejos, y la pantalla diciendo «Error guardando cambios» como si no hubiera pasado nada.

**Decisión: `guardar_remate_completo(uuid, jsonb, jsonb, jsonb, jsonb)`, que DELEGA en vez de reimplementar.** `editar_remate` y `guardar_escaleras` ya existían, ya estaban probadas y ya dejaban asiento solo cuando había cambio (ADR-038). Esta función **las llama**. Una función PL/pgSQL que llama a otra sigue en la misma transacción, así que el todo es atómico igual y no aparece una segunda implementación de la regla del incremento ni de la de las escaleras. Copiarlas habría sido el ADR-015 dentro de la propia base.

Lo que hace por su cuenta es lo que nadie hacía: `races` y `horses`, con su auditoría campo a campo.

**El candado se toma tres veces y no pasa nada.** `pg_advisory_xact_lock` cuenta re-entradas dentro de la misma transacción, así que tomarlo aquí y otra vez dentro de las dos funciones delegadas no se traba.

**Las bajas se piden, no se deducen.** Sería más cómodo borrar todo caballo que no venga en la lista, y sería una bomba: un fallo del frontend que mandara la lista a medias borraría caballos con pujas. Se borra exactamente lo que venga en `p_eliminados`, y solo si es de esa carrera. **No adivinar lo que el usuario no dijo** vale también entre dos trozos de código propio.

**Las escaleras viajan colgando de su caballo**, igual que en el ADR-036, así que un caballo recién creado lleva la suya sin que la pantalla tenga que recuperar su id. El `newIdByTemp` que hacía ese trabajo desaparece.

**Qué dice el asiento.** Una clave por cosa que cambió, con la forma `{antes, despues}` que `/admin/log` ya sabe pintar:

```
Carrera hipodromo: La Rinconada → Valencia
Caballo 1 precio salida: 100,00 → 150,00
Caballo 7 alta: (no existía) → Centella, salida 120,00
Caballo 3 baja: Tres → (eliminado)
```

Y **no nombra al caballo que no cambió**. Si no cambió nada, no hay asiento (ADR-038).

**Y se cierran las dos puertas que quedaban.** `races` y `horses` bajan a solo lectura para `authenticated`. Con `remate_price_rules` (ADR-037), quedan cerradas las tres tablas del catálogo del remate: el panel ya no escribe ninguna directo.

**Una corrección de P48.** `support_settings` llevaba desde el 29/09 agrupada con esas tres, con la nota de que las cuatro bajarían «el día que existan `crear_remate_completo()` y `guardar_remate_completo()`». No tenía nada que ver: la escribe `/admin/super/soporte`, otra pantalla, y necesita su propia RPC. Sale de ese grupo con su motivo escrito al lado.

**Lo que NO arregla, dicho para que no se descubra por sorpresa.** Siguen sin poder intercambiarse los números de dos caballos: `horses_race_id_numero_key` no es diferible, así que pasar el 3 a 5 cuando ya hay un 5 rebota con 23505. La diferencia es que ahora **rebota sin dejar nada a medias**. Arreglarlo de verdad es renumerar en dos fases o declarar la restricción diferible, y es una decisión aparte.

**Consecuencias.** `P70`, ocho condiciones. La que da la medida es la atomicidad: se fuerza que el tercer caballo no pase el mínimo de precio de salida **después** de haber escrito los dos primeros y la carrera, y se compara la foto de los caballos antes y después:

```
foto antes:   1=Relampago/150.00, 2=Dos/100.00, 7=Centella/120.00
foto después: 1=Relampago/150.00, 2=Dos/100.00, 7=Centella/120.00
```

Idéntica. Antes, el 1 y el 2 se habrían quedado cambiados.

---

## ADR-040 · El «Volver» era el síntoma; la enfermedad era que no había navegación

**Fecha.** 9 de octubre de 2026 *(sin migración: esto es todo frontend)*

**Contexto.** Jota, en mayúsculas y con razón: *«ME TIENE ENFERMO EL PUTO BOTONSITO DE VOLVER, VOLVER, VOLVER»*.

Medido antes de tocar nada: **11 pantallas de admin con cero navegación** y **10 enlaces «Volver»** en el lado cliente. El «Volver» no era un botón feo: era el único camino entre pantallas. Para ir de `/admin/recargas` a `/admin/retiros` había que volver a `/admin`, leer el menú y entrar. Y como cada pantalla se lo dibujaba a su manera, el mismo gesto estaba en cuatro sitios distintos y con cuatro estilos.

Un enlace «Volver» además **miente sobre a dónde lleva**: no vuelve a la pantalla anterior, lleva a la que el programador supuso que era la anterior. Desde `/reglas`, al que había llegado desde el registro, «Volver a remates» no era volver.

**Decisión: el marco de la aplicación vive por encima de las pantallas, una sola vez, y las pantallas no se dibujan su navegación.** Es el ADR-026 otra vez, aplicado a la navegación.

- **Panel de admin:** barra lateral en escritorio, barra inferior con cajón en móvil. Cuatro grupos (Caja / Remates / Casa / Ajustes). Los contadores salen de `useCajaEnVivo()` — no se recalculan, así que no pueden discrepar del aviso de caja.
- **Lado cliente:** cabecera `sticky` con la marca y, en escritorio, el menú; barra inferior **solo en móvil**, que es donde Jota la quiere y donde llega el pulgar.

**Por qué la cabecera se queda incluso donde el saldo se oculta.** Jota pidió que el nombre y el saldo **no** salieran en su panel ni en la pantalla de pujar, porque ahí los tres saldos ya están en grande: dos cifras del mismo dinero en una pantalla hacen dudar cuál es la buena. Correcto. Pero lo que se oculta es **el bloque de usuario y saldo, no la cabecera**, y el motivo es duro: en escritorio el menú vive en la cabecera. Si la cabecera desapareciera en esas dos pantallas, un jugador con portátil se quedaría ahí **sin ninguna forma de salir** — el problema del «Volver» reintroducido por la puerta de atrás.

**Un proveedor pregunta, dos componentes pintan.** La cabecera y la barra inferior necesitan lo mismo (sesión, rol, nombre, saldo) y no pueden ser el mismo componente porque una va arriba del contenido y la otra abajo. `SesionCliente` lo resuelve **una vez** para toda la aplicación; `CabeceraCliente` y `NavegacionCliente` solo pintan. Es la forma de `CajaEnVivo` en el panel, y por el mismo motivo: dos consultas de lo mismo son dos verdades que acabarán discrepando.

**Y un solo menú.** `enlacesCliente.ts` declara los enlaces y, con ellos, qué cuenta como «estar en esta pantalla» — `/remates` sigue marcado dentro de un remate concreto, `/dashboard` **no** se marca en `/dashboard/retirar` porque retirar es su propio botón. Dos listas habrían ofrecido menús distintos en móvil y en escritorio a la primera pantalla nueva.

**Los anchos, que era la otra mitad de la queja.** *«en pc se vea normal y no un rectángulo en el medio»*. Era literal: `max-w-md` —448 px, el ancho de un móvil— aparecía **24 veces**. En un monitor de 27 pulgadas la aplicación entera era una columna estrecha entre dos desiertos. `Contenedor.tsx` declara tres anchos con su motivo: `lectura` (448, formularios de una columna, donde 448 **es** lo correcto), `normal` (768) y `ancho` (1280, tablas y listas). En la lista de remates el cambio de verdad no es la tarjeta más ancha sino **cuántas caben**: pasa a rejilla de 2 y 3 columnas.

**Qué «Volver» sobreviven, y por qué.** Los de `/login`, `/register` y `/auth/reset`: son pantallas de autenticación, no llevan marco, y ese enlace es la única salida. Y los dos de «remate no disponible»: ahí el enlace **es la acción**, no decoración de chrome.

**Una línea de regalo, dicha para que no sea una sorpresa en el diff.** El pie de página tenía `©2026` escrito a mano desde enero; ahora lo calcula `lib/marca.ts`. En enero de 2027 habría mentido.

**Lo que queda abierto.** `/dashboard/retirar` enseña «Saldo total: Bs X», que es **exactamente** la cifra de la cabecera. Por el criterio que dio Jota debería ocultarse ahí también; no lo meto por mi cuenta porque él nombró dos pantallas, no tres. Es una línea en `yaEnsenaElSaldo`.

**Consecuencias.** No hay prueba automática de esto: es disposición en pantalla, y lo que la valida es mirarla. `tsc` limpio, `eslint` sin añadir ni un problema nuevo a los seis archivos tocados, `next build` verde.

---

## ADR-041 · `/admin` deja de ser el menú y pasa a decir cómo está la casa

**Fecha.** 10 de octubre de 2026 *(sin migración)*

**Contexto.** `/admin` eran 166 líneas, y de ellas un bloque «Acciones» con **ocho enlaces**. Los ocho están desde ayer en la barra lateral (ADR-040), así que al entrar al panel se veía el menú **dos veces en la misma pantalla**. Y la copia del medio ya estaba desactualizada: la barra lleva 9 destinos, el bloque llevaba 7 — faltaban **Usuarios** y **Soporte**, que nacieron después. Nadie actualiza dos listas de lo mismo; es el ADR-015 aplicado a la navegación.

Hasta ADR-040 ese menú estaba justificado, porque `/admin` **era** el único sitio donde existía la lista de destinos. Al dejar de serlo, la pregunta que esta pantalla tiene que responder cambia: no «a dónde puedo ir», sino **cómo está la casa ahora mismo**.

**Decisión: tres bloques, en orden de urgencia.**

**1 · Cola de trabajo, y la cifra que importa no es el monto.** Jota: *«un retiro pendiente no debería ser tal cosa por mucho tiempo, de hecho eso debería ser cuestión de minutos, no de horas ni mucho menos días»*. Si eso es cierto, lo informativo es la **antigüedad del más viejo**, no la cantidad: «2 retiros pendientes» no dice nada, «2 retiros, el más viejo hace 3 horas» dice que la casa está operando mal. Un jugador que espera un pago tres días no vuelve, y lo cuenta. Dos umbrales (15 y 60 minutos) traducen esa frase a colores, declarados en dos constantes.

**2 · Balance, con el «Debe» por fin partido.** Y aquí me corrijo: **dije que hacía falta una migración y no hacía falta.** `casa_resumen()` devuelve `obligaciones` sumado, pero `admin_contabilidad_resumen()` —que la pantalla de contabilidad ya llama— devuelve **las dos mitades por separado y con la definición idéntica**: `saldo_usuarios` es `sum(saldo_disponible + saldo_bloqueado)` de `wallets`, y `retiros_pendientes` es `sum(monto)` de los retiros pendientes. Son los mismos dos CTEs que `casa_resumen` suma. Lo afirmé sin medir hasta el fondo; la corrección salió de leer las dos funciones enteras, que es la lección de siempre.

Por qué importa partirlo, y no es estética: los saldos son **flotante** —dinero del jugador que puede que nunca pida— y los retiros pendientes son **pagos que hay que hacer ya**. Con una sola cifra de 50.000 Bs el dueño no sabe si puede retirar utilidades o si tiene que dejar 8.000 quietos para mañana. Eso es una decisión de dinero.

**3 · Las recargas pendientes no están en el balance, y es correcto.** Una recarga pendiente **no es dinero**: no está en caja (`casa_resumen` solo cuenta las `'aprobado'`) ni en obligaciones (la cartera no se acredita hasta aprobar). Es una promesa del jugador, y su sitio es la cola de trabajo. Un retiro pendiente **sí** es deuda, y la más urgente, porque `solicitar_retiro` ya le descontó el saldo al jugador al pedirlo (`20261006110000`): la casa ya tiene ese dinero fuera de la cuenta del jugador y todavía no lo ha entregado. Por eso entra en `obligaciones`, y por eso **no** hay doble conteo con los saldos.

**Esta pantalla no hace ni una suma de dinero.** Pinta lo que devuelven las dos RPC. Calcular aquí sería tener dos sitios diciendo cuánto debe la casa (ADR-015) y aritmética de dinero en JavaScript (ADR-035). También se descartó sumar el libro en el navegador: `/admin/contabilidad` lo lee con `.limit(15)`, y sumar por categoría obligaría a traer la tabla entera — a 1.000 remates, 1.000 filas para pintar dos cifras.

**El descuadre solo aparece cuando hay descuadre.** Un cero permanente en pantalla se vuelve invisible, y el día que deje de ser cero nadie lo nota.

**Lo que NO se puede todavía, dicho para que no se busque en vano.** Las ganancias por remates salen en **una** cifra. El reparto existe dentro de `admin_contabilidad_resumen` —el CTE `calc` ya distingue `ganador_user_id is null` → la casa se queda el pozo entero, si no → `pozo * pct/100`— pero sale sumado en `remates_casa_total`. Son **dos claves más en el jsonb**, sin cambio de tipo de retorno: migración trivial, pero migración.

Y antes de escribirla hay una decisión que no es técnica: las categorías honestas son **tres**, no dos. Comisión sobre pozos que ganó un jugador; pozos completos que ganó la casa; y **los caballos que nadie pujó**, que la casa banca por su `precio_salida` y entran al pozo sin que nadie ponga ese dinero — hoy mezclados dentro de las otras dos. Es Jota quien decide si el tercero es categoría propia.

**El reloj.** La antigüedad se calcula con el reloj del **navegador** contra `created_at`. Con la hora desajustada, el número miente. Es el mismo defecto ya anotado para la ventana del remate; para un indicador de cola es tolerable, para decidir dinero no se usaría.

**Consecuencias.** 166 líneas de menú duplicado fuera. `tsc` limpio, `eslint` sin un solo problema en el archivo, `next build` verde. No hay prueba automática: es una pantalla de lectura, y lo que la valida es comparar sus cifras con `/admin/contabilidad`, que lee las mismas dos funciones.

---

## ADR-042 · La marca deja de estar escrita a mano, y pasa a ser vectorial

**Fecha.** 10 de octubre de 2026 *(sin migración)*

**Contexto.** El diseñador entregó **un JPG de 2048×2048** y nada más. De ahí salieron los PNG con transparencia (ADR de facto en `docs/MARCA.md`), pero la marca seguía **clavada a mano en cinco sitios**: dos rutas y dos `alt` en `BrandLogo.tsx`, el `title` del layout, el pie de página y el `h1` de la portada. `lib/marca.ts` existía desde el 09/10 pero **no lo usaba nadie**: era una costura preparada y sin coser.

Eso no es comodidad, es el modelo de negocio: esta aplicación se alquila, y cada licenciatario quiere el nombre de su remate.

**Decisión 1: los vectoriales se sacan aquí, de los propios PNG.** El procedimiento completo está en `docs/MARCA.md`; `herramientas/marca_vectorizar.py` lo repite entero si mañana llega un logo nuevo. Lo que lo hizo posible fue una medición: **el alfa de esos PNG es prácticamente binario** —52 % fuera, 47 % dentro, 0,9 % de borde—, así que los huecos internos ya estaban como transparencia y trazar el alfa devuelve la silueta completa **con** sus huecos. Con un alfa suave no habría salido.

Siete archivos, **67 KB en total contra 3,3 MB de PNG**. El isotipo pasa de 1.008 KB a **4,3 KB**.

**Y no son el vectorial del diseñador.** El original es un render 3D con biseles, reflejos y destellos; eso no se traza — un autotrazado de un degradado metálico da cientos de bandas planas, pesa megas y se ve peor. Esto es la marca **aplanada**. Para la interfaz es mejor que el PNG; para una pieza grande donde el metal es el protagonista, el PNG 3D sigue siendo más rico, y por eso no se borró ninguno de los dos que hacen falta.

**Decisión 2: la versión `-mono` no es un extra.** `fill="currentColor"` es lo que permite que la misma pieza sirva con el color de un licenciatario sin rehacerla. Es el modelo de negocio metido en un atributo, y con un PNG era imposible.

**No hubo que tocar `next.config.ts`, y se comprobó en la documentación antes de escribir nada.** Next 16: *«We recommend using the `unoptimized` prop when the `src` prop is known to be SVG. This happens automatically when `src` ends with `.svg`»*. Es decir, `next/image` con un `.svg` se salta el optimizador solo, así que **no hace falta `dangerouslyAllowSVG`** — que es la bandera que habría hecho falta si el SVG pasara por el optimizador, y que habría abierto la puerta a SVG remotos con scripts. La alternativa era `<img>`, que eslint marca.

**Decisión 3: los iconos se mudan a `app/`.** `icon.png`, `apple-icon.png`, `favicon.ico` y `opengraph-image.png` estaban en `public/marca/` sin que nadie los sirviera. En `app/` son convención de Next y aparecen solos: el build pasó de 27 a **30 rutas**, y las tres nuevas son `/icon.png`, `/apple-icon.png` y `/opengraph-image.png`. Siguen siendo PNG a propósito: iOS no respeta el alfa y las redes sociales no renderizan SVG.

**`metadataBase`, que no es decorativo.** Sin él la vista previa al compartir apunta a una ruta relativa y las redes se quedan sin imagen. Sale de la variable que Vercel pone sola, con respaldo a localhost para que `next dev` no avise.

**Tres cosas que se arreglaron de paso, dichas para que no sorprendan en el diff.**

1. **La portada decía «Remates Catire Bello», en plural.** La marca es «Remate Catire Bello», en singular — está así en el logo y en `lib/marca.ts`. Llevaba escrito a mano desde enero. Ahora ese `h1` sale de `PLATAFORMA.nombre` y es `sr-only`: el nombre ya está **dentro** del logo, y repetirlo debajo en texto era decirlo dos veces.
2. **Los tres botones de la portada eran `<a>`, no `<Link>`.** eslint lo marcaba como error desde antes de hoy. Un `<a>` interno recarga la página entera, y con ella se pierde la suscripción de realtime que vive en el layout.
3. **Se borraron `public/logo.png`, `public/logo-hero.png` y los cinco SVG de la plantilla de `create-next-app`** (`file.svg`, `globe.svg`, `next.svg`, `vercel.svg`, `window.svg`). Los dos primeros quedaron huérfanos al reescribir `BrandLogo`; los otros cinco nunca los usó nadie. `public/` queda con una sola carpeta: `marca/`.

**Consecuencias.** `tsc` limpio, `eslint` **cero problemas** en los cuatro archivos tocados, `next build` verde con 30 rutas. No hay prueba automática: es marca, y lo que la valida es mirarla.

---

## ADR-043 · Una transacción decide QUÉ se guarda, no CUÁNDO se comprueban las reglas

**Fecha.** 10 de octubre de 2026 *(migración `20261010140000`)*

**Contexto.** Pendiente 1.1, medido el 07/10 y arrastrado tres días. No se podían **intercambiar** los números de dos caballos: pasar el 3 a 5 cuando la carrera ya tenía un 5 rebotaba con `23505 duplicate key value violates unique constraint "horses_race_id_numero_key"` en el **primer** `UPDATE`, antes de que el 5 llegara a ser 3. Y el admin lo veía en crudo.

**Y aquí está lo que importa entender, porque es fácil creer lo contrario.** `guardar_remate_completo` **ya era atómica** desde el 08/10 (ADR-039), y P70 lo demuestra con una foto idéntica de los caballos antes y después de un fallo. Aun así esto fallaba. El defecto no era de atomicidad: era que el **índice comprueba fila a fila** un estado —«no hay dos caballos con el mismo número»— que durante un intercambio es **falso a mitad de camino** y solo vuelve a ser cierto cuando el bucle termina.

> Una transacción decide que se guarda **todo o nada**. No decide **cuándo** se comprueban las reglas.

**Decisión: la restricción pasa a `DEFERRABLE INITIALLY IMMEDIATE`, y el diferimiento se pide a mano donde hace falta.** La alternativa era renumerar en dos pasadas —primero a números temporales que no choquen, luego a los definitivos—, que funciona, duplica los `UPDATE` y mete en la función una regla sobre qué números son «seguros» que habría que mantener para siempre. El diferimiento existe exactamente para esto.

**`INITIALLY IMMEDIATE` y no `INITIALLY DEFERRED`**, que es la decisión fina. Diferir por defecto en toda la base significa que **cualquier** escritura con números repetidos no se entera hasta el `COMMIT`, incluida una que no intercambia nada. Así, un `insert` suelto sigue rebotando al momento —P71 lo comprueba— y la única línea que difiere es la que está dentro de `guardar_remate_completo`.

**Se comprueba dentro de la función, no al confirmar.** `set constraints ... immediate` fuerza la comprobación ahí mismo; la documentación de PostgreSQL lo dice literal: *«any outstanding data modifications that would have been checked at the end of the transaction are instead checked during the execution of the SET CONSTRAINTS command»*. Hace falta que falle **ahí dentro**: si la comprobación se quedara para el commit, el `23505` saldría fuera de la función y el admin volvería a ver el `duplicate key` en crudo. El bloque lo traduce. Quien rechaza sigue siendo el índice; esto es presentación del error (mismo criterio que ADR-036).

**Hay `DROP` porque no hay otra forma, y se comprobó antes de escribir.** `ALTER TABLE ... ALTER CONSTRAINT` solo sirve para claves foráneas: *«Currently only foreign key constraints may be altered»*. Y al tirarla no se rompe nada: ninguna clave foránea apunta a `(race_id, numero)` —las tres sobre `horses` apuntan a `horses(id)`—, y **no hay ni un `on conflict` sobre `horses`** en todo el repositorio, que es el uso que un índice diferible no admite.

**La mecánica se probó aislada antes de tocar la migración**, sobre un Postgres 16 limpio y con el mismo patrón: el intercambio pasa, el duplicado de verdad da `23505` con el mensaje traducido **y las filas no se mueven**, y un `insert` suelto repetido sigue rebotando al momento.

**Consecuencias.** `P71`, cuatro condiciones. La que da la medida es la foto idéntica tras el duplicado: el primer `UPDATE` **sí** llegó a ejecutarse —por eso hacía falta diferir— y aun así no quedó nada.

---

## ADR-044 · Dos clics son dos peticiones correctas, y por eso la transacción no bastaba

**Fecha.** 10 de octubre de 2026 *(migración `20261010150000`)*

**Contexto.** Pendiente 1.2, abierto desde el 07/10. Jota: *«al crearse un remate, el botón de crear remate queda activo y si le doy 20 veces más, crea 20 remates con el mismo nombre y los mismos datos»*.

**Por qué la transacción del 07/10 no lo cubrió**, que es el mismo malentendido que ADR-043 por el otro lado:

> Dos clics son dos llamadas **completas y correctas**. No hay nada a medias que deshacer.

`crear_remate_completo` hacía su trabajo bien las dos veces. La base creaba dos remates porque **no tenía forma de saber que era el mismo**. Una transacción decide si una petición se guarda entera; no decide si dos peticiones son la misma petición.

Las dos guardas que había (`if (saving) return` y `if (createdRemateId)`) son **del navegador**. Protegen del doble clic rápido en la misma pestaña y de nada más: recargar y reenviar las salta, dos pestañas las saltan, y una respuesta que tarda con un admin que insiste las salta.

**Decisión: una clave que pone quien pide.** El formulario genera una clave en el primer envío y la repite en **cada reintento**. Dos envíos con la misma clave son, por definición, el mismo remate —y eso la base sí lo puede afirmar, porque es un dato y no una suposición. La clave identifica el **intento**, no la pulsación.

**El segundo envío no crea nada y no falla: devuelve el remate del primero**, con la misma forma de respuesta y con los contadores reales —contados de las filas, no recordados. Para el formulario es indistinguible de haber acertado a la primera, que es justo lo que se quiere: un admin que hizo doble clic no tiene por qué ver un error.

**El candado va antes de mirar, no después.** Sin él, dos clics casi simultáneos entran los dos en el `select`, los dos no encuentran nada y los dos intentan insertar: uno gana y el otro se come un `23505` del índice único —correcto en cuanto a datos, feo en cuanto a mensaje. Con `pg_advisory_xact_lock` sobre la clave, el segundo espera y cuando mira ya encuentra el remate del primero. El índice único sigue siendo la garantía de fondo.

**No se repite la bitácora.** El segundo envío no creó nada, así que no hay nada que registrar: anotarlo sería el defecto que cerró ADR-038, una bitácora anunciando lo que no pasó. P72 lo comprueba contando asientos.

**Una columna, no una tabla aparte.** La clave es un atributo del remate —con quién lo creó y cuándo. Una tabla de claves sería un sitio más que limpiar, una unión más que hacer, y dejaría la puerta a que exista una clave sin remate. El índice es **parcial** (`where clave_creacion is not null`), así que los remates anteriores a hoy quedan fuera en vez de ocupar una entrada nula cada uno.

**`p_clave` tiene valor por omisión, y eso es por el despliegue.** El orden es **base primero, código después**. Entre los dos pasos, el frontend desplegado llama con tres argumentos: con el valor por omisión esa llamada sigue siendo válida y se comporta como hoy. Sin él, cada remate creado entre un paso y el otro habría fallado. P72 lo comprueba explícitamente.

**Hay `DROP` de la firma vieja.** `create or replace` no puede añadir un parámetro: crearía una función **nueva** y dejaría la de tres argumentos viva. Dos sobrecargas con el mismo nombre dejan a PostgREST eligiendo, y no para la función que crea remates.

**Consecuencias.** `P72`, siete condiciones, incluida la que cierra el bucle: sin clave sigue creando siempre, que es como se comportó hasta hoy y como se comporta el frontend viejo durante el despliegue.
