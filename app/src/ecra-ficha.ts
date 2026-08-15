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
  aprovarPab,
  assinarSeccao,
  lerEstadoSeccoes,
  lerFicha,
  lerItensInspecao,
  lerLinhasPreBetonagem,
  marcarItem,
  mensagemDeErro,
  NOME_DA_SECCAO,
  SECCOES_PRE_BETONAGEM,
  type EstadoPab,
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

/** Os três RPC deste ecrã — marcar_item_fcq, assinar_seccao_fcq e aprovar_pab —
 *  exigem exactamente estes dois perfis. Esconder o que o servidor recusaria é
 *  cortesia; quem contar com isto para segurança conta com a coisa errada. */
const PERFIS_DE_INSPECAO = ['FISCALIZACAO', 'DIRETOR_QUALIDADE']

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

/** Hora do servidor, escrita na hora local de quem lê. Se vier ilegível,
 *  mostra-se o que veio em vez de inventar uma data. */
function horaLocal(iso: string | null): string {
  if (iso === null) return 'hora desconhecida'
  const quando = new Date(iso)
  if (!Number.isFinite(quando.getTime())) return iso
  return quando.toLocaleString('pt-PT', { dateStyle: 'short', timeStyle: 'short' })
}

function desenharCabecalhoSeccao(
  seccao: SeccaoFcq,
  estado: EstadoSeccao | undefined,
  podeInspecionar: boolean,
  aoAssinar: (seccao: SeccaoFcq) => void,
): DocumentFragment {
  const preenchidos = estado?.itens_preenchidos ?? 0
  const total = estado?.linhas_da_seccao ?? 0
  const naoConformes = estado?.itens_nao_conformes ?? 0
  const completa = total > 0 && preenchidos === total

  const ponto = document.createElement('span')
  ponto.className =
    'ponto ' + (naoConformes > 0 ? 'ponto-nc' : completa ? 'ponto-ok' : 'ponto-pendente')

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

  // O botão só aparece enquanto a secção não estiver assinada, e só fica activo
  // com a secção completa. Reassinar está fora deste âmbito; o servidor recusa
  // uma segunda assinatura sem motivo escrito, e diz porquê.
  if (podeInspecionar && estado?.assinada !== true) {
    const assinar = document.createElement('button')
    assinar.type = 'button'
    assinar.className = 'btn-assinar'
    assinar.textContent = 'Assinar'
    assinar.disabled = !completa
    assinar.title = completa
      ? `Assinar a secção ${NOME_DA_SECCAO[seccao]}`
      : 'Não se assina uma secção incompleta.'
    assinar.addEventListener('click', () => aoAssinar(seccao))
    cabecalho.append(assinar)
  }

  const fragmento = document.createDocumentFragment()
  fragmento.append(cabecalho)

  if (estado?.assinada === true) {
    const assinatura = document.createElement('div')
    assinatura.className = estado.em_vigor ? 'assinatura-seccao' : 'assinatura-seccao caida'
    assinatura.textContent = estado.em_vigor
      ? `Assinada por ${estado.nome_impresso ?? '—'} · ${horaLocal(estado.assinado_em)}`
      : `Assinada por ${estado.nome_impresso ?? '—'} · ${horaLocal(estado.assinado_em)} — já não cobre os itens actuais.`
    fragmento.append(assinatura)
  }

  return fragmento
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
  const podeInspecionar = PERFIS_DE_INSPECAO.includes(utilizador.perfil)

  let fichaId: string | null = null
  let ocupado = false
  let estadoPab: EstadoPab = pab.estado

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

      ${podeInspecionar ? '' : `<p class="nota-perfil">O perfil ${utilizador.perfil} não preenche a ficha.</p>`}

      <div id="seccoes"><p class="vazio">A carregar…</p></div>
      <p id="erro-ficha" class="erro" role="alert" hidden></p>

      <footer id="rodape-ficha" class="rodape-ficha">
        <div class="rodape-estado">
          <span class="rodape-etiqueta">Estado do PAB</span>
          <span id="estado-pab" class="estado"></span>
        </div>
        <button id="botao-aprovar" class="btn btn-p" type="button" hidden>Aprovar betonagem</button>
      </footer>
    </section>
  `

  const voltar = destino.querySelector<HTMLButtonElement>('#botao-voltar')!
  voltar.textContent = `‹ ${obra.codigo}`

  destino.querySelector<HTMLDivElement>('.elemento-ficha')!.textContent =
    `PAB ${pab.numero} · ${pab.elemento}`

  const seccoes = destino.querySelector<HTMLDivElement>('#seccoes')!
  const erro = destino.querySelector<HTMLParagraphElement>('#erro-ficha')!
  const rodape = destino.querySelector<HTMLElement>('#rodape-ficha')!
  const estadoPabEl = destino.querySelector<HTMLSpanElement>('#estado-pab')!
  const botaoAprovar = destino.querySelector<HTMLButtonElement>('#botao-aprovar')!

  const mostrarErro = (causa: unknown): void => {
    erro.textContent = mensagemDeErro(causa)
    erro.hidden = false
  }

  voltar.addEventListener('click', aoVoltar)

  /** Enquanto o servidor não responder, nada nesta ficha se toca. O erro
   *  aparece na caixa; nunca é engolido. */
  function executar<T>(accao: () => Promise<T>, depois: (resultado: T) => void): void {
    if (ocupado) return
    ocupado = true
    erro.hidden = true
    seccoes.classList.add('a-gravar')
    rodape.classList.add('a-gravar')

    accao()
      .then(depois)
      .catch(mostrarErro)
      .finally(() => {
        ocupado = false
        seccoes.classList.remove('a-gravar')
        rodape.classList.remove('a-gravar')
      })
  }

  const enviar = (linha: LinhaFicha, valor: ValorFcq, anotacao: string | null): void => {
    const id = fichaId
    if (id === null) return
    executar(() => marcarItem(id, linha.codigo, valor, anotacao), recarregar)
  }

  const assinar = (seccao: SeccaoFcq): void => {
    const id = fichaId
    if (id === null) return
    executar(() => assinarSeccao(id, seccao), recarregar)
  }

  const desenharRodape = (): void => {
    estadoPabEl.textContent = estadoPab
    estadoPabEl.className = `estado estado-${estadoPab}`
    botaoAprovar.hidden = !podeInspecionar || estadoPab !== 'SUBMETIDO'
  }

  // O botão fica activo mesmo com o gate por cumprir: é o servidor que decide,
  // e é a frase dele que aparece. Um botão desactivado por conta do cliente
  // esconderia a razão da recusa — que é precisamente o que interessa ler.
  botaoAprovar.addEventListener('click', () => {
    executar(
      () => aprovarPab(pab.id),
      (estado) => {
        estadoPab = estado
        desenharRodape()
        recarregar()
      },
    )
  })

  desenharRodape()

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
      bloco.append(
        desenharCabecalhoSeccao(seccao, dados.estados.get(seccao), podeInspecionar, assinar),
      )

      for (const linha of daSeccao) {
        bloco.append(
          desenharCriterio(linha, dados.itens.get(linha.codigo), podeInspecionar, escolher),
        )
      }
      seccoes.append(bloco)
    }
  }

  function recarregar(): void {
    carregar(pab.id).then(desenhar).catch(mostrarErro)
  }

  recarregar()
}
