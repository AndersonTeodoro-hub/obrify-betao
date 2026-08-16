// Painel de controlo da obra — o «nível 2» do painel-e-mapa-controlo-betonagem:
// «como está a minha obra?».
//
// ── O QUE MOSTRA, E PORQUÊ ESTES ────────────────────────────────────────────
// O documento de especificação enumera sete acumuladores. Aqui estão os que
// são calculáveis com o que a plataforma já regista:
//
//   A1  volume por betonagem (guias vs. previsto no PAB)  → «à espera» e desvio
//   A4  volume por obra                                    → o cartão do topo
//   A5  volume por classe de betão                         → a base da amostragem
//   A6  volume por central                                 → reconciliação
//
// Ficam de fora, e digo porquê em vez de os desenhar vazios:
//   A2  por elemento e A3 por frente — calculáveis, mas o pedido desta entrega
//       não os inclui; entram quando forem pedidos.
//   A7  por lote de controlo — depende de provetes, que não existem. É o
//       acumulador que o documento diz ser o mais importante, porque é o único
//       que previne em vez de constatar. Fica registado como o que falta.
//
// ── A REGRA DE LEITURA DO DESVIO ────────────────────────────────────────────
// «O desvio de volume só é conclusivo com a betonagem fechada. Num PAB em
// curso, negativo é o estado normal.» O painel separa as duas situações — e não
// o fazer geraria alarme falso todos os dias, que é a forma mais rápida de
// fazer com que ninguém olhe para ele.
//
// ── E O SINAL MAIS IMPORTANTE ───────────────────────────────────────────────
// «O sinal mais importante é a ausência de atividade, não os números
// vermelhos.» Daí o bloco dos aprovados sem guias vir antes das somas: uma obra
// que betona e não regista é mais grave do que uma obra com desvios
// registados.
//
// Tudo calculado a pedido a partir de duas leituras. Sem migração, sem vista
// materializada, sem contador guardado. Gráficos em SVG escrito à mão — sem
// dependências.

import {
  lerCentrais,
  lerFrentes,
  lerGuiasDaObra,
  lerPabs,
  mensagemDeErro,
  type Central,
  type EstadoPab,
  type Frente,
  type Guia,
  type Obra,
  type Pab,
} from './dominio'

const ESTADOS: EstadoPab[] = [
  'SUBMETIDO',
  'APROVADO',
  'EM_BETONAGEM',
  'BETONADO',
  'FCQ_FECHADA',
  'REJEITADO',
  'ANULADO',
]

type Dados = {
  pabs: Pab[]
  guias: Guia[]
  centrais: Central[]
  frentes: Frente[]
}

// ── cálculo ─────────────────────────────────────────────────────────────────

function somaPor<T>(itens: T[], chave: (i: T) => string, valor: (i: T) => number) {
  const mapa = new Map<string, { soma: number; contagem: number }>()
  for (const item of itens) {
    const k = chave(item)
    const actual = mapa.get(k) ?? { soma: 0, contagem: 0 }
    mapa.set(k, { soma: actual.soma + valor(item), contagem: actual.contagem + 1 })
  }
  return [...mapa.entries()].sort((a, b) => b[1].soma - a[1].soma)
}

const volumeDe = (g: Guia): number => Number(g.volume_m3)

function horaCurta(iso: string): string {
  const d = new Date(iso)
  return Number.isFinite(d.getTime())
    ? d.toLocaleString('pt-PT', { dateStyle: 'short', timeStyle: 'short' })
    : iso
}

// ── desenho ─────────────────────────────────────────────────────────────────
// Com o DOM e textContent: estes valores vêm da base e foram escritos por
// pessoas.

function bloco(titulo: string, barra = false): HTMLElement {
  const cabeca = document.createElement(barra ? 'div' : 'h3')
  cabeca.textContent = titulo
  if (barra) cabeca.className = 'doc-barra'

  const seccao = document.createElement('section')
  seccao.className = 'doc-bloco'
  seccao.append(cabeca)
  return seccao
}

