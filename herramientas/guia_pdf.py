# -*- coding: utf-8 -*-
"""
herramientas/guia_pdf.py  -  LA GUIA DEL ADMINISTRADOR, EN PDF CON LA MARCA

  python herramientas/guia_pdf.py        (desde la raiz del repositorio)
  -> docs/Guia-del-administrador-Remate-Catire-Bello.pdf

POR QUE UN SCRIPT Y NO UN PDF EN EL REPOSITORIO (14/10/2026, ADR-053)

  El PDF es un ARTEFACTO: se deriva de `docs/GUIA_LICENCIATARIO.md`, que es la
  unica fuente del texto. Guardar el binario versionado dejaria dos copias de
  la misma guia, y la del PDF se quedaria vieja en cuanto alguien corrigiera el
  documento -- justo lo que le paso a GUIA_USO.md. Mismo criterio que
  `herramientas/marca_vectorizar.py` con los SVG.

LO QUE ESTE SCRIPT APRENDIO POR LAS MALAS

  La primera version se genero SIN UN SOLO ERROR y era ilegible: faltaba
  `NextPageTemplate` antes del salto de pagina, asi que ReportLab cambiaba de
  pagina pero no de plantilla y pintaba la portada encima de todo el
  documento. Un PDF que pesa 786 KB y no revienta parece correcto. Solo se vio
  abriendolo. Si tocas las plantillas, MIRA EL RESULTADO.

DEPENDENCIAS

  pip install reportlab pillow

  Pillow es opcional: si no esta, el PDF sale igual pero pesa cuatro veces mas,
  porque los PNG de marca se incrustan a tamano completo.
"""
import re, os, datetime
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph,
                                Spacer, Table, TableStyle, Image, PageBreak,
                                KeepTogether, HRFlowable, NextPageTemplate)
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

# Rutas del repositorio: este script vive en herramientas/
RAIZ   = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE   = os.path.join(RAIZ, "docs")          # donde se escribe el PDF
MARCA  = os.path.join(RAIZ, "public", "marca")

# ------------------------------------------------------------------ imagenes
#  Los PNG de marca pesan 1 MB y aqui se pintan a 92 mm y a 6 mm. Incrustarlos
#  tal cual dejaba el PDF en 2,1 MB -- un documento que se manda por correo.
#  Se reescalan a lo que de verdad hace falta antes de incrustarlos.
def reducir(src, ancho_px):
    try:
        from PIL import Image as PILImage
    except ImportError:
        return src
    if not os.path.exists(src):
        return src
    im = PILImage.open(src).convert("RGBA")
    if im.width <= ancho_px:
        return src
    alto = max(1, round(im.height * ancho_px / im.width))
    im = im.resize((ancho_px, alto), PILImage.LANCZOS)
    import tempfile
    dst = os.path.join(tempfile.gettempdir(), "_r_" + os.path.basename(src))
    im.save(dst, optimize=True)
    return dst

# ---------------------------------------------------------------- la marca
ORO        = colors.HexColor("#d7af5d")
ORO_SOMBRA = colors.HexColor("#865d22")
NEGRO      = colors.HexColor("#09090b")
TINTA      = colors.HexColor("#18181b")
GRIS       = colors.HexColor("#52525b")
GRIS_SUAVE = colors.HexColor("#a1a1aa")
LINEA      = colors.HexColor("#e4e4e7")
AMBAR_F    = colors.HexColor("#fdf6e3")
AMBAR_B    = colors.HexColor("#b4881f")

PLATAFORMA = "Remate Catire Bello"
EMPRESA    = "Jercol Technologies"
TITULO     = "Cómo operar tu casa"
SUBTITULO  = "Guía del administrador"

