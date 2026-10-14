# Cómo operar tu casa

Guía del administrador. Está escrita para la persona que **opera** la casa, no para quien programa: no hace falta saber nada técnico para seguirla.

---

## Antes de nada: qué hace esta aplicación y qué no

**Lo que hace:** llevar las cuentas. Registra quién recargó, quién pujó, quién va ganando, cuánto se le cobra al cerrar un remate y cuánto se le paga al liquidarlo. Y deja constancia de cada acción tuya, con tu nombre y la hora.

**Lo que NO hace, y conviene que lo tengas claro desde hoy:**

- **No mueve dinero real.** Ni un bolívar pasa por el software. El jugador te paga a **tu** cuenta y tú le pagas desde **tu** cuenta. La aplicación solo anota.
- **No cobra ni paga sola.** Nada se acredita hasta que **tú** apruebas, y nada sale hasta que **tú** pagas y lo marcas.
- **No verifica identidades** ni comprueba que un pago llegó. Eso lo miras tú en tu banco.

De ahí se deduce lo importante: **el dinero de tus jugadores es responsabilidad tuya**, no de la plataforma. La aplicación te da el libro de cuentas y la prueba de lo que pasó; el resto es tu operación.

---

## 1. El día uno: deja la casa lista

Son cinco cosas. Hasta que estén, tu casa no puede trabajar.

### 1.1 Fundar la casa

Entra a tu dirección web, **regístrate** con el correo que diste al contratar y vuelve a la portada. Verás una franja ámbar que dice *«Esta casa todavía no tiene dueño»*. Pulsa **Fundar la casa**, entra con ese correo y te pedirá dos datos:

- **Código** (de 2 a 6 letras o números, por ejemplo `JP1`)
- **Nombre visible** (el tuyo)

> **Esos dos datos no son adorno.** Cada acción que hagas sobre el dinero queda firmada con ellos en el registro de la casa. Si mañana hay una discusión sobre quién aprobó una recarga, ahí está la respuesta.

Esto **solo funciona una vez**. En cuanto fundas, nadie más puede hacerlo — ni siquiera nosotros.

### 1.2 Tus datos de cobro

**`Datos de la casa` → `Cómo cobras`.**

Titular, cédula o RIF, y al menos un método completo (Pago Móvil o transferencia). **Mientras falte algo, tus jugadores no pueden recargar**: la pantalla de recarga les dirá que la casa todavía no tiene datos de cobro, y no les dejará enviar la solicitud.

Es a propósito. Es preferible que no puedan pagar a que paguen a la cuenta equivocada.

La pantalla te enseña una **vista previa de lo que verá tu jugador**. Compárala con tu libreta antes de guardar: un dígito mal copiado no lo descubre quien lo escribió, lo descubre días después alguien que mandó su dinero a otro sitio.

### 1.3 Tu nombre y tu logo

Misma pantalla, bloque **`Tu casa`**.

- **Nombre:** sale en la portada, en la cabecera, en la pestaña del navegador y cuando alguien comparte el enlace.
- **Logo:** opcional. Súbelo y ya está — le quitamos el espacio sobrante solo y lo dejamos del tamaño correcto. PNG, JPG o WEBP, hasta 2 MB.

Si no tienes logo no pasa nada: se ve tu nombre bien puesto, y queda digno.

### 1.4 Tus canales de contacto

**`Soporte`.** Pon tu correo, tu WhatsApp o lo que uses.

Ahí es donde te escribe un jugador con un problema: la página **Quejas, reclamos y sugerencias** le dice, con tu nombre, que **tu casa** es quien recibe los depósitos, paga los retiros y responde por los reclamos. Si no pones nada, esa página sale vacía y el jugador se queda sin saber a quién escribir — que es exactamente como se generan los problemas.

### 1.5 Revisa los mínimos

En **`Datos de la casa`** verás que hay tres valores que **no** puedes cambiar desde ahí:

| Valor | Qué es |
|---|---|
| Incremento mínimo | lo mínimo que puede subir una puja |
| Precio de salida mínimo | lo mínimo a lo que puede salir un caballo |
| % apostado para poder retirar | cuánto de lo recargado hay que jugar antes de poder sacar |

No están bloqueados por capricho: **la base de datos valida contra ellos**, y cambiarlos desde una pantalla podría dejarte creando remates que el propio sistema rechaza en otro sitio. Si necesitas otros valores, **pídenoslo** y te los cambiamos.

---

## 2. Cómo funciona el dinero, en una frase

> **Durante el remate no se mueve un solo bolívar. El dinero se mueve una sola vez, al cerrar.**

