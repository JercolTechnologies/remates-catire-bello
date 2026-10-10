# -*- coding: utf-8 -*-
"""
herramientas/marca_vectorizar.py  -  DE LOS PNG DE LA MARCA A SVG

POR QUE EXISTE (10/10/2026)
--------------------------
El disenador entrego un JPG de 2048x2048 y no hay vectoriales. `marca_sacar.py`
saco de ahi los PNG con transparencia; este saca los SVG.

LO QUE HACE POSIBLE QUE ESTO FUNCIONE, y conviene entenderlo antes de tocarlo:
el alfa de esos PNG es practicamente BINARIO -- medido: 52% fuera, 47% dentro,
0.9% de borde. Eso quiere decir que los huecos internos (los espacios entre las
crines, el ojo, el hueco de la C) ya estan como TRANSPARENCIA y no como pintura
oscura. Asi que trazar el canal alfa devuelve la silueta completa CON sus
huecos, que es justo lo que es un logo plano.

LO QUE ESTO **NO** ES, dicho claro
----------------------------------
No es el vectorial del disenador. El original es un render 3D: biseles,
reflejos especulares y destellos. Eso NO se puede trazar -- un autotrazado de un
degradado metalico produce cientos de bandas planas, pesa megas y se ve peor.

Lo que sale de aqui es la marca APLANADA: la misma forma, con un degradado
dorado de la paleta medida. Para la interfaz es MEJOR que el PNG (nitida a
cualquier tamano, pesa una decima parte, y se puede recolorear por CSS, que es
lo que hace falta el dia que un licenciatario quiera su color). Para una pieza
grande donde el metal es el protagonista, el PNG 3D sigue siendo mas rico.

LA VERSION MONO, que no es un extra
-----------------------------------
`fill="currentColor"` es lo que permite que la misma pieza valga para la marca
de un licenciatario sin rehacer nada. Es el modelo de negocio metido en un
atributo.

EL UMBRAL DE COSTURAS (`--costuras`)
------------------------------------
Donde dos formas se solapan -- la B contra la quijada del caballo, la C contra
la crin -- el original las separa con un bisel DORADO SOBRE DORADO, no con un
hueco. Al aplanar, esas dos formas se funden en una mancha. Recortando por
luminancia se recupera la separacion. Medido sobre el isotipo: por debajo de 70
no separa nada, 85 separa bien, a partir de 100 empieza a comerse pedazos.
"""
SI_LOS_SVG_PESAN_DE_MAS = """
Si un .svg recien copiado pesa el triple de lo que dice este script, abrelo: el
traslado de archivos entre maquinas le inyecta un manifiesto C2PA (procedencia
de contenido) dentro -- un atributo xmlns:c2pa y un bloque <metadata> de unos
8 KB. No aporta nada a un asset de marca. Se quita con:

    import re
    s = s.replace(' xmlns:c2pa="http://c2pa.org/manifest"', "")
    s = re.sub(r"<metadata>.*?</metadata>", "", s, flags=re.S)

Paso el 10/10/2026 con los siete archivos. El SVG seguia siendo valido y se
veia bien; solo pesaba 120 KB en vez de 67 KB en total.
"""

import argparse
import os
import numpy as np
import potrace
from PIL import Image, ImageFilter

# La paleta medida sobre los 532.000 pixeles dorados del original. Ver
# docs/MARCA.md; no esta elegida a ojo.
ORO_BRILLO = "#FDEB9C"
ORO_BASE = "#D7AF5D"
ORO_SOMBRA = "#865D22"


def _contornos(mascara_bool, escala, turdsize, opttolerance):
    """potrace sobre la mascara. Ojo: hay que invertirla.

    La primera version salio en NEGATIVO -- fondo dorado y marca negra -- y
    eso solo se vio al RENDERIZAR el SVG y mirarlo. Una prueba que no mira el
    resultado no habria atrapado nada: el SVG era valido, pesaba lo esperado y
    tenia el numero de contornos correcto.
    """
    bmp = potrace.Bitmap(np.ascontiguousarray(~mascara_bool))
    return bmp.trace(turdsize=turdsize, alphamax=1.0, opticurve=True, opttolerance=opttolerance)