# fuentes con acentos y ñ
def registrar():
    cands = [
        ("Cuerpo", "DejaVuSans.ttf", "DejaVuSans-Bold.ttf", "DejaVuSans-Oblique.ttf", "DejaVuSans-BoldOblique.ttf"),
        ("Cuerpo", "LiberationSans-Regular.ttf", "LiberationSans-Bold.ttf", "LiberationSans-Italic.ttf", "LiberationSans-BoldItalic.ttf"),
    ]
    raices = ["/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/truetype/liberation",
              "/usr/share/fonts/truetype/liberation2"]
    for nombre, r, b, i, bi in cands:
        rutas = []
        for f in (r, b, i, bi):
            hallado = None
            for raiz in raices:
                p = os.path.join(raiz, f)
                if os.path.exists(p):
                    hallado = p; break
            rutas.append(hallado)
        if all(rutas):
            pdfmetrics.registerFont(TTFont("Cuerpo", rutas[0]))
            pdfmetrics.registerFont(TTFont("Cuerpo-Bold", rutas[1]))
            pdfmetrics.registerFont(TTFont("Cuerpo-It", rutas[2]))
            pdfmetrics.registerFont(TTFont("Cuerpo-BoldIt", rutas[3]))
            from reportlab.pdfbase.pdfmetrics import registerFontFamily
            registerFontFamily("Cuerpo", normal="Cuerpo", bold="Cuerpo-Bold",
                               italic="Cuerpo-It", boldItalic="Cuerpo-BoldIt")
            return True
    return False

TIENE_TTF = registrar()
F  = "Cuerpo"      if TIENE_TTF else "Helvetica"
FB = "Cuerpo-Bold" if TIENE_TTF else "Helvetica-Bold"
FM = "Courier"

# ---------------------------------------------------------------- estilos
def st(nombre, **kw):
    base = dict(name=nombre, fontName=F, fontSize=9.5, leading=14.5,
                textColor=TINTA, alignment=TA_LEFT, spaceBefore=0, spaceAfter=0)
    base.update(kw)
    return ParagraphStyle(**base)

S = {
  "h1":   st("h1", fontName=FB, fontSize=19, leading=24, textColor=NEGRO, spaceAfter=2),
  "h2":   st("h2", fontName=FB, fontSize=13, leading=17, textColor=ORO_SOMBRA, spaceBefore=16, spaceAfter=5),
  "h3":   st("h3", fontName=FB, fontSize=10.5, leading=14, textColor=NEGRO, spaceBefore=9, spaceAfter=3),
  "p":    st("p", spaceAfter=6),
  "li":   st("li", leftIndent=12, bulletIndent=2, spaceAfter=3),
  "nota": st("nota", fontSize=9, leading=13.5, textColor=AMBAR_B, leftIndent=9, rightIndent=9,
             spaceBefore=3, spaceAfter=3),
  "th":   st("th", fontName=FB, fontSize=7.8, leading=10.5, textColor=GRIS),
  "td":   st("td", fontSize=9, leading=13),
  "pie":  st("pie", fontSize=7.5, leading=10, textColor=GRIS_SUAVE),
}

