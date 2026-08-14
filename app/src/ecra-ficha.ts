// A ficha I.CR.033 do PAB — os 20 critérios pré-betonagem.
//
// Estes 20 são os que o gate de aprovação exige: implantação 1, cofragem 5,
// armaduras 14. As outras três secções do impresso — juntas, betonagem e
// pós-betonagem — não entram aqui, e a de juntas nem sequer entra no gate: uma
// junta de betonagem nasce durante o processo e o corte e a selagem são
// posteriores.
//
// Cada critério é marcado UM DE CADA VEZ, e cada marcação leva o seu momento e
// a sua posição na sequência do aparelho. Não há «marcar tudo conforme» — nem
// aqui nem no servidor. É dos poucos sítios onde a fricção é o objectivo: é ela
// que distingue uma ficha preenchida em obra de uma ficha preenchida no
// gabinete na véspera.
//
// Um item marcado não se altera. Corrigir é um registo novo que referencia o
// anterior, com motivo escrito, e isso é fase própria — aqui os botões de um
// critério já marcado ficam inertes.

import {
  lerEstadoSeccoes,
  lerFicha,
  lerItensInspecao,
  lerLinhasPreBetonagem,
  marcarItem,
  mensagemDeErro,
  NOME_DA_SECCAO,
  SECCOES_PRE_BETONAGEM,
  type EstadoSeccao,
  type Ficha,
  type ItemFicha,
  type LinhaFicha,
  type Obra,
  type Pab,
  type SeccaoFcq,
  type ValorFcq,
} from './dominio'
import type { UtilizadorDeDominio } from './sessao'

/** Quem pode marcar, segundo betonagens.marcar_item_fcq. */
const PODE_MARCAR = ['FISCALIZACAO', 'DIRETOR_QUALIDADE']

/** O mínimo que a anotação de uma não conformidade tem de ter, do lado do
 *  servidor: constraint fcq_item_nc_anotado e verificação na função. */
const MINIMO_ANOTACAO = 5

const VALORES: ValorFcq[] = ['C', 'NC', 'NA']
const SIMBOLO: Record<ValorFcq, string> = { C: '√', NC: '✕', NA: '∕' }
const TITULO: Record<ValorFcq, string> = {
  C: 'Conforme',
  NC: 'Não conforme',
  NA: 'Não aplicável',
}

type Dados = {
  ficha: Ficha
  linhas: LinhaFicha[]
  itens: Map<string, ItemFicha>
  estados: Map<SeccaoFcq, EstadoSeccao>
}

async function carregar(pabId: string): Promise<Dados> {
  const ficha = await lerFicha(pabId)
  const [linhas, itens, estados] = await Promise.all([
    lerLinhasPreBetonagem(ficha.modelo_impresso_id),
    lerItensInspecao(ficha.id),
    lerEstadoSeccoes(ficha.id),
  ])
  return {
    ficha,
    linhas,
    itens: new Map(itens.map((i) => [i.linha_codigo, i])),
    estados: new Map(estados.map((e) => [e.seccao, e])),
  }
}

// ── desenho ─────────────────────────────────────────────────────────────────
// Com o DOM e textContent: os critérios vêm do mapa de campos do impresso e as
// anotações foram escritas por pessoas.

function desenharCabecalhoSeccao(seccao: SeccaoFcq, estado: EstadoSeccao | undefined): HTMLElement {
  const preenchidos = estado?.itens_preenchidos ?? 0
  const total = estado?.linhas_da_seccao ?? 0
  const naoConformes = estado?.itens_nao_conformes ?? 0

  const ponto = document.createElement('span')
  ponto.className =
    'ponto ' +
    (naoConformes > 0
      ? 'ponto-nc'
      : total > 0 && preenchidos === total
        ? 'ponto-ok'
        : 'ponto-pendente')

  const nome = document.createElement('span')
  nome.className = 'seccao-nome'
  nome.textContent = NOME_DA_SECCAO[seccao]

  const contagem = document.createElement('span')
  contagem.className = 'mono seccao-contagem'
  contagem.textContent =
    naoConformes > 0 ? `${preenchidos}/${total} · ${naoConformes} NC` : `${preenchidos}/${total}`

  const cabecalho = document.createElement('div')
  cabecalho.className = 'seccao-cabecalho'
  cabecalho.append(ponto, nome, contagem)
  return cabecalho
}

function desenharCriterio(
  linha: LinhaFicha,
  item: ItemFicha | undefined,
  podeMarcar: boolean,
  aoEscolher: (linha: LinhaFicha, valor: ValorFcq, bloco: HTMLElement) => void,
): HTMLElement {
  const bloco = document.createElement('div')
  bloco.className = 'criterio-bloco'

  const codigo = document.createElement('span')
  codigo.className = 'mono criterio-codigo'
  codigo.textContent = linha.codigo

  const texto = document.createElement('span')
  texto.className = 'criterio-texto'
  texto.textContent = linha.criterio

  const tri = document.createElement('div')
  tri.className = 'tri'
  for (const valor of VALORES) {
    const botao = document.createElement('button')
    botao.type = 'button'
    botao.textContent = SIMBOLO[valor]
    botao.title = TITULO[valor]
    botao.setAttribute('aria-label', `${TITULO[valor]} — ${linha.codigo}`)

    if (item !== undefined) {
      botao.disabled = true
      if (item.valor === valor) botao.className = `on-${valor}`
    } else if (!podeMarcar) {
      botao.disabled = true
    } else {
      botao.addEventListener('click', () => aoEscolher(linha, valor, bloco))
    }
    tri.append(botao)
  }

  const criterio = document.createElement('div')
  criterio.className = 'criterio'
  criterio.append(codigo, texto, tri)
  bloco.append(criterio)

  if (item?.anotacao != null && item.anotacao !== '') {
    const anotacao = document.createElement('div')
    anotacao.className = 'anotacao-registada'
    anotacao.textContent = item.anotacao
    bloco.append(anotacao)
  }

  return bloco
}