def _d(camino, escala, dec=0):
    """Coordenadas ENTERAS, y no es un recorte de calidad: es lo contrario.

    Medido sobre el isotipo, mismo recorte del hocico a 2400 px de ancho:

        escala 2, 1 decimal ->  44,3 KB   bordes temblorosos
        escala 2, 0 decimales -> 29,4 KB   peor todavia (el redondeo se come
                                           la precision que daba el x2)
        escala 1, 0 decimales ->  4,2 KB   EL MAS SUAVE de los tres

    Parece al reves y no lo es: al ampliar la mascara x2 y desenfocarla, el
    borde gana ruido de pixel que potrace sigue fielmente. A escala 1 es el
    ajuste de curvas de potrace el que suaviza. Diez veces mas pequeno y mejor.

    Esto SOLO se vio comparando recortes ampliados. El SVG de 44 KB era valido,
    tenia el numero de contornos correcto y pesaba lo esperado.
    """
    def p(pt):
        return pt.x / escala, pt.y / escala

    out = []
    for curva in camino:
        x, y = p(curva.start_point)
        out.append(f"M{x:.{dec}f},{y:.{dec}f}")
        for s in curva.segments:
            if s.is_corner:
                cx, cy = p(s.c)
                ex, ey = p(s.end_point)
                out.append(f"L{cx:.{dec}f},{cy:.{dec}f}L{ex:.{dec}f},{ey:.{dec}f}")
            else:
                a1, b1 = p(s.c1)
                a2, b2 = p(s.c2)
                ex, ey = p(s.end_point)
                out.append(f"C{a1:.{dec}f},{b1:.{dec}f} {a2:.{dec}f},{b2:.{dec}f} {ex:.{dec}f},{ey:.{dec}f}")
        out.append("Z")
    return "".join(out)


def trazar_region(im, caja=None, costuras=0, escala=1, suavizar=0.8, turdsize=6, opttolerance=0.4):
    """Devuelve (d, ancho, alto) de una region del PNG, ya recortada a su tinta."""
    reg = im.crop(caja) if caja else im
    arr = np.array(reg)
    dentro = arr[..., 3] > 128
    if costuras:
        rgb = arr[..., :3].astype(np.float32)
        lum = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]
        dentro = dentro & (lum >= costuras)

    # Recortar al contenido: un SVG con margenes vacios es imposible de
    # componer, porque el margen se escala con la pieza.
    filas = np.where(dentro.any(axis=1))[0]
    cols = np.where(dentro.any(axis=0))[0]
    y0, y1 = int(filas[0]), int(filas[-1]) + 1
    x0, x1 = int(cols[0]), int(cols[-1]) + 1
    dentro = dentro[y0:y1, x0:x1]
    h, w = dentro.shape

    pil = Image.fromarray((dentro * 255).astype(np.uint8))
    pil = pil.resize((w * escala, h * escala), Image.LANCZOS).filter(ImageFilter.GaussianBlur(suavizar))
    m = np.array(pil).astype(np.float32) / 255 > 0.5

    camino = _contornos(m, escala, turdsize, opttolerance)
    return _d(camino, escala), w, h


DEGRADADO = (
    '<linearGradient id="{id}" x1="0" y1="0" x2="0" y2="1">'
    f'<stop offset="0%" stop-color="{ORO_BRILLO}"/>'
    f'<stop offset="45%" stop-color="{ORO_BASE}"/>'
    f'<stop offset="100%" stop-color="{ORO_SOMBRA}"/>'
    "</linearGradient>"
)


def svg_pieza(d, w, h, titulo, mono=False, gid="oro"):
    relleno = "currentColor" if mono else f"url(#{gid})"
    defs = "" if mono else f"<defs>{DEGRADADO.format(id=gid)}</defs>"
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" role="img" aria-label="{titulo}">'
        f"<title>{titulo}</title>{defs}"
        f'<path fill="{relleno}" fill-rule="evenodd" d="{d}"/>'
        "</svg>"
    )


def svg_compuesto(piezas, titulo, mono=False):
    """piezas = [(d, x, y, escala, gid)] ya colocadas en el lienzo."""
    anchos = [p[1] + p[3] * p[5] for p in piezas]
    altos = [p[2] + p[4] * p[5] for p in piezas]
    W, H = max(anchos), max(altos)
    defs = ""
    cuerpo = []
    for d, x, y, w, h, esc, gid in piezas:
        relleno = "currentColor" if mono else f"url(#{gid})"
        if not mono:
            defs += DEGRADADO.format(id=gid)
        cuerpo.append(f'<g transform="translate({x:.1f},{y:.1f}) scale({esc:.4f})"><path fill="{relleno}" fill-rule="evenodd" d="{d}"/></g>')
    bloque = f"<defs>{defs}</defs>" if defs else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}" role="img" aria-label="{titulo}">'
        f"<title>{titulo}</title>{bloque}{''.join(cuerpo)}</svg>"
    )


