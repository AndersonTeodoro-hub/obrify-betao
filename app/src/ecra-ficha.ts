// O PAB como documento: o impresso em versão digital, em modo de leitura.
//
// A organização é a do QAS.150.04, o modelo do empreiteiro que serve de
// referência de completude: cabeçalho de obra, barra com o número do pedido, e
// depois os blocos pela ordem do impresso — Localização, Elementos técnicos,
// Data prevista para, Empreiteiro, Fiscalização, Verificações, Observações.
//
// As verificações ficam DENTRO deste documento, e não num ecrã à parte, porque
// é aí que elas estão no impresso e porque este ecrã já recebia o PAB inteiro:
// os blocos novos são desenho dos dados que já cá estavam. A única leitura
// acrescentada é a das frentes, para dar nome à parte da obra.
//
// Estes 20 critérios são os que o gate de aprovação exige: implantação 1,
// cofragem 5, armaduras 14. As outras três secções do impresso — juntas,
// betonagem e pós-betonagem — não entram aqui, e a de juntas nem sequer entra
// no gate: uma junta de betonagem nasce durante o processo e o corte e a
// selagem são posteriores.
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
  lerFrentes,
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
  frente: string | null
}

async function carregar(pab: Pab, obraId: string): Promise<Dados> {
  const ficha = await lerFicha(pab.id)
  const [linhas, itens, estados, frentes] = await Promise.all([
    lerLinhasPreBetonagem(ficha.modelo_impresso_id),
    lerItensInspecao(ficha.id),
    lerEstadoSeccoes(ficha.id),
    lerFrentes(obraId),
  ])
  return {
    ficha,
    linhas,
    itens: new Map(itens.map((i) => [i.linha_codigo, i])),
    estados: new Map(estados.map((e) => [e.seccao, e])),
    frente: frentes.find((f) => f.id === pab.frente_id)?.designacao ?? null,
  }
}

// ── desenho ─────────────────────────────────────────────────────────────────
// Com o DOM e textContent: os critérios vêm do mapa de campos do impresso e as
// anotações foram escritas por pessoas.

/**
 * Uma linha de campo do impresso: etiqueta à esquerda, valor à direita.
 *
 * Um valor que não existe imprime «—» em cinzento, e nunca um espaço em branco:
 * no papel, um espaço vazio e um campo que ninguém preencheu são a mesma coisa,
 * e é precisamente essa confusão que uma versão digital não deve herdar.
 */
function campo(etiqueta: string, valor: string | null, largo = false): HTMLElement {
  const rotulo = document.createElement('span')
  rotulo.className = 'etiqueta'
  rotulo.textContent = etiqueta

  const conteudo = document.createElement('span')
  conteudo.className = 'valor'
  if (valor === null || valor === '') {
    conteudo.textContent = '—'
    conteudo.classList.add('por-indicar')
  } else {
    conteudo.textContent = valor
  }

  const linha = document.createElement('div')
  linha.className = largo ? 'campo campo-largo' : 'campo'
  linha.append(rotulo, conteudo)
  return linha
}

/**
 * Uma linha do impresso com vários campos lado a lado.
 *
 * No papel os campos curtos partilham linha — «Identificação do Betão: C30/37
 * Classe: XC4  Slump: S5  Vol. Prev.: 15 m3» — e é essa densidade que faz
 * aquilo parecer um impresso. Em coluna estreita a CSS desfaz a linha e cada
 * campo volta ao seu lugar.
 */
function linha(...campos: HTMLElement[]): HTMLElement {
  const fila = document.createElement('div')
  fila.className = `linha-campos linha-${campos.length}`
  fila.append(...campos)
  return fila
}

/** Hora do servidor, escrita na hora local de quem lê. Se vier ilegível,
 *  mostra-se o que veio em vez de inventar uma data. */
function horaLocal(iso: string | null): string | null {
  if (iso === null) return null
  const quando = new Date(iso)
  if (!Number.isFinite(quando.getTime())) return iso
  return quando.toLocaleString('pt-PT', { dateStyle: 'short', timeStyle: 'short' })
}

/** A data prevista para descofragem ou escoramento, nos três estados que o
 *  impresso distingue: uma data, «N/A», ou por indicar. */
function dataOuNA(prevista: string | null, aplicavel: boolean): string | null {
  if (!aplicavel) return 'N/A'
  return prevista
}

/** A decisão da fiscalização, em texto. É o servidor que a determina; aqui
 *  só se lê o que ele gravou. */
