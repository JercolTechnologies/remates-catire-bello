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

## Los vectoriales (10/10/2026)

El diseñador no entregó vectoriales, así que se sacaron aquí, de los propios
PNG. El script es `herramientas/marca_vectorizar.py` y se vuelve a correr
entero si mañana llega un logo nuevo.

| Archivo | Peso | Para qué |
|---|---|---|
| `isotipo.svg` | 4,3 KB | el monograma, con el degradado de la paleta |
| `isotipo-mono.svg` | 4,1 KB | lo mismo en `currentColor` |
| `texto.svg` | 8,5 KB | REMATE + CATIRE BELLO |
| `logo-vertical.svg` | 12,8 KB | el conjunto apilado, como el original |
| `logo-horizontal.svg` | 12,8 KB | isotipo + texto en línea |
| `logo-vertical-mono.svg` · `logo-horizontal-mono.svg` | 12,4 KB | en `currentColor` |

**El isotipo pasa de 1.008 KB a 4,3 KB**, y además se ve mejor a cualquier
tamaño.

### Por qué esto se pudo hacer

El alfa de los PNG es prácticamente **binario** — medido: 52 % fuera, 47 %
dentro, 0,9 % de borde. Los huecos internos (los espacios entre las crines, el
ojo, el hueco de la C) ya están como **transparencia**, no como pintura oscura.
Trazar el canal alfa devuelve la silueta completa **con** sus huecos, que es
exactamente lo que es un logo plano.

### Lo que estos SVG NO son

**No son el vectorial del diseñador.** El original es un render 3D: biseles,
reflejos especulares y destellos. Eso no se puede trazar — un autotrazado de un
degradado metálico produce cientos de bandas planas, pesa megas y se ve peor.

Lo que hay aquí es la marca **aplanada**: la misma forma, con un degradado
dorado de la paleta medida. Para la interfaz es **mejor** que el PNG. Para una
pieza grande donde el metal es el protagonista — la portada, un cartel — el PNG
3D sigue siendo más rico, y por eso no se borra ninguno.

### Las costuras

Donde dos formas se solapan — la **B** contra la quijada del caballo, la **C**
contra la crin — el original las separa con un bisel **dorado sobre dorado**, no
con un hueco. Al aplanar, esas dos formas se funden en una mancha. El parámetro
`--costuras` recorta por luminancia y recupera la separación. Medido sobre el
isotipo: **por debajo de 70 no separa nada, 85 separa bien, a partir de 100
empieza a comerse pedazos**. Los archivos de esta carpeta están a 85.

### El hallazgo que parece al revés

Mismo recorte del hocico, renderizado a 2400 px de ancho:

| Parámetros | Peso | Bordes |
|---|---|---|
| escala ×2, 1 decimal | 44,3 KB | temblorosos |
| escala ×2, 0 decimales | 29,4 KB | peor todavía |
| **escala ×1, 0 decimales** | **4,2 KB** | **el más suave de los tres** |

Al ampliar la máscara ×2 y desenfocarla, el borde gana ruido de píxel que
potrace sigue fielmente. A escala 1 es el ajuste de curvas de potrace el que
suaviza. Diez veces más pequeño **y** mejor.

Esto solo se vio **comparando recortes ampliados**. El SVG de 44 KB era válido,
tenía el número de contornos correcto y pesaba lo esperado: ninguna comprobación
automática lo habría atrapado.

### La versión mono no es un extra

`fill="currentColor"` es lo que permite que la misma pieza sirva con el color de
un licenciatario sin rehacer nada. Es el modelo de negocio metido en un
atributo.

### Lo que sigue conviniendo pedirle al diseñador

El vectorial de verdad, para tener **el metal en vector** y para que la versión
horizontal la componga él: la de aquí está **compuesta por nosotros** — el
original viene apilado, y la línea se armó poniendo el texto al lado del
isotipo al 74 % de su altura. No bloquea nada; es para que no se descubra tarde.