def main():
    ap = argparse.ArgumentParser(description="Saca los SVG de la marca a partir de los PNG")
    ap.add_argument("--origen", default="public/marca", help="donde estan isotipo.png y logo-vertical.png")
    ap.add_argument("--destino", default="public/marca", help="donde dejar los .svg")
    ap.add_argument("--costuras", type=int, default=85,
                    help="umbral de luminancia para recuperar las separaciones (0 = silueta limpia)")
    args = ap.parse_args()

    vert = Image.open(os.path.join(args.origen, "logo-vertical.png")).convert("RGBA")

    # Las tres franjas del logo apilado, encontradas por filas vacias de alfa
    # en vez de a ojo: 9-793 el monograma, 886-1095 "REMATE", 1150-1264
    # "CATIRE BELLO". Se recalculan para que esto siga valiendo con otro logo.
    a = np.array(vert)[..., 3] > 128
    filas = a.sum(axis=1)
    huecos, ini = [], None
    for i, v in enumerate(filas):
        if v == 0 and ini is None:
            ini = i
        elif v != 0 and ini is not None:
            if i - ini >= 20:
                huecos.append((ini, i))
            ini = None
    if len(huecos) < 1:
        raise SystemExit("No encuentro la separacion entre el monograma y el texto")
    corte = huecos[0][1]  # primera fila del texto

    d_iso, w_iso, h_iso = trazar_region(vert, (0, 0, vert.width, huecos[0][0]), costuras=args.costuras)
    d_txt, w_txt, h_txt = trazar_region(vert, (0, corte, vert.width, vert.height), costuras=0)

    os.makedirs(args.destino, exist_ok=True)
    salidas = {}

    salidas["isotipo.svg"] = svg_pieza(d_iso, w_iso, h_iso, "Catire Bello")
    salidas["isotipo-mono.svg"] = svg_pieza(d_iso, w_iso, h_iso, "Catire Bello", mono=True)
    salidas["texto.svg"] = svg_pieza(d_txt, w_txt, h_txt, "Remate Catire Bello")

    # VERTICAL: la proporcion y el hueco salen del original, no inventados.
    hueco = (huecos[0][1] - huecos[0][0])
    ancho = max(w_iso, w_txt)
    piezas_v = [
        (d_iso, (ancho - w_iso) / 2, 0, w_iso, h_iso, 1.0, "oroA"),
        (d_txt, (ancho - w_txt) / 2, h_iso + hueco, w_txt, h_txt, 1.0, "oroB"),
    ]
    salidas["logo-vertical.svg"] = svg_compuesto(piezas_v, "Remate Catire Bello")
    salidas["logo-vertical-mono.svg"] = svg_compuesto(piezas_v, "Remate Catire Bello", mono=True)

    # HORIZONTAL: el isotipo a la izquierda y el texto a su derecha, con el
    # texto escalado para que su altura sea el 78% del isotipo -- es la
    # proporcion que no deja el texto ni enano ni dominando al simbolo.
    esc_txt = (h_iso * 0.74) / h_txt
    # El hueco mide desde el borde del LIENZO del isotipo, y el hocico del
    # caballo llega casi hasta ese borde: con 0,12 la "R" de REMATE quedaba
    # pegada al morro. 0,22 es lo que deja respirar sin despegar las dos
    # mitades de la marca.
    sep = h_iso * 0.22
    tw, th = w_txt * esc_txt, h_txt * esc_txt
    alto = max(h_iso, th)
    piezas_h = [
        (d_iso, 0, (alto - h_iso) / 2, w_iso, h_iso, 1.0, "oroA"),
        (d_txt, w_iso + sep, (alto - th) / 2, w_txt, h_txt, esc_txt, "oroB"),
    ]
    salidas["logo-horizontal.svg"] = svg_compuesto(piezas_h, "Remate Catire Bello")
    salidas["logo-horizontal-mono.svg"] = svg_compuesto(piezas_h, "Remate Catire Bello", mono=True)

    for nombre, texto in salidas.items():
        ruta = os.path.join(args.destino, nombre)
        open(ruta, "w", encoding="utf-8").write(texto)
        print(f"  {nombre:28s} {len(texto)/1024:6.1f} KB")

    print(f"\nisotipo {w_iso}x{h_iso}   texto {w_txt}x{h_txt}   costuras={args.costuras}")


if __name__ == "__main__":
    main()