// ── ecrã ────────────────────────────────────────────────────────────────────

export function montarEcraFicha(
  destino: HTMLElement,
  obra: Obra,
  pab: Pab,
  utilizador: UtilizadorDeDominio,
  aoVoltar: () => void,
): void {
  const podeMarcar = PODE_MARCAR.includes(utilizador.perfil)

  let fichaId: string | null = null
  let ocupado = false

  destino.innerHTML = `
    <section class="ecra">
      <button id="botao-voltar" class="voltar" type="button"></button>

      <header class="cabecalho-ficha">
        <div class="linha-ficha">
          <h1 class="mono numero-ficha">033 / <span id="numero-ficha">…</span></h1>
          <span id="estado-ficha" class="estado"></span>
        </div>
        <div class="elemento-ficha"></div>
        <p class="sub-ficha">
          Ficha de Controlo da Qualidade · Betão Armado · I.CR.033 Rev. 9<br>
          Verificações anteriores à betonagem — 20 critérios em 3 secções
        </p>
      </header>

      ${podeMarcar ? '' : `<p class="nota-perfil">O perfil ${utilizador.perfil} não preenche a ficha.</p>`}

      <div id="seccoes"><p class="vazio">A carregar…</p></div>
      <p id="erro-ficha" class="erro" role="alert" hidden></p>
    </section>
  `

  const voltar = destino.querySelector<HTMLButtonElement>('#botao-voltar')!
  voltar.textContent = `‹ ${obra.codigo}`

  destino.querySelector<HTMLDivElement>('.elemento-ficha')!.textContent =
    `PAB ${pab.numero} · ${pab.elemento}`

  const seccoes = destino.querySelector<HTMLDivElement>('#seccoes')!
  const erro = destino.querySelector<HTMLParagraphElement>('#erro-ficha')!

  const mostrarErro = (causa: unknown): void => {
    erro.textContent = mensagemDeErro(causa)
    erro.hidden = false
  }

  voltar.addEventListener('click', aoVoltar)

  const enviar = (linha: LinhaFicha, valor: ValorFcq, anotacao: string | null): void => {
    if (fichaId === null) return
    ocupado = true
    erro.hidden = true
    seccoes.classList.add('a-gravar')

    marcarItem(fichaId, linha.codigo, valor, anotacao)
      .then(recarregar)
      .catch(mostrarErro)
      .finally(() => {
        ocupado = false
        seccoes.classList.remove('a-gravar')
      })
  }

  const escolher = (linha: LinhaFicha, valor: ValorFcq, bloco: HTMLElement): void => {
    if (ocupado) return

    // Conforme e Não aplicável vão directos. Uma não conformidade exige dizer o
    // que está mal — a constraint do servidor recusa-a sem isso, e faz bem.
    if (valor !== 'NC') {
      enviar(linha, valor, null)
      return
    }

    if (bloco.querySelector('.forma-anotacao') !== null) return

    const forma = document.createElement('form')
    forma.className = 'forma-anotacao'

    const campo = document.createElement('input')
    campo.type = 'text'
    campo.required = true
    campo.minLength = MINIMO_ANOTACAO
    campo.placeholder = 'O que está mal, em poucas palavras'
    campo.setAttribute('aria-label', `Anotação da não conformidade em ${linha.codigo}`)

    const registar = document.createElement('button')
    registar.type = 'submit'
    registar.className = 'btn btn-p'
    registar.textContent = 'Registar não conformidade'

    const cancelar = document.createElement('button')
    cancelar.type = 'button'
    cancelar.className = 'btn btn-s'
    cancelar.textContent = 'Cancelar'
    cancelar.addEventListener('click', () => forma.remove())

    forma.addEventListener('submit', (evento) => {
      evento.preventDefault()
      const anotacao = campo.value.trim()
      if (anotacao.length < MINIMO_ANOTACAO) {
        mostrarErro(
          `A anotação da não conformidade precisa de pelo menos ${MINIMO_ANOTACAO} caracteres. ` +
            'É o que fica no impresso e no anexo, e é por ela que alguém sabe o que houve.',
        )
        campo.focus()
        return
      }
      enviar(linha, 'NC', anotacao)
    })

    forma.append(campo, registar, cancelar)
    bloco.append(forma)
    campo.focus()
  }

  const desenhar = (dados: Dados): void => {
    fichaId = dados.ficha.id

    destino.querySelector<HTMLSpanElement>('#numero-ficha')!.textContent = dados.ficha.numero
    const estadoFicha = destino.querySelector<HTMLSpanElement>('#estado-ficha')!
    estadoFicha.textContent = dados.ficha.estado
    estadoFicha.className = `estado estado-${dados.ficha.estado}`

    seccoes.replaceChildren()

    for (const seccao of SECCOES_PRE_BETONAGEM) {
      const daSeccao = dados.linhas.filter((l) => l.seccao === seccao)
      if (daSeccao.length === 0) continue

      const bloco = document.createElement('section')
      bloco.className = 'seccao'
      bloco.append(desenharCabecalhoSeccao(seccao, dados.estados.get(seccao)))

      for (const linha of daSeccao) {
        bloco.append(desenharCriterio(linha, dados.itens.get(linha.codigo), podeMarcar, escolher))
      }
      seccoes.append(bloco)
    }
  }

  function recarregar(): void {
    carregar(pab.id).then(desenhar).catch(mostrarErro)
  }

  recarregar()
}