Si te acuerdas de esa frase, todo lo demás se deduce.

### Los tres números que ve tu jugador

| Número | Qué es |
|---|---|
| **Saldo total** | todo lo que tiene en tu casa |
| **Comprometido** | lo que se le cobraría si los remates cerraran ahora mismo |
| **Retirable** | lo que puede sacar hoy: total menos comprometido |

**El saldo total NO baja al pujar.** Lo que baja es el retirable. Mucha gente espera que baje el total, y ahí es donde se arman las discusiones. Si un jugador te escribe diciendo «pujé y no me descontaron», tiene razón: todavía no se le ha cobrado nada.

### Lo que confunde a todo el mundo

Un jugador va ganando un caballo en 200 y lo sube a 250. **Queda comprometido por 250, no por 450.** La puja nueva reemplaza a la vieja, no se suma.

### Qué pasa en cada momento

| Momento | Qué pasa con el dinero |
|---|---|
| Puja por primera vez | **nada** — queda comprometido, no cobrado |
| Le superan | **nada** — su compromiso baja solo |
| Sube su propia puja | **nada** — el compromiso pasa a ser la nueva |
| Retiran el caballo | **nada** — sale del remate y el compromiso baja |
| **Cierras el remate** | **aquí sí** — a cada uno que iba ganando se le cobra |
| Liquidas | se le paga el premio al ganador |

Un jugador puede estar comprometido en varios remates a la vez: su comprometido es la suma de todos los caballos que lidera.

---

## 3. El día a día

### 3.1 Recargas

El jugador paga **primero** y después registra la solicitud: monto, método, referencia y fecha.

Tú entras a **`Recargas`**, y antes de tocar nada **compruebas el pago en tu banco**. La referencia que él escribió tiene que aparecer en tu cuenta.

- **Aprobar** → se le acredita el saldo en ese momento. Antes de aprobar, ese dinero **no existe** en la aplicación.
- **Rechazar** → te pide un **motivo** de una lista, y puedes añadir una nota. El jugador ve ese motivo, así que escribe algo que le sirva.

> **No apruebes por confianza ni por prisa.** Aprobar es lo mismo que decir «ya recibí este dinero». Si lo apruebas y no llegó, el agujero es tuyo.

### 3.2 Retiros

El jugador pide un retiro. El sistema **ya comprobó** dos cosas antes de que te llegue:

1. Que lo que pide no pase de su **retirable** (total menos comprometido).
2. Que haya **jugado al menos el porcentaje exigido** de todo lo que ha recargado.

Esa segunda es la llamada **regla del 50%**, y está ahí para que tu casa no se convierta en un canal de transferencia: entra dinero por un lado y sale por el otro sin pasar por el juego. Está copiada de cómo lo hacen los operadores con licencia, por higiene — y la solicitud que no la cumple **ni siquiera te llega**.

En **`Retiros`**: **pagas por tu banco primero**, y después lo marcas en la aplicación. Si lo rechazas, también lleva motivo.

> El orden importa: marcar como pagado algo que no pagaste deja tu libro mintiendo, y el jugador verá que «ya cobró».

---

## 4. Un remate de principio a fin

### Paso 1 — Crear

**`Crear remate`**. Datos de la carrera (descripción, hipódromo, número, fecha y hora), datos del remate (nombre, incremento, % de la casa) y los caballos con su número, nombre, jinete y precio de salida.

Si un caballo necesita reglas propias de incremento, se las activas; si no, usa las generales del remate.

> Si pulsas «Crear» dos veces por nervios, **no se crean dos remates**. El sistema reconoce que es el mismo intento.

### Paso 2 — Abierto

Los jugadores pujan. El pozo sube. **No se mueve dinero.**

Puedes editar el remate mientras está abierto: cambiar precios, corregir nombres, incluso **intercambiar los números de dos caballos**. Cada cambio que afecte al dinero queda anotado en el registro.

### Paso 3 — Cerrar

**Se acaban las pujas.** A cada jugador que iba ganando un caballo **se le cobra**. Pase lo que pase después en la carrera, esa plata ya no vuelve.

### Paso 4 — Liquidar

Ya corrió la carrera y sabes qué caballo ganó. Eliges el ganador y se le paga el premio a su dueño: **el pozo menos el porcentaje de la casa** que fijaste al crear el remate. Si el caballo ganador se quedó sin dueño, la casa se queda con el pozo.

> **Cerrar y liquidar son dos cosas distintas, y entre una y otra pueden pasar horas.** Es normal: la carrera todavía no ha corrido. Si tu jugador pregunta por qué ya le cobraron y no le han pagado, la respuesta es esta.