function campo(etiqueta: string, valor: string, realce = false): HTMLElement {
  const rotulo = document.createElement('span')
  rotulo.className = 'etiqueta'
  rotulo.textContent = etiqueta

  const conteudo = document.createElement('span')
  conteudo.className = realce ? 'valor valor-grande' : 'valor'
  conteudo.textContent = valor

  const linha = document.createElement('div')
  linha.className = 'campo'
  linha.append(rotulo, conteudo)
  return linha
}

function linhaDe(...campos: HTMLElement[]): HTMLElement {
  const fila = document.createElement('div')
  fila.className = `linha-campos linha-${campos.length}`
  fila.append(...campos)
  return fila
}

/**
 * Uma barra proporcional, em SVG escrito à mão.
 *
 * Sem biblioteca: uma barra é um rectângulo, e trazer um motor de gráficos para
 * desenhar rectângulos seria pagar uma dependência para não escrever seis
 * linhas.
 */
function barra(fraccao: number, cor: string): SVGSVGElement {
  const larguraTotal = 100
  const util = Math.max(0, Math.min(1, fraccao))

  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  svg.setAttribute('viewBox', `0 0 ${larguraTotal} 8`)
  svg.setAttribute('preserveAspectRatio', 'none')
  svg.setAttribute('class', 'barra')
  svg.setAttribute('aria-hidden', 'true')

  const fundo = document.createElementNS('http://www.w3.org/2000/svg', 'rect')
  fundo.setAttribute('width', String(larguraTotal))
  fundo.setAttribute('height', '8')
  fundo.setAttribute('fill', '#EAE8E3')

  const cheio = document.createElementNS('http://www.w3.org/2000/svg', 'rect')
  cheio.setAttribute('width', String(util * larguraTotal))
  cheio.setAttribute('height', '8')
  cheio.setAttribute('fill', cor)

  svg.append(fundo, cheio)
  return svg
}

/** Uma linha de tabela com etiqueta, barra proporcional e valor. */
function linhaComBarra(
  etiqueta: string,
  detalhe: string,
  valor: string,
  fraccao: number,
  cor: string,
): HTMLElement {
  const nome = document.createElement('span')
  nome.className = 'painel-nome'
  nome.textContent = etiqueta

  const sub = document.createElement('span')
  sub.className = 'sub-doc'
  sub.textContent = detalhe

  const texto = document.createElement('span')
  texto.className = 'corpo-doc'
  texto.append(nome, sub)

  const numero = document.createElement('span')
  numero.className = 'mono painel-valor'
  numero.textContent = valor

  const linha = document.createElement('div')
  linha.className = 'painel-linha'
  linha.append(texto, numero, barra(fraccao, cor))
  return linha
}

function vazio(texto: string): HTMLElement {
  const p = document.createElement('p')
  p.className = 'vazio'
  p.textContent = texto
  return p
}

// ── ecrã ────────────────────────────────────────────────────────────────────