# ------------------------------------------------- markdown en linea -> rl
def enlinea(t):
    t = (t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
    t = re.sub(r"`([^`]+)`", r'<font face="%s" size="8.5">\1</font>' % FM, t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<i>\1</i>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<font color="#865d22"><u>\1</u></font>', t)
    t = t.replace("—", "—").replace("«", "«").replace("»", "»")
    return t

def fila_tabla(linea):
    partes = [c.strip() for c in linea.strip().strip("|").split("|")]
    return partes

def construir_flujo(md):
    fl = []
    lineas = md.split("\n")
    i = 0
    n = len(lineas)
    while i < n:
        L = lineas[i]
        s = L.strip()

        if not s:
            i += 1; continue

        if s.startswith("# "):
            fl.append(Paragraph(enlinea(s[2:]), S["h1"])); i += 1; continue
        if s.startswith("## "):
            fl.append(Spacer(1, 4))
            fl.append(HRFlowable(width="100%", thickness=0.6, color=LINEA,
                                 spaceBefore=0, spaceAfter=7))
            fl.append(Paragraph(enlinea(s[3:]), S["h2"])); i += 1; continue
        if s.startswith("### "):
            fl.append(Paragraph(enlinea(s[4:]), S["h3"])); i += 1; continue

        if s.startswith("---"):
            i += 1; continue

        # cita -> recuadro ambar
        if s.startswith(">"):
            trozo = []
            while i < n and lineas[i].strip().startswith(">"):
                trozo.append(lineas[i].strip().lstrip(">").strip()); i += 1
            txt = " ".join(x for x in trozo if x)
            caja = Table([[Paragraph(enlinea(txt), S["nota"])]], colWidths=[165*mm])
            caja.setStyle(TableStyle([
                ("BACKGROUND", (0,0), (-1,-1), AMBAR_F),
                ("LINEBEFORE", (0,0), (0,-1), 2.2, ORO),
                ("LEFTPADDING", (0,0), (-1,-1), 9),
                ("RIGHTPADDING", (0,0), (-1,-1), 9),
                ("TOPPADDING", (0,0), (-1,-1), 7),
                ("BOTTOMPADDING", (0,0), (-1,-1), 7),
            ]))
            fl.append(Spacer(1, 3)); fl.append(caja); fl.append(Spacer(1, 7))
            continue

        # tabla
        if s.startswith("|"):
            crudas = []
            while i < n and lineas[i].strip().startswith("|"):
                crudas.append(lineas[i]); i += 1
            if len(crudas) >= 2:
                cab = fila_tabla(crudas[0])
                cuerpo = [fila_tabla(x) for x in crudas[2:]]
                cols = len(cab)
                ancho = 165*mm
                if cols == 2:
                    anchos = [ancho*0.34, ancho*0.66]
                elif cols == 3:
                    anchos = [ancho*0.26, ancho*0.37, ancho*0.37]
                else:
                    anchos = [ancho/cols]*cols
                datos = [[Paragraph(enlinea(c), S["th"]) for c in cab]]
                for r in cuerpo:
                    r = (r + [""]*cols)[:cols]
                    datos.append([Paragraph(enlinea(c), S["td"]) for c in r])
                t = Table(datos, colWidths=anchos, repeatRows=1, hAlign="LEFT")
                t.setStyle(TableStyle([
                    ("VALIGN", (0,0), (-1,-1), "TOP"),
                    ("LINEBELOW", (0,0), (-1,0), 0.9, ORO),
                    ("LINEBELOW", (0,1), (-1,-2), 0.35, LINEA),
                    ("LEFTPADDING", (0,0), (-1,-1), 0),
                    ("RIGHTPADDING", (0,0), (-1,-1), 8),
                    ("TOPPADDING", (0,0), (-1,-1), 5),
                    ("BOTTOMPADDING", (0,0), (-1,-1), 5),
                ]))
                fl.append(Spacer(1, 4)); fl.append(t); fl.append(Spacer(1, 9))
            continue

        # listas
        m_ol = re.match(r"^(\d+)\.\s+(.*)$", s)
        if s.startswith("- ") or m_ol:
            while i < n:
                q = lineas[i].strip()
                mo = re.match(r"^(\d+)\.\s+(.*)$", q)
                if q.startswith("- "):
                    fl.append(Paragraph(enlinea(q[2:]), S["li"], bulletText="•"))
                elif mo:
                    fl.append(Paragraph(enlinea(mo.group(2)), S["li"], bulletText=mo.group(1)+"."))
                elif q == "":
                    sig = lineas[i+1].strip() if i+1 < n else ""
                    if not (sig.startswith("- ") or re.match(r"^\d+\.\s", sig)):
                        break
                else:
                    break
                i += 1
            fl.append(Spacer(1, 4))
            continue

        # parrafo
        trozo = []
        while i < n and lineas[i].strip() and not re.match(r"^(#|>|\||-\s|\d+\.\s|---)", lineas[i].strip()):
            trozo.append(lineas[i].strip()); i += 1
        fl.append(Paragraph(enlinea(" ".join(trozo)), S["p"]))
    return fl

# ---------------------------------------------------------------- plantilla
class Doc(BaseDocTemplate):
    def __init__(self, ruta, **kw):
        BaseDocTemplate.__init__(self, ruta, pagesize=A4,
                                 leftMargin=22*mm, rightMargin=23*mm,
                                 topMargin=26*mm, bottomMargin=20*mm, **kw)
        marco = Frame(self.leftMargin, self.bottomMargin,
                      self.width, self.height, id="cuerpo",
                      leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
        self.addPageTemplates([
            PageTemplate(id="portada", frames=[Frame(0, 0, A4[0], A4[1], id="p")], onPage=self.portada),
            PageTemplate(id="cuerpo", frames=[marco], onPage=self.adorno),
        ])

    def portada(self, c, d):
        W, H = A4
        c.setFillColor(NEGRO); c.rect(0, 0, W, H, stroke=0, fill=1)
        # franja de oro
        c.setFillColor(ORO); c.rect(0, H-10*mm, W, 10*mm, stroke=0, fill=1)
        logo = reducir(os.path.join(MARCA, "logo-horizontal.png"), 1100)
        if os.path.exists(logo):
            from reportlab.lib.utils import ImageReader
            im = ImageReader(logo); iw, ih = im.getSize()
            anc = 92*mm; alt = anc*ih/iw
            c.drawImage(im, (W-anc)/2, H*0.60, width=anc, height=alt,
                        mask="auto", preserveAspectRatio=True)
        c.setFillColor(colors.white); c.setFont(FB, 30)
        c.drawCentredString(W/2, H*0.44, TITULO)
        c.setFillColor(ORO); c.setFont(F, 13)
        c.drawCentredString(W/2, H*0.44-11*mm, SUBTITULO)
        c.setStrokeColor(ORO); c.setLineWidth(0.8)
        c.line(W/2-26*mm, H*0.44-18*mm, W/2+26*mm, H*0.44-18*mm)
        c.setFillColor(colors.HexColor("#8a8a93")); c.setFont(F, 8.6)
        c.drawCentredString(W/2, 28*mm, "%s  ·  Desarrollado por %s" % (PLATAFORMA, EMPRESA))
        c.drawCentredString(W/2, 22*mm, datetime.date.today().strftime("Edición del %d/%m/%Y"))

    def adorno(self, c, d):
        W, H = A4
        c.setFillColor(ORO); c.rect(0, H-4*mm, W, 4*mm, stroke=0, fill=1)
        iso = reducir(os.path.join(MARCA, "isotipo.png"), 120)
        if os.path.exists(iso):
            from reportlab.lib.utils import ImageReader
            im = ImageReader(iso); iw, ih = im.getSize()
            alt = 6.2*mm; anc = alt*iw/ih
            c.drawImage(im, 22*mm, H-16.5*mm, width=anc, height=alt, mask="auto")
        c.setFillColor(GRIS_SUAVE); c.setFont(F, 7.6)
        c.drawRightString(W-23*mm, H-14.5*mm, "%s · %s" % (TITULO, SUBTITULO))
        c.setStrokeColor(LINEA); c.setLineWidth(0.5)
        c.line(22*mm, H-19*mm, W-23*mm, H-19*mm)
        c.line(22*mm, 15*mm, W-23*mm, 15*mm)
        c.setFillColor(GRIS_SUAVE); c.setFont(F, 7.4)
        c.drawString(22*mm, 11*mm, "%s · %s" % (PLATAFORMA, EMPRESA))
        c.drawRightString(W-23*mm, 11*mm, str(d.page - 1))

md = open(os.path.join(BASE, "GUIA_LICENCIATARIO.md"), encoding="utf-8").read()
# NextPageTemplate ANTES del salto: sin esto el salto cambia de pagina pero NO
# de plantilla, y la portada se sigue pintando encima de todo el documento.
# Pasó el 14/10: el PDF se generó sin un solo error y era ilegible.
flujo = [NextPageTemplate("cuerpo"), PageBreak()] + construir_flujo(md)
salida = os.path.join(BASE, "Guia-del-administrador-Remate-Catire-Bello.pdf")
doc = Doc(salida)
doc.title = "%s — %s" % (TITULO, SUBTITULO)
doc.author = EMPRESA
doc.subject = "Guía operativa para el administrador de una casa licenciada"
doc.build(flujo)
print("OK:", salida, os.path.getsize(salida), "bytes")
