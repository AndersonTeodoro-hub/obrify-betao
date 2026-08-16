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
  carregarFotoGuia,
  criarCentral,
  enderecoDaFoto,
  fecharBetonagem,
  lerCentrais,
  lerEstadoSeccoes,
  lerFicha,
  lerFrentes,
  lerGuias,
  lerItensInspecao,
  lerLinhasPreBetonagem,
  marcarItem,
  mensagemDeErro,
  NOME_DA_SECCAO,
  registarGuia,
  SECCOES_PRE_BETONAGEM,
  type Central,
  type EstadoPab,
  type EstadoSeccao,
  type Ficha,
  type Guia,
  type ItemFicha,
  type LinhaFicha,
  type Obra,
  type Pab,
  type SeccaoFcq,
  type ValorFcq,
} from './dominio'
import { lerNumero } from './campos'
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

/** Os estados em que a receção do betão faz sentido. Antes de aprovado não há
 *  betão para receber; depois de fechada a ficha, o bloco é histórico. */
const COM_RECECAO: EstadoPab[] = ['APROVADO', 'EM_BETONAGEM', 'BETONADO', 'FCQ_FECHADA']

type Dados = {
  ficha: Ficha
  linhas: LinhaFicha[]
  itens: Map<string, ItemFicha>
  estados: Map<SeccaoFcq, EstadoSeccao>
  frente: string | null
  guias: Guia[]
  centrais: Central[]
}

