# La marca, y de dónde salió cada archivo

Todo lo de esta carpeta se derivó de **un solo archivo**: el logo que entregó el
diseñador, un JPG de 2048×2048, oro sobre un degradado casi negro. No había
vectores.

## La paleta, medida del archivo

No está estimada a ojo: se sacó muestreando los píxeles del logo original.

| Uso | Hex | De dónde sale |
|---|---|---|
| Oro brillo | `#FDEB9C` | el 5 % de píxeles dorados más claros |
| **Oro base** | `#D7AF5D` | la franja del 40–60 % de luminancia |
| Oro sombra | `#865D22` | el 5 % más oscuro |
| Oro promedio | `#D0AC5F` | media de los 532 000 píxeles dorados |
| Fondo arriba | `#242429` | esquina superior del degradado |
| Fondo abajo | `#010005` | esquina inferior |

El fondo de la aplicación hoy es `zinc-950` = `#09090B`, que cae justo dentro de
ese degradado. **La marca y la app ya comparten fondo**, no hay que cambiarlo.

## Los archivos

| Archivo | Para qué | Nota |
|---|---|---|
| `isotipo.png` | el monograma CB + caballo, solo | barra lateral, barra inferior, avatares |
| `logo-horizontal.png` | isotipo + texto en línea | cabecera en escritorio |
| `logo-vertical.png` | el conjunto, como el original | portada, login, registro |
| `icon.png` (512) | favicon moderno | va a `app/icon.png` |
| `icon-192.png` | icono pequeño / PWA | |
| `apple-icon.png` (180) | icono de iOS | **sobre fondo**, no transparente: iOS no respeta el alfa y lo pondría sobre blanco |
| `favicon.ico` | navegadores viejos | 16, 32, 48 y 64 dentro |
| `opengraph-image.png` | vista previa al compartir el enlace | 1200×630, sobre el fondo de la marca |

## Cómo se quitó el fondo, y por qué importa

El original es un JPG: **no tiene canal de transparencia**. Hubo que deducirlo.

La primera versión lo sacó de la luminancia a secas y dejó un **halo rectangular
visible sobre fondo blanco**: el fondo del archivo no es negro puro sino un
degradado que llega a `#242429` arriba, y esa diferencia se quedaba medio opaca.

La versión buena **mide el fondo y lo resta**: las columnas de los extremos no
tienen tinta en ninguna fila, así que su mediana fila a fila es el valor del
degradado a esa altura. El alfa sale del residuo, no del valor absoluto, y por
eso conserva los dorados oscuros sin arrastrar el fondo.

El script que lo hizo es `herramientas/marca_sacar.py`. Si mañana llega un logo
nuevo, se vuelve a correr y salen todas las piezas otra vez.

## Lo que convendría pedirle al diseñador

**El vectorial** (`.ai`, `.eps` o `.svg`). Con él:

- el logo se ve nítido a cualquier tamaño, también en pantallas retina y al
  imprimir; lo que hay ahora son píxeles y a partir de cierto tamaño se notan;
- se puede recolorear sin rehacerlo — hace falta el día que un licenciatario
  quiera su propia marca, que es el modelo de negocio;
- el `logo-horizontal.png` de aquí está **compuesto por nosotros**: el original
  viene apilado, y la versión en línea se armó moviendo el texto al lado del
  isotipo. Con el vectorial, esa versión la hace el diseñador y queda con su
  espaciado, no con el nuestro.

Nada de esto bloquea el rediseño. Es para que no se descubra tarde.