---

## 5. Cancelar y archivar

No son lo mismo y no se deshacen.

- **Cancelar** — el remate no se corre. Te pide **escribir la palabra CANCELAR** y un **motivo obligatorio**. Esa fricción es a propósito: cancelar un remate con pujas afecta al dinero de gente.
- **Archivar** — el remate ya terminó y lo quitas de la vista. Pide **motivo obligatorio** y queda en el histórico. No borra nada.

---

## 6. Tu dinero

### `Estado de la casa` — la pantalla de cada mañana

Es lo primero que ves al entrar, y está pensada para mirarse en diez segundos:

- **Cola de trabajo** — cuántas recargas esperan aprobación y cuántos retiros esperan pago, con el monto y **cuánto lleva esperando el más viejo**. Si algo lleva demasiado, te avisa en ámbar o en rojo.
- **Balance** — tu **caja**, lo que **debes** (saldos de jugadores + retiros por pagar, separados) y tu **patrimonio**.
- **Resultado** — ganancias por remates, capital que aportaste, utilidades que sacaste.

> Esta pantalla **no calcula nada**: todas las cifras salen de la base. Si un número te parece raro, es un número real, no un error de pantalla.

### `Contabilidad`

Aquí registras lo tuyo: **capital aportado** (dinero que metes a la casa) y **utilidades retiradas** (dinero que sacas para ti).

Lo ganado en cada remate **lo escribe el sistema solo** y no se puede meter a mano. Así hay dos formas independientes de calcular lo mismo, y tienen que dar igual. **Si no cuadran, algo pasó** — avísanos.

---

## 7. Tus administradores

Si tu casa la operan varias personas, en **`Administradores`** puedes nombrar a los tuyos. Cada uno con su **código** y su **nombre**, porque cada acción sobre el dinero se firma con ellos.

- Un **administrador** puede aprobar recargas, pagar retiros, crear y liquidar remates.
- Solo el **super administrador** —tú— cambia los datos de cobro, el nombre, el logo y nombra o quita administradores.

> **Un código no se reutiliza nunca**, ni cuando alguien deja el cargo. Si el código de quien se fue se lo das a otro, el registro de los últimos meses deja de significar algo.

Y piénsalo dos veces antes de dar super administrador: esa persona puede cambiar **a qué cuenta bancaria pagan tus jugadores**.

---

## 8. Todo queda escrito

En **`Registro`** está cada acción de cada administrador: qué hizo, cuándo, sobre qué, y qué cambió exactamente — con el valor de antes y el de después.

No es vigilancia. Es lo que te permite responder cuando alguien dice «yo no aprobé eso» o «aquí faltaba dinero».

---

## 9. Cuando algo sale mal

**Un jugador dice que recargó y no le aparece.** Mira `Recargas`: si está pendiente, es que falta que tú la apruebes. Si no está, es que no llegó a registrar la solicitud.

**Un jugador dice que pujó y no le descontaron.** Correcto. No se cobra hasta cerrar el remate. (Ver §2.)

**Un jugador no puede retirar todo su saldo.** Mira su comprometido: si va ganando caballos, ese dinero está apartado. Y revisa la regla del porcentaje jugado.

**Un jugador dice que no le pagaste.** Mira `Retiros` y tu banco. Si lo marcaste como pagado, tu libro dice que cobró.

**Las cuentas no cuadran en `Estado de la casa`.** No lo arregles a mano. **Escríbenos.**

**Escríbenos a nosotros** si: una pantalla da error, las cuentas no cuadran, o necesitas cambiar los mínimos. El enlace de soporte está abajo del todo en el menú de tu panel.

**No nos escribas** por un jugador que no cobró o una recarga sin aprobar: eso es tu operación, y nosotros no vemos ni tocamos tu dinero.

---

## 10. Glosario

| Palabra | Qué significa |
|---|---|
| **Casa** | tu negocio: tú |
| **Remate** | la subasta de los caballos de una carrera |
| **Pozo** | la suma de lo que se pagó por todos los caballos de ese remate |
| **Puja** | lo que un jugador ofrece por un caballo |
| **Comprometido** | lo que se le cobraría a un jugador si todo cerrara ahora |
| **Retirable** | lo que un jugador puede sacar hoy |
| **Cerrar** | se acaban las pujas y se cobra a los líderes |
| **Liquidar** | se paga el premio al dueño del caballo ganador |
| **Caja** | el dinero que debería haber en tu cuenta |
| **Se debe** | saldos de jugadores más retiros pendientes de pago |
| **Patrimonio** | caja menos lo que se debe: lo que es tuyo de verdad |