function decisao(pab: Pab): string | null {
  if (pab.aprovado_em !== null) return `Aprovado em ${horaLocal(pab.aprovado_em)}`
  if (pab.rejeitado_em !== null) {
    return `Rejeitado em ${horaLocal(pab.rejeitado_em)} — ${pab.motivo_rejeicao ?? 'sem motivo registado'}`
  }
  if (pab.anulado_em !== null) {
    return `Anulado em ${horaLocal(pab.anulado_em)} — ${pab.motivo_anulacao ?? 'sem motivo registado'}`
  }
  return null
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
      ? `Assinada por ${estado.nome_impresso ?? '—'} · ${horaLocal(estado.assinado_em) ?? 'hora desconhecida'}`
      : `Assinada por ${estado.nome_impresso ?? '—'} · ${horaLocal(estado.assinado_em) ?? 'hora desconhecida'} — já não cobre os itens actuais.`
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

      <article class="doc">
        <div class="doc-titulo">
          <h1>Pedido de autorização de betonagem</h1>
          <span id="estado-pab" class="estado"></span>
        </div>

        <div class="doc-ident">
          <div class="campo"><span class="etiqueta">Dono de obra</span
            ><span class="valor" data-obra="dono_obra"></span></div>
          <div class="campo"><span class="etiqueta">Obra / empreitada</span
            ><span class="valor" data-obra="obra"></span></div>
          <div class="campo"><span class="etiqueta">Adjudicatário</span
            ><span class="valor" data-obra="empreiteiro"></span></div>
          <div class="campo"><span class="etiqueta">Fiscalização</span
            ><span class="valor" data-obra="fiscalizacao"></span></div>
        </div>

        <div class="doc-numero">
          <span>Pedido de autorização de betonagem n.º</span>
          <span class="mono valor-numero" id="numero-pab"></span>
        </div>

        <section class="doc-bloco">
          <h3>Localização</h3>
          <div class="campos" id="bloco-localizacao"></div>
        </section>

        <section class="doc-bloco">
          <h3>Elementos técnicos</h3>
          <div class="campos" id="bloco-tecnicos"></div>
        </section>

        <section class="doc-bloco">
          <h3>Data prevista para</h3>
          <div class="campos" id="bloco-datas"></div>
        </section>

        <section class="doc-bloco">
          <h3>Empreiteiro</h3>
          <div class="campos" id="bloco-empreiteiro"></div>
        </section>

        <section class="doc-bloco">
          <div class="doc-barra"><span>Fiscalização</span></div>
          <div class="campos" id="bloco-fiscalizacao"></div>
        </section>

        <section class="doc-bloco">
          <div class="doc-barra">
            <span>Verificações anteriores à betonagem</span>
            <span class="barra-lado">
              <span class="mono" id="numero-ficha">…</span>
              <span id="estado-ficha" class="estado"></span>
            </span>
          </div>
          <p class="legenda-doc">
            I.CR.033 Rev. 9 · 20 critérios em 3 secções ·
            <b>√</b> conforme · <b>✕</b> não conforme · <b>∕</b> não aplicável
          </p>
          ${podeInspecionar ? '' : `<p class="nota-perfil">O perfil ${utilizador.perfil} não preenche a ficha.</p>`}
          <div id="seccoes"><p class="vazio">A carregar…</p></div>
        </section>

        <section class="doc-bloco">
          <h3>Observações</h3>
          <div class="campos" id="bloco-observacoes"></div>
        </section>

        <footer id="rodape-ficha" class="rodape-ficha">
          <div class="rodape-estado">
            <span class="rodape-etiqueta">Estado do PAB</span>
            <span id="estado-rodape" class="estado"></span>
          </div>
          <button id="botao-aprovar" class="btn btn-p" type="button" hidden>Aprovar betonagem</button>
        </footer>
      </article>

      <p id="erro-ficha" class="erro" role="alert" hidden></p>
    </section>
  `

  const voltar = destino.querySelector<HTMLButtonElement>('#botao-voltar')!
  voltar.textContent = `‹ ${obra.codigo}`

  // O cabeçalho do impresso. Por textContent: são valores de base de dados
  // escritos por pessoas.
  for (const alvo of destino.querySelectorAll<HTMLElement>('[data-obra]')) {
    const qual = alvo.dataset.obra
    const valor =
      qual === 'obra'
        ? `Obra n.º ${obra.codigo} — ${obra.designacao}`
        : qual === 'dono_obra'
          ? obra.dono_obra
          : qual === 'empreiteiro'
            ? obra.empreiteiro
            : obra.fiscalizacao
    alvo.textContent = valor ?? '—'
    if (valor === null) alvo.classList.add('por-indicar')
  }

  destino.querySelector<HTMLSpanElement>('#numero-pab')!.textContent = String(pab.numero)

  const seccoes = destino.querySelector<HTMLDivElement>('#seccoes')!
  const erro = destino.querySelector<HTMLParagraphElement>('#erro-ficha')!
  const rodape = destino.querySelector<HTMLElement>('#rodape-ficha')!
  const estadoRodape = destino.querySelector<HTMLSpanElement>('#estado-rodape')!
  const estadoTopo = destino.querySelector<HTMLSpanElement>('#estado-pab')!
  const botaoAprovar = destino.querySelector<HTMLButtonElement>('#botao-aprovar')!

  const mostrarErro = (causa: unknown): void => {
    erro.textContent = mensagemDeErro(causa)
    erro.hidden = false
  }

  voltar.addEventListener('click', aoVoltar)

  // ── os blocos do impresso, que não dependem do que se carrega ─────────────

  // A ordem e o agrupamento são os da linha 14 e 15 do impresso.
  destino.querySelector<HTMLDivElement>('#bloco-tecnicos')!.append(
    linha(
      campo('Identificação do betão', pab.classe_betao),
      campo('Classe', pab.classe_exposicao),
      campo('Slump', pab.classe_consistencia),
      campo('Vol. prev.', `${pab.volume_previsto_m3} m³`),
    ),
    linha(
      // O Dmáx não existe no QAS.150.04 — é do nosso modelo. Fica com os
      // processos por ser o que sobra da especificação do betão.
      campo('Dmáx do agregado', pab.dmax_agregado_mm === null ? null : `${pab.dmax_agregado_mm} mm`),
      campo('Processo de betonagem', pab.processo_betonagem),
      campo('Processo de cura', pab.processo_cura),
    ),
  )

  // Linhas 17 e 18 do impresso: betonagem e horas de um lado, descofragem e
  // escoramento do outro.
  destino.querySelector<HTMLDivElement>('#bloco-datas')!.append(
    linha(
      campo('Betonagem', pab.data_prevista),
      campo('Hora de início', pab.hora_prevista_inicio),
      campo('Hora de fim', pab.hora_prevista_fim),
    ),
    linha(
      campo('Descofragem', dataOuNA(pab.descofragem_prevista, pab.descofragem_aplicavel)),
      campo(
        'Retirada do escoramento',
        dataOuNA(pab.escoramento_retirada_prevista, pab.escoramento_aplicavel),
      ),
    ),
  )

  // Linha 19 do impresso: «Empreiteiro: [nome]  Data: [data]». O nome não vem
  // aqui — seria um embed para betonagens.utilizador, e isso é mais do que
  // apresentação. O que se mostra é o que a linha do PAB guarda.
  destino.querySelector<HTMLDivElement>('#bloco-empreiteiro')!.append(
    linha(
      campo('Data do pedido', pab.data_pedido),
      campo('Submetido em', horaLocal(pab.submetido_em)),
    ),
  )

  destino.querySelector<HTMLDivElement>('#bloco-fiscalizacao')!.append(
    linha(
      campo('Pedido recebido em', horaLocal(pab.submetido_em)),
      campo('Decisão', decisao(pab)),
    ),
  )

  destino.querySelector<HTMLDivElement>('#bloco-observacoes')!.append(
    campo('Observações', pab.observacoes, true),
  )

  // ── acções ───────────────────────────────────────────────────────────────

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

  const desenharEstado = (): void => {
    for (const alvo of [estadoTopo, estadoRodape]) {
      alvo.textContent = estadoPab.replace('_', ' ')
      alvo.className = `estado estado-${estadoPab}`
    }
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
        desenharEstado()
        recarregar()
      },
    )
  })

  desenharEstado()

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

    const campoTexto = document.createElement('input')
    campoTexto.type = 'text'
    campoTexto.required = true
    campoTexto.minLength = MINIMO_ANOTACAO
    campoTexto.placeholder = 'O que está mal, em poucas palavras'
    campoTexto.setAttribute('aria-label', `Anotação da não conformidade em ${linha.codigo}`)

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
      const anotacao = campoTexto.value.trim()
      if (anotacao.length < MINIMO_ANOTACAO) {
        mostrarErro(
          `A anotação da não conformidade precisa de pelo menos ${MINIMO_ANOTACAO} caracteres. ` +
            'É o que fica no impresso e no anexo, e é por ela que alguém sabe o que houve.',
        )
        campoTexto.focus()
        return
      }
      enviar(linha, 'NC', anotacao)
    })

    forma.append(campoTexto, registar, cancelar)
    bloco.append(forma)
    campoTexto.focus()
  }

  const desenhar = (dados: Dados): void => {
    fichaId = dados.ficha.id

    destino.querySelector<HTMLSpanElement>('#numero-ficha')!.textContent =
      `I.CR.033 n.º ${dados.ficha.numero}`
    const estadoFicha = destino.querySelector<HTMLSpanElement>('#estado-ficha')!
    estadoFicha.textContent = dados.ficha.estado
    estadoFicha.className = `estado estado-${dados.ficha.estado}`

    // Linhas 11 e 12 do impresso: parte da obra e desenho na mesma linha, as
    // peças a betonar na largura toda — é uma descrição longa, com quebras.
    const localizacao = destino.querySelector<HTMLDivElement>('#bloco-localizacao')!
    localizacao.replaceChildren(
      linha(
        campo('Parte da obra', dados.frente),
        campo('Ref.ª do desenho', pab.referencia_desenho),
      ),
      campo('Peças a betonar', pab.elemento, true),
    )

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
    carregar(pab, obra.id).then(desenhar).catch(mostrarErro)
  }

  recarregar()
}
