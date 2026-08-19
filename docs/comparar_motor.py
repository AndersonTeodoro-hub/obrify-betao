"""Compara o PDF do motor (Edge Function gerar-fcq, pdf-lib) com o do oráculo
(preencher.py, reportlab+pypdf), com o MESMO input.

Não compara bytes: dois produtores diferentes nunca dão bytes iguais — nomes de
fonte, `q/Q`, codificação das cadeias, tudo difere sem que o documento difira.
Compara o que tem de ser igual para o documento ser o mesmo:

  1. cada cadeia escrita, com a posição onde assenta e o corpo da letra;
  2. os segmentos vectoriais — o visto não é texto, é traço;
  3. o impresso por baixo, que aparece nas duas listas por ser o mesmo ficheiro.

O fluxo de conteúdo é lido e interpretado aqui, em vez de se usar a extracção
do pypdf: o oráculo escreve as observações com `TL`/`T*` (avança a linha) e o
motor com um `Tm` por linha, e a reconstrução do pypdf não segue o primeiro
caso — dava uma diferença de posição que não existe no papel. Um parser de
cinco operadores é mais pequeno do que a explicação de porque é que o outro
mente.

Uso (a partir de docs/, com modelo.pdf = o impresso oficial):
    python preencher.py                        # -> fcq_preenchida.pdf
    deno run --allow-read --allow-write motor.ts   # -> fcq_motor.pdf
    python comparar_motor.py fcq_preenchida.pdf fcq_motor.pdf

reportlab e pypdf são precisos só para esta comparação. O motor que corre em
produção é Deno + pdf-lib e não usa Python nenhum.
"""
import re
import sys
from collections import Counter

from pypdf import PdfReader

TOLERANCIA = 0.05  # pt · abaixo disto é arredondamento do produtor, não desenho

NUM = r"-?\d+(?:\.\d+)?"
# Os operadores que estes dois produtores usam. Qualquer outro é do impresso e
# aparece igual nos dois lados.
FICHA = re.compile(
    rf"(?P<tf>/(?P<fonte>[^\s/]+)\s+(?P<corpo>{NUM})\s+Tf)"
    rf"|(?P<tl>(?P<leading>{NUM})\s+TL)"
    rf"|(?P<tm>(?:{NUM}\s+){{4}}(?P<tx>{NUM})\s+(?P<ty>{NUM})\s+Tm)"
    rf"|(?P<tstar>T\*)"
    rf"|(?P<tj>(?P<cadeia>\((?:[^()\\]|\\.)*\)|<[0-9A-Fa-f\s]*>)\s*Tj)"
    rf"|(?P<caminho>(?P<px>{NUM})\s+(?P<py>{NUM})\s+(?P<op>[ml])(?![a-zA-Z]))"
)


def descodificar(cadeia):
    """Cadeia literal `(...)` com escapes octais, ou hexadecimal `<...>`."""
    if cadeia.startswith("<"):
        hexa = re.sub(r"\s", "", cadeia[1:-1])
        return bytes.fromhex(hexa).decode("latin-1")
    corpo = cadeia[1:-1]
    corpo = re.sub(r"\\([0-7]{1,3})", lambda m: chr(int(m.group(1), 8)), corpo)
    return re.sub(r"\\(.)", r"\1", corpo)


def ler(caminho):
    """(texto, traços) da página 1: [(cadeia, x, y, corpo)] e Counter de m/l."""
    fluxo = PdfReader(caminho).pages[0].get_contents().get_data().decode("latin-1")
    texto, tracos = [], Counter()
    corpo, leading, x, y = 0.0, 0.0, 0.0, 0.0

    for m in FICHA.finditer(fluxo):
        if m.group("tf"):
            corpo = float(m.group("corpo"))
        elif m.group("tl"):
            leading = float(m.group("leading"))
        elif m.group("tm"):
            x, y = float(m.group("tx")), float(m.group("ty"))
        elif m.group("tstar"):
            y -= leading            # T* desce uma linha: é isto que o pypdf perde
        elif m.group("tj"):
            cadeia = descodificar(m.group("cadeia")).strip()
            if cadeia:
                texto.append((cadeia, round(x, 2), round(y, 2), round(corpo, 2)))
        else:
            tracos[(m.group("op"), round(float(m.group("px")), 2),
                    round(float(m.group("py")), 2))] += 1

    return texto, tracos


def parear(a, b):
    restantes = list(b)
    pares, sozinhos = [], []
    for item in a:
        alvo = next(
            (o for o in restantes if o[0] == item[0] and abs(o[3] - item[3]) < TOLERANCIA),
            None,
        )
        if alvo is None:
            sozinhos.append(item)
        else:
            restantes.remove(alvo)
            pares.append((item, alvo))
    return pares, sozinhos, restantes


def main(caminho_oraculo, caminho_motor):
    oraculo, traco_o = ler(caminho_oraculo)
    motor, traco_m = ler(caminho_motor)
    pares, so_oraculo, so_motor = parear(oraculo, motor)

    print(f"cadeias escritas · oráculo {len(oraculo)} · motor {len(motor)} · emparelhadas {len(pares)}")

    desviadas = [
        (o, m) for o, m in pares
        if abs(o[1] - m[1]) > TOLERANCIA or abs(o[2] - m[2]) > TOLERANCIA
    ]
    if desviadas:
        print(f"\nPOSIÇÕES DIFERENTES ({len(desviadas)}):")
        for o, m in desviadas[:40]:
            print(f"  {o[0][:44]!r}  oráculo ({o[1]}, {o[2]})  motor ({m[1]}, {m[2]})")
    else:
        print(f"posições: iguais dentro de {TOLERANCIA} pt")

    for titulo, lista in (("SÓ NO ORÁCULO", so_oraculo), ("SÓ NO MOTOR", so_motor)):
        if lista:
            print(f"\n{titulo} ({len(lista)}):")
            for t in lista[:40]:
                print(f"  {t}")

    print(f"\nsegmentos vectoriais · oráculo {sum(traco_o.values())} · motor {sum(traco_m.values())}")
    if traco_o == traco_m:
        print("segmentos: idênticos")
    else:
        print("SEGMENTOS DIFERENTES:")
        for t, n in sorted((traco_o - traco_m).items()):
            print(f"  só no oráculo ×{n}: {t}")
        for t, n in sorted((traco_m - traco_o).items()):
            print(f"  só no motor   ×{n}: {t}")

    igual = not desviadas and not so_oraculo and not so_motor and traco_o == traco_m
    print("\nRESULTADO:", "EQUIVALENTES" if igual else "COM DIFERENÇAS — ver acima")
    return 0 if igual else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
