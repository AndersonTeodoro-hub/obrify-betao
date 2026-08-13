import json, io
from reportlab.pdfgen import canvas
from pypdf import PdfReader, PdfWriter

M = json.load(open("mapa_campos.json"))
W, H = M["documento"]["largura_pt"], M["documento"]["altura_pt"]
def Y(top): return H - top

def preencher(dados, saida):
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=(W, H))
    c.setFillColorRGB(0, 0, 0.55)          # azul-escuro para distinguir do impresso
    # cabecalho
    cab = M["cabecalho"]
    for k, fs in (("n_obra",7),("designacao",7),("numero",7),("n_anexos",7),("local_inspecao",6.5)):
        v = dados.get(k)
        if v:
            c.setFont("Helvetica", fs)
            c.drawString(cab[k]["x"], Y(cab[k]["y_baseline"])+1, str(v))
    # checkboxes + anotacoes
    idx = {l["id"]: l for l in M["linhas"]}
    for lid, cols in dados.get("checks", {}).items():
        L = idx[lid]
        for col, val in cols.items():
            pos = L["check"][col]
            x, y = pos["x"], Y(pos["cy"])
            if val == "C":                  # conforme -> visto vetorial
                c.setLineWidth(1.1); c.setStrokeColorRGB(0,0,0.55)
                pth = c.beginPath(); pth.moveTo(x-2.8, y-0.2); pth.lineTo(x-0.9, y-2.4); pth.lineTo(x+3.0, y+2.8)
                c.drawPath(pth)
            elif val == "NC":
                c.setFont("Helvetica-Bold", 7.5); c.drawCentredString(x, y-2.6, "X")
            elif val == "NA":
                c.setFont("Helvetica", 8); c.drawCentredString(x, y-2.6, "/")
    for lid, txt in dados.get("anotacoes", {}).items():
        L = idx[lid]; c.setFont("Helvetica", 5.5)
        c.drawString(L["anotacao"]["x"], Y(L["anotacao"]["y_baseline"])+1.5, txt[:38])
    # blocos elaborado por / data
    xs = M["blocos_assinatura"]["x_por_coluna"]
    for b in M["blocos_assinatura"]["blocos"]:
        d = dados.get("assinaturas", {}).get(b["seccao"], {})
        for col, v in d.items():
            c.setFont("Helvetica", 5.2)
            c.drawString(xs[col]+0.5, Y(b["y_elaborado"])+1.5, v.get("por","")[:11])
            c.drawString(xs[col]+0.5, Y(b["y_data"])+1.5, v.get("data","")[:11])
    # observacoes
    obs = dados.get("observacoes")
    if obs:
        o = M["observacoes"]; c.setFont("Helvetica", 6.5)
        t = c.beginText(o["x"]+38, Y(o["y_topo"])); t.setLeading(8)
        import textwrap
        for ln in textwrap.wrap(obs, 105)[:3]: t.textLine(ln)
        c.drawText(t)
    c.save(); buf.seek(0)
    base = PdfReader("modelo.pdf"); over = PdfReader(buf)
    w = PdfWriter(); pg = base.pages[0]; pg.merge_page(over.pages[0]); w.add_page(pg)
    with open(saida, "wb") as f: w.write(f)

if __name__ == "__main__":
    dados = {
      "n_obra":"2602","designacao":"Empreendimento Marina Sul – Bloco B",
      "numero":"033 / 047","n_anexos":"3",
      "local_inspecao":"Bloco B / Piso 0 / Núcleo A – Sapatas S12 a S15",
      "checks":{ "L01":{"insp":"C"}, "L02":{"insp":"C"}, "L03":{"insp":"NC","reinsp1":"C"},
                 "L04":{"insp":"C"}, "L05":{"insp":"C"}, "L06":{"insp":"C"},
                 "L07":{"insp":"C"}, "L09":{"insp":"C"}, "L15":{"insp":"C"},
                 "L21":{"insp":"NA"}, "L22":{"insp":"NA"}, "L26":{"insp":"NA"},
                 "L28":{"insp":"C"}, "L29":{"insp":"C"}, "L31":{"insp":"C"},
                 "L32":{"insp":"NC","reinsp1":"C"}, "L34":{"insp":"C"} },
      "anotacoes":{"L03":"Escoramento reforçado em 14/07","L32":"Chocho localizado – reparado 16/07"},
      "assinaturas":{"implantacao":{"insp":{"por":"J. Salvador","data":"10/07/2026"}},
                     "cofragem":{"insp":{"por":"J. Salvador","data":"12/07/2026"},
                                 "reinsp1":{"por":"J. Salvador","data":"14/07/2026"}},
                     "armaduras":{"insp":{"por":"J. Salvador","data":"15/07/2026"}},
                     "betonagem":{"insp":{"por":"J. Salvador","data":"16/07/2026"}},
                     "pos_betonagem":{"insp":{"por":"J. Salvador","data":"18/07/2026"}}},
      "observacoes":"Betonagem coberta pelo PAB n.º 47. Guias de remessa 118432, 118433 e 118441 em anexo (3 anexos). Volume total 42,50 m3 para 40,00 m3 previstos (+6,3%). Classe C30/37 conforme aprovado."
    }
    preencher(dados, "fcq_preenchida.pdf")
    print("ok")