async function carregar(pab: Pab, obraId: string): Promise<Dados> {
  const ficha = await lerFicha(pab.id)
  const [linhas, itens, estados, frentes, guias, centrais] = await Promise.all([
    lerLinhasPreBetonagem(ficha.modelo_impresso_id),
    lerItensInspecao(ficha.id),
    lerEstadoSeccoes(ficha.id),
    lerFrentes(obraId),
    lerGuias(pab.id),
    lerCentrais(),
  ])
  return {
    ficha,
    linhas,
    itens: new Map(itens.map((i) => [i.linha_codigo, i])),
    estados: new Map(estados.map((e) => [e.seccao, e])),
    frente: frentes.find((f) => f.id === pab.frente_id)?.designacao ?? null,
    guias,
    centrais,
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

/**
 * O resumo da receção, calculado a pedido a partir das guias.
 *
 * A pedido e não guardado, como diz a nota de implementação do painel: a estes
 * volumes uma soma é instantânea, e um contador guardado é uma oportunidade de
 * dessincronização.
 */
function resumoDaRececao(guias: Guia[], centrais: Central[]) {
  const nomeCentral = new Map(centrais.map((c) => [c.id, c.designacao]))
  const momentos = guias.map((g) => new Date(g.data_hora_betonagem).getTime()).sort()
  return {
    volume: guias.reduce((soma, g) => soma + Number(g.volume_m3), 0),
    origens: [...new Set(guias.map((g) => nomeCentral.get(g.central_id) ?? '—'))].join(' · '),
    inicio: momentos.length === 0 ? null : new Date(momentos[0]!).toISOString(),
    fim: momentos.length === 0 ? null : new Date(momentos[momentos.length - 1]!).toISOString(),
  }
}

function preencherCentrais(select: HTMLSelectElement, centrais: Central[]): void {
  const escolhida = select.value
  select.replaceChildren()

  for (const central of centrais.filter((c) => c.ativa)) {
    const opcao = document.createElement('option')
    opcao.value = central.id
    opcao.textContent = central.designacao
    select.append(opcao)
  }

  if (centrais.some((c) => c.id === escolhida)) select.value = escolhida
}

/** A tabela de guias — a folha «Guias» do mapa de controlo, que é a fonte
 *  única de que tudo o resto agrega. */
function desenharGuias(destino: HTMLElement, dados: Dados, aoVerFoto: (g: Guia) => void): void {
  destino.replaceChildren()

  if (dados.guias.length === 0) {
    const vazio = document.createElement('p')
    vazio.className = 'vazio'
    vazio.textContent = 'Ainda não há guias registadas nesta betonagem.'
    destino.append(vazio)
    return
  }

  const nomeCentral = new Map(dados.centrais.map((c) => [c.id, c.designacao]))

  for (const guia of dados.guias) {
    const numero = document.createElement('span')
    numero.className = 'mono ref-doc'
    numero.textContent = guia.numero_guia

    const corpo = document.createElement('span')
    corpo.className = 'corpo-doc'

    const titulo = document.createElement('span')
    titulo.className = 'titulo-doc'
    titulo.textContent = `${guia.volume_m3} m³ · ${guia.classe_betao}`

    const sub = document.createElement('span')
    sub.className = 'sub-doc'
    sub.textContent = [
      nomeCentral.get(guia.central_id) ?? 'central desconhecida',
      horaLocal(guia.data_hora_betonagem) ?? '—',
      guia.slump_mm === null ? null : `slump ${guia.slump_mm} mm`,
      guia.temperatura_c === null ? null : `${guia.temperatura_c} °C`,
      guia.registado_por_fiscalizacao ? 'registada pela fiscalização' : null,
    ]
      .filter((p): p is string => p !== null)
      .join(' · ')

    corpo.append(titulo, sub)

    const lado = document.createElement('span')
    lado.className = 'lado-doc'

    // A conformidade vem do servidor: classe divergente, sobreconsumo, slump
    // fora do intervalo. Não se recalcula aqui — seria uma segunda opinião.
    const conf = document.createElement('span')
    conf.className = `estado conf-${guia.conformidade}`
    conf.textContent = guia.conformidade.replace('_', ' ')

    const foto = document.createElement('button')
    foto.type = 'button'
    foto.className = 'btn-foto'
    foto.textContent = 'Ver foto'
    foto.addEventListener('click', () => aoVerFoto(guia))

    lado.append(conf, foto)

    const linha = document.createElement('div')
    linha.className = 'linha-doc linha-guia'
    linha.append(numero, corpo, lado)

    if (guia.motivo_substituicao !== null) {
      const motivo = document.createElement('div')
      motivo.className = 'anotacao-registada'
      motivo.textContent = `Correcção: ${guia.motivo_substituicao}`
      linha.append(motivo)
    }

    destino.append(linha)
  }
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
  /** Quem pode criar centrais, segundo betonagens.criar_central. */
  const podeCriarCentral = ['ADMIN', 'DIRETOR_QUALIDADE', 'FISCALIZACAO'].includes(
    utilizador.perfil,
  )

  let fichaId: string | null = null
  let ocupado = false
  let estadoPab: EstadoPab = pab.estado

  // Sem <section class="ecra"> à volta: este documento é montado DENTRO da área
  // de trabalho do ecrã da obra, que já dá a largura e o espaçamento. Trazer o
  // seu próprio contentor seria uma coluna de 34rem dentro de uma folha de
  // 55rem, a lutar com ela.
  destino.innerHTML = `
    <div class="envolvente-doc">
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

        <!-- O que falta fazer, no topo. O bloco da receção fica a seguir aos 20
             critérios, como no impresso — e quem vem registar guias não tinha
             como saber que estava lá em baixo. -->
        <button id="atalho-guias" class="atalho" type="button" hidden></button>

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

        <section class="doc-bloco" id="bloco-rececao" hidden>
          <div class="doc-barra">
            <span>Receção do betão</span>
            <span class="barra-lado"><span class="mono" id="resumo-volume"></span></span>
          </div>
          <div class="campos" id="rececao-resumo"></div>
          <p id="aviso-centrais" class="aviso-bloqueio" hidden></p>
          <div id="lista-guias" class="guias"></div>

          <details id="forma-guia-dobra" class="dobra dobra-clara">
            <summary>Registar guia de remessa</summary>
            <form id="forma-guia">
              <div class="campos">
                <div class="campo campo-largo">
                  <label for="foto-guia">Fotografia da guia</label>
                  <input id="foto-guia" name="foto-guia" type="file"
                         accept="image/jpeg,image/png,image/webp" capture="environment" required>
                  <label class="caixa" for="foto-galeria">
                    <input id="foto-galeria" name="foto-galeria" type="checkbox">
                    Veio da galeria, não da câmara
                  </label>
                </div>
                <div class="campo campo-largo" id="campo-justificacao" hidden>
                  <label for="justificacao-galeria">Porque não foi fotografada na hora</label>
                  <input id="justificacao-galeria" name="justificacao-galeria" type="text"
                         autocomplete="off"
                         placeholder="Telemóvel sem bateria; guia fotografada no escritório">
                </div>
              </div>

              <div class="campos">
                <div class="linha-campos linha-3">
                  <div class="campo">
                    <label for="numero-guia">N.º da guia</label>
                    <input id="numero-guia" class="mono" name="numero-guia" type="text" required
                           autocomplete="off" placeholder="118588">
                  </div>
                  <div class="campo">
                    <label for="central-guia">Central</label>
                    <select id="central-guia" name="central-guia" required></select>
                  </div>
                  <div class="campo">
                    <label for="volume-guia">Volume (m³)</label>
                    <input id="volume-guia" class="mono" name="volume-guia" type="text" required
                           inputmode="decimal" autocomplete="off" placeholder="8,00">
                  </div>
                </div>
                <div class="linha-campos linha-3">
                  <div class="campo">
                    <label for="classe-guia">Classe de betão</label>
                    <input id="classe-guia" class="mono" name="classe-guia" type="text" required
                           autocomplete="off" minlength="3">
                  </div>
                  <div class="campo">
                    <label for="data-guia">Data e hora da betonagem</label>
                    <input id="data-guia" class="mono" name="data-guia" type="datetime-local" required>
                  </div>
                  <div class="campo">
                    <label for="hora-carga">Hora de carga <span class="op">opcional</span></label>
                    <input id="hora-carga" class="mono" name="hora-carga" type="datetime-local">
                  </div>
                </div>
                <div class="linha-campos linha-2">
                  <div class="campo">
                    <label for="slump-guia">Slump (mm) <span class="op">opcional</span></label>
                    <input id="slump-guia" class="mono" name="slump-guia" type="text"
                           inputmode="numeric" autocomplete="off" placeholder="120">
                  </div>
                  <div class="campo">
                    <label for="temperatura-guia">Temperatura (°C) <span class="op">opcional</span></label>
                    <input id="temperatura-guia" class="mono" name="temperatura-guia" type="text"
                           inputmode="decimal" autocomplete="off" placeholder="22,5">
                  </div>
                </div>
              </div>

              <div class="doc-accao">
                <button id="botao-guia" class="btn btn-p" type="submit">Registar guia</button>
              </div>
            </form>
          </details>

          ${
            podeCriarCentral
              ? `<details id="forma-central-dobra" class="dobra dobra-clara">
            <summary>Nova central de betonagem</summary>
            <form id="forma-central" class="forma-curta">
              <label for="designacao-central">Designação</label>
              <input id="designacao-central" name="designacao-central" type="text" required
                     autocomplete="off" placeholder="Betão Liz — Lagos">
              <label for="prefixo-central">Prefixo das guias <span class="op">opcional</span></label>
              <input id="prefixo-central" class="mono" name="prefixo-central" type="text"
                     autocomplete="off" placeholder="BL">
              <button id="botao-central" class="btn btn-s" type="submit">Criar central</button>
            </form>
          </details>`
              : ''
          }
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
          <button id="botao-fechar" class="btn btn-p" type="button" hidden>Fechar betonagem</button>
        </footer>
      </article>

      <p id="erro-ficha" class="erro" role="alert" hidden></p>
    </div>
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
  const botaoFechar = destino.querySelector<HTMLButtonElement>('#botao-fechar')!
  const blocoRececao = destino.querySelector<HTMLElement>('#bloco-rececao')!
  const formaGuiaDobra = destino.querySelector<HTMLDetailsElement>('#forma-guia-dobra')!
  const listaGuias = destino.querySelector<HTMLElement>('#lista-guias')!
  const rececaoResumo = destino.querySelector<HTMLElement>('#rececao-resumo')!
  const resumoVolume = destino.querySelector<HTMLElement>('#resumo-volume')!
  const formaGuia = destino.querySelector<HTMLFormElement>('#forma-guia')!
  const selectCentral = destino.querySelector<HTMLSelectElement>('#central-guia')!
  const atalhoGuias = destino.querySelector<HTMLButtonElement>('#atalho-guias')!
  const avisoCentrais = destino.querySelector<HTMLParagraphElement>('#aviso-centrais')!

  // O atalho leva ao bloco e abre a dobra — quem carrega nele quer registar,
  // não quer chegar lá e ter de abrir mais uma coisa.
  atalhoGuias.addEventListener('click', () => {
    formaGuiaDobra.open = true
    blocoRececao.scrollIntoView({ behavior: 'smooth', block: 'start' })
  })

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
    // Fechar é de quem regista as guias, não só de quem inspecciona — o
    // fechar_betonagem aceita empreiteiro, fiscalização e direcção de qualidade.
    botaoFechar.hidden = estadoPab !== 'EM_BETONAGEM'
    blocoRececao.hidden = !COM_RECECAO.includes(estadoPab)
    // Depois de fechada, as guias ficam para leitura: a R7 já não deixa entrar
    // mais nenhuma, e mostrar um formulário que o servidor vai recusar é
    // convidar alguém a escrever para nada.
    const aceitaGuias = estadoPab === 'APROVADO' || estadoPab === 'EM_BETONAGEM'
    formaGuiaDobra.hidden = !aceitaGuias
    atalhoGuias.hidden = !aceitaGuias
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

  botaoFechar.addEventListener('click', () => {
    executar(
      () => fecharBetonagem(pab.id),
      (estado) => {
        estadoPab = estado
        desenharEstado()
        recarregar()
      },
    )
  })

  // ── receção do betão ──────────────────────────────────────────────────────

  const foto = destino.querySelector<HTMLInputElement>('#foto-guia')!
  const daGaleria = destino.querySelector<HTMLInputElement>('#foto-galeria')!
  const campoJustificacao = destino.querySelector<HTMLElement>('#campo-justificacao')!
  const justificacao = destino.querySelector<HTMLInputElement>('#justificacao-galeria')!
  const numeroGuia = destino.querySelector<HTMLInputElement>('#numero-guia')!
  const volumeGuia = destino.querySelector<HTMLInputElement>('#volume-guia')!
  const classeGuia = destino.querySelector<HTMLInputElement>('#classe-guia')!
  const dataGuia = destino.querySelector<HTMLInputElement>('#data-guia')!
  const horaCarga = destino.querySelector<HTMLInputElement>('#hora-carga')!
  const slumpGuia = destino.querySelector<HTMLInputElement>('#slump-guia')!
  const temperaturaGuia = destino.querySelector<HTMLInputElement>('#temperatura-guia')!
  const botaoGuia = destino.querySelector<HTMLButtonElement>('#botao-guia')!

  // A classe pré-preenchida com a do PAB, e editável: o que veio pode não ser o
  // que se pediu, e é isso que o registo tem de poder dizer. Se divergir, o
  // servidor grava na mesma e marca a guia como não conforme — não se apaga.
  classeGuia.value = pab.classe_betao

  daGaleria.addEventListener('change', () => {
    campoJustificacao.hidden = !daGaleria.checked
    justificacao.required = daGaleria.checked
    if (!daGaleria.checked) justificacao.value = ''
  })

  formaGuia.addEventListener('submit', (evento) => {
    evento.preventDefault()

    const ficheiro = foto.files?.[0]
    if (ficheiro === undefined) {
      mostrarErro('Escolha ou tire a fotografia da guia. Sem fotografia não há registo.')
      return
    }

    const volume = lerNumero(volumeGuia.value)
    if (volume.estado !== 'ok' || volume.valor <= 0) {
      mostrarErro('Indique o volume desta guia em metros cúbicos, maior do que zero.')
      volumeGuia.focus()
      return
    }

    const slump = lerNumero(slumpGuia.value)
    if (slump.estado === 'invalido') {
      mostrarErro('O slump tem de ser um número em milímetros, ou ficar vazio.')
      slumpGuia.focus()
      return
    }

    const temperatura = lerNumero(temperaturaGuia.value)
    if (temperatura.estado === 'invalido') {
      mostrarErro('A temperatura tem de ser um número em graus, ou ficar vazia.')
      temperaturaGuia.focus()
      return
    }

    const origem = daGaleria.checked ? 'GALERIA' : 'CAMARA'
    const porque = daGaleria.checked ? justificacao.value.trim() : null

    botaoGuia.textContent = 'A carregar a fotografia…'
    executar(
      async () => {
        // Duas viagens, por esta ordem e não ao contrário: a fotografia
        // primeiro, porque o registo da guia exige um ficheiro já registado.
        const ficheiroId = await carregarFotoGuia(obra.id, ficheiro, origem, porque)
        botaoGuia.textContent = 'A registar a guia…'
        await registarGuia({
          pabId: pab.id,
          centralId: selectCentral.value,
          numeroGuia: numeroGuia.value.trim(),
          dataHoraBetonagem: new Date(dataGuia.value).toISOString(),
          volumeM3: volume.valor,
          classeBetao: classeGuia.value.trim(),
          ficheiroId,
          horaCarga: horaCarga.value === '' ? null : new Date(horaCarga.value).toISOString(),
          slumpMm: slump.estado === 'ok' ? slump.valor : null,
          temperaturaC: temperatura.estado === 'ok' ? temperatura.valor : null,
        })
      },
      () => {
        formaGuia.reset()
        classeGuia.value = pab.classe_betao
        campoJustificacao.hidden = true
        recarregar()
      },
    )
    botaoGuia.textContent = 'Registar guia'
  })

  const formaCentral = destino.querySelector<HTMLFormElement>('#forma-central')
  if (formaCentral !== null) {
    const designacao = destino.querySelector<HTMLInputElement>('#designacao-central')!
    const prefixo = destino.querySelector<HTMLInputElement>('#prefixo-central')!
    formaCentral.addEventListener('submit', (evento) => {
      evento.preventDefault()
      executar(
        () =>
          criarCentral(
            designacao.value.trim(),
            prefixo.value.trim() === '' ? null : prefixo.value.trim(),
          ),
        () => {
          formaCentral.reset()
          recarregar()
        },
      )
    })
  }

  const verFoto = (guia: Guia): void => {
    erro.hidden = true
    enderecoDaFoto(guia.ficheiro_id)
      .then((endereco) => {
        // noopener: a página aberta não fica com referência para esta.
        window.open(endereco, '_blank', 'noopener')
      })
      .catch(mostrarErro)
  }

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

    // ── receção do betão ────────────────────────────────────────────────────
    const resumo = resumoDaRececao(dados.guias, dados.centrais)
    const previsto = Number(pab.volume_previsto_m3)

    resumoVolume.textContent = `${resumo.volume.toFixed(2)} / ${previsto.toFixed(2)} m³`

    // O desvio só é conclusivo com a betonagem fechada. Num PAB em curso,
    // ficar abaixo do previsto é o estado normal — dizer «em falta» todos os
    // dias é a forma mais rápida de fazer com que ninguém olhe para o painel.
    const fechada = estadoPab === 'BETONADO' || estadoPab === 'FCQ_FECHADA'
    const desvio = previsto === 0 ? 0 : ((resumo.volume - previsto) / previsto) * 100
    const leituraDoDesvio =
      dados.guias.length === 0
        ? null
        : !fechada
          ? `${desvio >= 0 ? '+' : ''}${desvio.toFixed(1)} % — betonagem em curso, ainda não é um desvio`
          : `${desvio >= 0 ? '+' : ''}${desvio.toFixed(1)} % face ao previsto`

    rececaoResumo.replaceChildren(
      linha(
        campo('Origem do betão', resumo.origens === '' ? null : resumo.origens),
        campo('Volume betonado', `${resumo.volume.toFixed(2)} m³`),
        campo('Desvio', leituraDoDesvio),
      ),
      linha(
        campo('Hora de início', horaLocal(resumo.inicio)),
        campo('Hora de fim', horaLocal(resumo.fim)),
        campo('Guias', String(dados.guias.length)),
      ),
    )

    desenharGuias(listaGuias, dados, verFoto)

    preencherCentrais(selectCentral, dados.centrais)

    // Sem central não há guia: o registar_guia exige uma, activa e da
    // organização. Um <select> vazio deixaria quem regista a carregar num botão
    // que ia falhar sem dizer porquê — e quem regista é o empreiteiro, que não
    // pode criar centrais (criar_central só aceita ADMIN, direção de qualidade
    // e fiscalização).
    const semCentrais = dados.centrais.filter((c) => c.ativa).length === 0
    avisoCentrais.hidden = !semCentrais
    avisoCentrais.textContent = podeCriarCentral
      ? 'Não há centrais de betonagem nesta organização. Crie uma abaixo antes de registar a primeira guia.'
      : 'Não há centrais de betonagem nesta organização, e o seu perfil não as cria. ' +
        'Peça à DDN que registe a central antes de lançar guias.'
    botaoGuia.disabled = semCentrais

    const guiasEmFalta = dados.guias.length === 0
    atalhoGuias.textContent = guiasEmFalta
      ? 'Registar a primeira guia de remessa desta betonagem →'
      : `Registar mais uma guia · ${dados.guias.length} já registada${dados.guias.length === 1 ? '' : 's'} →`

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