export function montarEcraPainel(destino: HTMLElement, obra: Obra, aoVoltar: () => void): void {
  destino.innerHTML = `
    <div class="envolvente-doc">
      <button id="painel-voltar" class="voltar" type="button">‹ Pedidos</button>
      <article class="doc" id="painel"></article>
      <p id="erro-painel" class="erro" role="alert" hidden></p>
    </div>
  `

  const painel = destino.querySelector<HTMLElement>('#painel')!
  const erro = destino.querySelector<HTMLParagraphElement>('#erro-painel')!

  destino.querySelector<HTMLButtonElement>('#painel-voltar')!.addEventListener('click', aoVoltar)

  const mostrarErro = (causa: unknown): void => {
    erro.textContent = mensagemDeErro(causa)
    erro.hidden = false
  }

  const desenhar = (dados: Dados): void => {
    const { pabs, guias, centrais, frentes } = dados
    const nomeCentral = new Map(centrais.map((c) => [c.id, c.designacao]))
    const nomeFrente = new Map(frentes.map((f) => [f.id, f.designacao]))
    const guiasPorPab = new Map<string, Guia[]>()
    for (const g of guias) guiasPorPab.set(g.pab_id, [...(guiasPorPab.get(g.pab_id) ?? []), g])

    const betonado = guias.reduce((s, g) => s + volumeDe(g), 0)
    // O previsto conta só o que ainda vale: um PAB rejeitado ou anulado não
    // representa betão nenhum, e somá-lo faria o consumo parecer menor do que é.
    const vivos = pabs.filter((p) => p.estado !== 'REJEITADO' && p.estado !== 'ANULADO')
    const previsto = vivos.reduce((s, p) => s + Number(p.volume_previsto_m3), 0)

    painel.replaceChildren()

    // ── cabeçalho ───────────────────────────────────────────────────────────
    const titulo = document.createElement('div')
    titulo.className = 'doc-titulo'
    const h1 = document.createElement('h1')
    h1.textContent = 'Painel de controlo da obra'
    const ident = document.createElement('span')
    ident.className = 'mono'
    ident.textContent = `Obra n.º ${obra.codigo}`
    titulo.append(h1, ident)
    painel.append(titulo)

    // ── o sinal que vem primeiro: o que está à espera de betão ──────────────
    // «Uma obra que betona e não regista é mais grave do que uma obra com
    // desvios registados.»
    const aEsperar = pabs.filter(
      (p) => p.estado === 'APROVADO' && (guiasPorPab.get(p.id) ?? []).length === 0,
    )
    const espera = bloco('Aprovados à espera de betonagem', true)
    if (aEsperar.length === 0) {
      espera.append(vazio('Nenhum PAB aprovado está sem guias.'))
    } else {
      const hoje = new Date().toISOString().slice(0, 10)
      for (const p of aEsperar) {
        const atrasado = p.data_prevista < hoje
        espera.append(
          linhaComBarra(
            `PAB ${p.numero} · ${p.elemento}`,
            `${nomeFrente.get(p.frente_id) ?? 'frente desconhecida'} · prevista ${p.data_prevista}` +
              (atrasado ? ' · data prevista já passou' : ''),
            `${Number(p.volume_previsto_m3).toFixed(2)} m³`,
            0,
            atrasado ? 'var(--ferro)' : 'var(--hivis)',
          ),
        )
      }
    }
    painel.append(espera)

    // ── pedidos por estado ──────────────────────────────────────────────────
    const porEstado = bloco('Pedidos por estado')
    const contagens = document.createElement('div')
    contagens.className = 'contadores'
    for (const estado of ESTADOS) {
      const quantos = pabs.filter((p) => p.estado === estado).length
      if (quantos === 0) continue
      const caixa = document.createElement('div')
      caixa.className = 'contador'
      const n = document.createElement('span')
      n.className = 'mono contador-numero'
      n.textContent = String(quantos)
      const nome = document.createElement('span')
      nome.className = `estado estado-${estado}`
      nome.textContent = estado.replace('_', ' ')
      caixa.append(n, nome)
      contagens.append(caixa)
    }
    if (pabs.length === 0) porEstado.append(vazio('Ainda não há pedidos nesta obra.'))
    else porEstado.append(contagens)
    painel.append(porEstado)

    // ── volume: previsto vs betonado (A4) ───────────────────────────────────
    const volume = bloco('Volume', true)
    const campos = document.createElement('div')
    campos.className = 'campos'
    campos.append(
      linhaDe(
        campo('Previsto', `${previsto.toFixed(2)} m³`, true),
        campo('Betonado', `${betonado.toFixed(2)} m³`, true),
        campo(
          'Guias registadas',
          `${guias.length}`,
          true,
        ),
      ),
    )
    volume.append(campos)
    volume.append(
      linhaComBarra(
        'Betonado sobre previsto',
        previsto === 0
          ? 'sem pedidos vivos'
          : 'inclui betonagens em curso — só é desvio quando a betonagem fecha',
        previsto === 0 ? '—' : `${((betonado / previsto) * 100).toFixed(0)} %`,
        previsto === 0 ? 0 : betonado / previsto,
        'var(--ddn)',
      ),
    )
    painel.append(volume)

    // ── por classe de betão (A5) ────────────────────────────────────────────
    const porClasse = bloco('Volume por classe de betão')
    const classes = somaPor(guias, (g) => g.classe_betao, volumeDe)
    if (classes.length === 0) porClasse.append(vazio('Ainda não há betão registado.'))
    else {
      const maior = classes[0]![1].soma
      for (const [classe, { soma, contagem }] of classes) {
        porClasse.append(
          linhaComBarra(
            classe,
            `${contagem} ${contagem === 1 ? 'guia' : 'guias'}`,
            `${soma.toFixed(2)} m³`,
            maior === 0 ? 0 : soma / maior,
            'var(--ddn)',
          ),
        )
      }
    }
    painel.append(porClasse)

    // ── por central (A6) ────────────────────────────────────────────────────
    const porCentral = bloco('Guias por central')
    const centraisComVolume = somaPor(guias, (g) => g.central_id, volumeDe)
    if (centraisComVolume.length === 0) porCentral.append(vazio('Ainda não há guias registadas.'))
    else {
      const maior = centraisComVolume[0]![1].soma
      for (const [id, { soma, contagem }] of centraisComVolume) {
        porCentral.append(
          linhaComBarra(
            nomeCentral.get(id) ?? 'central desconhecida',
            `${contagem} ${contagem === 1 ? 'guia' : 'guias'}`,
            `${soma.toFixed(2)} m³`,
            maior === 0 ? 0 : soma / maior,
            'var(--marcacao)',
          ),
        )
      }
    }
    painel.append(porCentral)

    // ── últimas betonagens (A1) ─────────────────────────────────────────────
    const ultimas = bloco('Últimas betonagens')
    const numeroDoPab = new Map(pabs.map((p) => [p.id, p]))
    const recentes = [...guiasPorPab.entries()]
      .map(([pabId, gs]) => ({
        pab: numeroDoPab.get(pabId),
        volume: gs.reduce((s, g) => s + volumeDe(g), 0),
        quantas: gs.length,
        ultima: gs.reduce(
          (m, g) => (g.data_hora_betonagem > m ? g.data_hora_betonagem : m),
          gs[0]!.data_hora_betonagem,
        ),
      }))
      .filter((r): r is { pab: Pab; volume: number; quantas: number; ultima: string } =>
        r.pab !== undefined,
      )
      .sort((a, b) => (a.ultima < b.ultima ? 1 : -1))
      .slice(0, 8)

    if (recentes.length === 0) ultimas.append(vazio('Ainda não houve betonagens nesta obra.'))
    else {
      for (const r of recentes) {
        const prev = Number(r.pab.volume_previsto_m3)
        const fechada = r.pab.estado === 'BETONADO' || r.pab.estado === 'FCQ_FECHADA'
        const desvio = prev === 0 ? 0 : ((r.volume - prev) / prev) * 100
        ultimas.append(
          linhaComBarra(
            `PAB ${r.pab.numero} · ${r.pab.elemento}`,
            `${horaCurta(r.ultima)} · ${r.quantas} ${r.quantas === 1 ? 'guia' : 'guias'} · ` +
              (fechada
                ? `${desvio >= 0 ? '+' : ''}${desvio.toFixed(1)} % face ao previsto`
                : 'em curso — ainda não é desvio'),
            `${r.volume.toFixed(2)} / ${prev.toFixed(2)} m³`,
            prev === 0 ? 0 : r.volume / prev,
            fechada && Math.abs(desvio) > 5 ? 'var(--hivis)' : 'var(--ddn)',
          ),
        )
      }
    }
    painel.append(ultimas)

    // ── o que falta, dito em voz alta ───────────────────────────────────────
    const falta = bloco('O que este painel ainda não sabe')
    const nota = document.createElement('p')
    nota.className = 'legenda-doc'
    nota.textContent =
      'Lotes de controlo e amostragem (o acumulador A7) dependem do registo de provetes, ' +
      'que ainda não existe. É o único acumulador que previne em vez de constatar: diz ' +
      'quanto betão foi colocado desde a última amostra e quando a próxima passa a ser ' +
      'exigível. Enquanto não existir, este painel descreve o passado.'
    falta.append(nota)
    painel.append(falta)
  }

  const recarregar = (): void => {
    Promise.all([lerPabs(obra.id), lerGuiasDaObra(obra.id), lerCentrais(), lerFrentes(obra.id)])
      .then(([pabs, guias, centrais, frentes]) => desenhar({ pabs, guias, centrais, frentes }))
      .catch(mostrarErro)
  }

  recarregar()
}
