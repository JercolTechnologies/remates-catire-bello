from PIL import Image
import numpy as np

SRC = '/root/.claude/uploads/550d5cca-06ca-53c2-8022-521ebd56cf69/8c5a2509-image.jpg'
im = Image.open(SRC).convert('RGB')
a = np.asarray(im).astype(float)

FONDO = (9, 9, 11)          # zinc-950, el fondo de la app

def con_alfa(arr, lo=9.0, hi=58.0):
    """Levanta el oro del negro.

    El JPG no tiene canal alfa, asi que hay que deducirlo. La primera version
    lo sacaba de la luminancia a secas y dejaba un HALO RECTANGULAR visible
    sobre fondo blanco: el fondo del archivo no es negro puro sino un
    degradado vertical que llega a #242429 arriba, y esa diferencia se quedaba
    medio opaca.

    Asi que el fondo se MIDE y se resta. Las columnas de los extremos no
    tienen tinta en ninguna fila, asi que su mediana por fila es el valor del
    degradado a esa altura. El alfa sale del residuo, no del valor absoluto, y
    por eso conserva los dorados oscuros (#865D22) sin arrastrar el fondo.
    """
    lum = arr.mean(2)
    h, w, _ = arr.shape
    borde = np.concatenate([lum[:, :260], lum[:, w-260:]], axis=1)
    fondo = np.median(borde, axis=1)[:, None]          # el degradado, fila a fila
    residuo = lum - fondo
    al = np.clip((residuo - lo) / (hi - lo), 0, 1)
    rgb = np.clip((arr - fondo[..., None] * 0.9) / np.maximum(al, 0.22)[..., None], 0, 255)
    rgb = np.where((al >= 0.999)[..., None], arr, rgb)
    return Image.fromarray(np.dstack([rgb, al * 255]).astype(np.uint8), 'RGBA')

def recortar(img, margen=0):
    bb = img.getchannel('A').point(lambda p: 255 if p > 8 else 0).getbbox()
    x0, y0, x1, y1 = bb
    return img.crop((max(0,x0-margen), max(0,y0-margen),
                     min(img.width,x1+margen), min(img.height,y1+margen)))

def cuadrar(img, lado, relleno=0.86, fondo=None):
    """Centra en un cuadrado, ocupando `relleno` del lado. Fondo None = transparente."""
    r = recortar(img)
    esc = (lado * relleno) / max(r.width, r.height)
    r = r.resize((max(1,round(r.width*esc)), max(1,round(r.height*esc))), Image.LANCZOS)
    base = Image.new('RGBA', (lado, lado), (*(fondo or (0,0,0)), 0 if fondo is None else 255))
    base.paste(r, ((lado-r.width)//2, (lado-r.height)//2), r)
    return base

rgba = con_alfa(a)

# --- los tres bloques que detectamos midiendo la imagen
isotipo  = recortar(rgba.crop((500, 390, 1550, 1200)))     # CB + caballo
remate   = recortar(rgba.crop((350, 1260, 1700, 1500)))    # REMATE
catire   = recortar(rgba.crop((400, 1525, 1650, 1670)))    # CATIRE BELLO
vertical = recortar(rgba.crop((340, 390, 1710, 1670)))     # el conjunto

isotipo.save('isotipo.png')
vertical.save('logo-vertical.png')

# --- LOGO HORIZONTAL: el isotipo a la izquierda, las dos palabras apiladas a
# la derecha. El original viene apilado, asi que esta version hay que
# componerla; no existe en el archivo de partida.
H = 420
iso_h = isotipo.resize((round(isotipo.width*H/isotipo.height), H), Image.LANCZOS)
anchoTexto = round(H * 2.35)
rem_h = remate.resize((anchoTexto, round(remate.height*anchoTexto/remate.width)), Image.LANCZOS)
cat_w = round(anchoTexto * 0.92)
cat_h = catire.resize((cat_w, round(catire.height*cat_w/catire.width)), Image.LANCZOS)
hueco = round(H * 0.08)
bloque_alto = rem_h.height + hueco + cat_h.height
sep = round(H * 0.18)
W = iso_h.width + sep + anchoTexto
horizontal = Image.new('RGBA', (W, max(H, bloque_alto)), (0,0,0,0))
horizontal.paste(iso_h, (0, (horizontal.height-H)//2), iso_h)
y = (horizontal.height - bloque_alto)//2
horizontal.paste(rem_h, (iso_h.width+sep, y), rem_h)
horizontal.paste(cat_h, (iso_h.width+sep+(anchoTexto-cat_w)//2, y+rem_h.height+hueco), cat_h)
horizontal = recortar(horizontal)
horizontal.save('logo-horizontal.png')

# --- iconos
cuadrar(isotipo, 512, 0.88).save('icon.png')
cuadrar(isotipo, 192, 0.88).save('icon-192.png')
# Apple no respeta la transparencia: va sobre el fondo de la marca.
cuadrar(isotipo, 180, 0.80, fondo=FONDO).save('apple-icon.png')
ico = cuadrar(isotipo, 256, 0.92)
ico.save('favicon.ico', sizes=[(16,16),(32,32),(48,48),(64,64)])

# --- opengraph 1200x630, sobre el fondo de la marca
og = Image.new('RGBA', (1200, 630), (*FONDO, 255))
lg = horizontal.resize((round(horizontal.width*430/horizontal.height), 430), Image.LANCZOS)
if lg.width > 1020:
    lg = horizontal.resize((1020, round(horizontal.height*1020/horizontal.width)), Image.LANCZOS)
og.paste(lg, ((1200-lg.width)//2, (630-lg.height)//2), lg)
og.convert('RGB').save('opengraph-image.png')

for f in ['isotipo','logo-vertical','logo-horizontal','icon','icon-192','apple-icon','opengraph-image']:
    i = Image.open(f + '.png'); print('%-20s %sx%s  %s' % (f+'.png', i.width, i.height, i.mode))
