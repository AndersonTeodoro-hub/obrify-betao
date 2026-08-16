// Ecrã de uma obra — o mais usado da aplicação. Duas zonas:
//
//   ESQUERDA   navegação: frentes (dobradas) e a lista de pedidos, com filtro
//   DIREITA    trabalho: o formulário de submissão, ou o pedido escolhido
//
// Em desktop ficam lado a lado e escolher um pedido à esquerda abre-o à
// direita, sem sair do ecrã. Em ecrã estreito empilham, e a lista sai da frente
// enquanto houver um pedido aberto.
//
// Isto não é gosto: numa obra real são dezenas de frentes e centenas de pedidos
// ao longo de meses. Numa coluna única, o formulário e o documento ficam para
// sempre no fundo, atrás de uma lista que só cresce.
//
// A frente é obrigatória para submeter um PAB — pab.frente_id é NOT NULL — e é
// ela que torna aplicável a regra R6, o bloqueio de duas betonagens em curso na
// mesma frente. Sem frente não há pedido, e é por isso que o painel das frentes
// fica aberto enquanto não houver nenhuma.
//
// O que a submissão faz do outro lado é mais do que inserir uma linha: atribui
// o número sequencial da obra e cria a ficha I.CR.033 em rascunho, 1:1 com o
// PAB.
//
// O filtro é sobre o que já está em memória — lerPabs traz os pedidos da obra e
// a procura corre sobre esse array. Não há leitura nova nem paginação.
// ponytail: filtro em memória; se uma obra passar do tecto de linhas do
// PostgREST, passa a filtro no servidor.

import {
  atualizarObra,
  criarFrente,
  lerFrentes,
  lerPabs,
  mensagemDeErro,
  submeterPab,
  type Frente,
  type Obra,
  type Pab,
} from './dominio'
import { lerNumero, textoOuNulo } from './campos'
import { montarEcraFicha } from './ecra-ficha'
import { montarEcraPainel } from './ecra-painel'
import type { UtilizadorDeDominio } from './sessao'

/** Quem pode criar frentes, segundo betonagens.criar_frente. */
const PODE_CRIAR_FRENTE = ['ADMIN', 'DIRETOR_QUALIDADE', 'FISCALIZACAO']

/** Quem pode submeter um PAB, segundo betonagens.submeter_pab. O ADMIN não:
 *  administra contas e obras, não pede betonagens. */
const PODE_SUBMETER_PAB = ['EMPREITEIRO', 'FISCALIZACAO', 'DIRETOR_QUALIDADE']

/** Quem pode corrigir o cabeçalho do impresso, segundo
 *  betonagens.atualizar_obra. Os mesmos que criam obras. */
const PODE_EDITAR_OBRA = ['ADMIN', 'DIRETOR_QUALIDADE']

function dataISO(dias: number): string {
  const d = new Date()
  d.setDate(d.getDate() + dias)
  return d.toISOString().slice(0, 10)
}


/**
 * O cabeçalho de identificação do impresso, nos quatro campos marcados com
 * data-obra. Serve o formulário e volta a correr depois de o cabeçalho ser
 * corrigido.
 *
 * Por textContent: são valores de base de dados escritos por pessoas.
 */
function escreverCabecalhoDaObra(raiz: HTMLElement, obra: Obra): void {
  for (const alvo of raiz.querySelectorAll<HTMLElement>('[data-obra]')) {
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
    alvo.classList.toggle('por-indicar', valor === null)
  }
}

/** A janela prevista, quando existir. Só a hora de início já diz alguma coisa;
 *  só a de fim, sem início, não diz — e por isso não se imprime sozinha. */
function horas(pab: Pab): string {
  if (pab.hora_prevista_inicio === null) return ''
  const fim = pab.hora_prevista_fim === null ? '' : `–${pab.hora_prevista_fim}`
  return ` ${pab.hora_prevista_inicio}${fim}`
}

// ── desenho ─────────────────────────────────────────────────────────────────
// Sempre com o DOM e textContent, nunca por interpolação em innerHTML: estes
// valores foram escritos por pessoas e vêm da base de dados.

function desenharFrentes(destino: HTMLElement, frentes: Frente[]): void {
  destino.replaceChildren()

  if (frentes.length === 0) {
    const vazio = document.createElement('li')
    vazio.className = 'vazio'
    vazio.textContent = 'Ainda não há frentes nesta obra.'
    destino.append(vazio)
    return
  }

  for (const frente of frentes) {
    const designacao = document.createElement('span')
    designacao.className = 'designacao'
    designacao.textContent = frente.designacao

    const item = document.createElement('li')
    item.className = 'frente'
    item.append(designacao)

    if (!frente.ativa) {
      const inactiva = document.createElement('span')
      inactiva.className = 'inactiva'
      inactiva.textContent = 'inactiva'
      item.append(inactiva)
    }

    destino.append(item)
  }
}

/** O texto contra o qual o filtro compara: tudo o que se procura de cabeça —
 *  o número, as peças, a frente e o estado. */
function textoPesquisavel(pab: Pab, frente: string): string {
  return [String(pab.numero), pab.elemento, frente, pab.estado, pab.classe_betao]
    .join(' ')
    .toLowerCase()
}

function desenharPabs(
  destino: HTMLElement,
  pabs: Pab[],
  frentes: Frente[],
  seleccionado: string | null,
  aoSeleccionar: (pab: Pab) => void,
  vazioPorFiltro: boolean,
): void {
  destino.replaceChildren()

  if (pabs.length === 0) {
    const vazio = document.createElement('li')
    vazio.className = 'vazio'
    vazio.textContent = vazioPorFiltro
      ? 'Nenhum pedido corresponde ao filtro.'
      : 'Ainda não há pedidos de betonagem nesta obra.'
    destino.append(vazio)
    return
  }

  const designacaoDaFrente = new Map(frentes.map((f) => [f.id, f.designacao]))

  for (const pab of pabs) {
    // A referência do documento, como numa capa de processo: PAB e o número.
    const referencia = document.createElement('span')
    referencia.className = 'mono ref-doc'
    referencia.textContent = `PAB ${pab.numero}`

    const titulo = document.createElement('span')
    titulo.className = 'titulo-doc'
    titulo.textContent = pab.elemento

    // frente · classe · volume · processo — só o que existir
    const sub = document.createElement('span')
    sub.className = 'sub-doc'
    sub.textContent = [
      designacaoDaFrente.get(pab.frente_id) ?? 'frente desconhecida',
      pab.classe_betao,
      `${pab.volume_previsto_m3} m³`,
      pab.processo_betonagem,
    ]
      .filter((parte): parte is string => parte !== null && parte !== '')
      .join(' · ')

    const corpo = document.createElement('span')
    corpo.className = 'corpo-doc'
    corpo.append(titulo, sub)

    const estado = document.createElement('span')
    estado.className = `estado estado-${pab.estado}`
    estado.textContent = pab.estado.replace('_', ' ')

    const data = document.createElement('span')
    data.className = 'mono data-doc'
    data.textContent = `${pab.data_prevista}${horas(pab)}`

    const lado = document.createElement('span')
    lado.className = 'lado-doc'
    lado.append(estado, data)

    const seta = document.createElement('span')
    seta.className = 'seta'
    seta.setAttribute('aria-hidden', 'true')
    seta.textContent = '›'

    // Abre para todos os perfis. Ler o próprio pedido não é inspeccionar: o
    // documento é o mesmo, e o bloco de verificações fica inerte para quem não
    // inspecciona — os botões desactivados e a nota a dizer de quem é a ficha.
    // Quem decide o que se pode marcar é betonagens.marcar_item_fcq, e isso não
    // muda por a linha da esquerda abrir.
    const botao = document.createElement('button')
    botao.type = 'button'
    botao.className = 'linha-doc'
    botao.append(referencia, corpo, lado, seta)
    // aria-current e não só uma classe: quem navega por leitor de ecrã tem de
    // saber qual dos pedidos é o que está aberto à direita.
    if (pab.id === seleccionado) botao.setAttribute('aria-current', 'true')
    botao.addEventListener('click', () => aoSeleccionar(pab))

    const item = document.createElement('li')
    item.append(botao)
    destino.append(item)
  }
}

function preencherFrentes(select: HTMLSelectElement, frentes: Frente[]): void {
  const escolhida = select.value
  select.replaceChildren()

  for (const frente of frentes) {
    const opcao = document.createElement('option')
    opcao.value = frente.id
    opcao.textContent = frente.designacao
    select.append(opcao)
  }

  if (frentes.some((f) => f.id === escolhida)) select.value = escolhida
}

// ── ecrã ────────────────────────────────────────────────────────────────────

export function montarEcraObra(
  destino: HTMLElement,
  obra: Obra,
  utilizador: UtilizadorDeDominio,
  aoVoltar: () => void,
): void {
  const podeCriarFrente = PODE_CRIAR_FRENTE.includes(utilizador.perfil)
  const podeSubmeter = PODE_SUBMETER_PAB.includes(utilizador.perfil)
  const podeEditarObra = PODE_EDITAR_OBRA.includes(utilizador.perfil)

  destino.innerHTML = `
    <section class="ecra ecra-obra">
      <button id="botao-voltar" class="voltar" type="button">‹ Obras</button>

      <header class="cabecalho-obra">
        <div class="mono codigo-obra"></div>
        <h1 class="designacao-obra"></h1>
      </header>

      <p id="erro-obra" class="erro" role="alert" hidden></p>

      ${
        podeEditarObra
          ? `<details id="editar-obra" class="editor-obra">
        <summary>Cabeçalho do impresso</summary>
        <form id="forma-editar-obra">
          <p class="nota-grupo">
            É o que aparece no topo de cada pedido de betonagem desta obra.
            O código não se altera: é a identidade da obra.
          </p>

          <label for="edit-designacao">Designação</label>
          <input id="edit-designacao" name="edit-designacao" type="text" required
                 autocomplete="off" minlength="3">

          <label for="edit-dono-obra">Dono de obra</label>
          <input id="edit-dono-obra" name="edit-dono-obra" type="text" autocomplete="off"
                 placeholder="Palmares — Comp. Empreendimentos Turísticos, SA">

          <label for="edit-empreiteiro">Adjudicatário</label>
          <input id="edit-empreiteiro" name="edit-empreiteiro" type="text" autocomplete="off"
                 placeholder="Ferreira Construção, S.A.">

          <label for="edit-fiscalizacao">Fiscalização</label>
          <input id="edit-fiscalizacao" name="edit-fiscalizacao" type="text" autocomplete="off"
                 placeholder="DDN — Engenharia e Fiscalização">

          <p class="nota-grupo">
            Um campo deixado em branco fica em branco: isto substitui os quatro valores.
          </p>

          <button id="botao-editar-obra" class="btn btn-p" type="submit">Gravar cabeçalho</button>
        </form>
      </details>`
          : ''
      }

      <nav class="zona-nav">
        <button id="botao-painel" class="btn-painel" type="button">
          Painel de controlo da obra
        </button>

        <details id="painel-frentes" class="dobra">
          <summary>Frentes <span id="conta-frentes" class="mono conta"></span></summary>
          <ul id="lista-frentes" class="lista"><li class="vazio">A carregar…</li></ul>

          ${
            podeCriarFrente
              ? `<form id="forma-frente" class="forma-curta">
            <label for="designacao-frente">Nova frente</label>
            <input id="designacao-frente" name="designacao-frente" type="text" required
                   autocomplete="off" placeholder="Bloco B / Piso 0">
            <button id="botao-criar-frente" class="btn btn-p" type="submit">Criar frente</button>
          </form>`
              : `<p class="nota-perfil">O perfil ${utilizador.perfil} não cria frentes.</p>`
          }
        </details>

        <div class="painel-pabs">
          <div class="cabeca-painel">
            <h2>Pedidos</h2>
            <span id="conta-pabs" class="mono conta"></span>
          </div>
          <input id="filtro-pabs" class="filtro" type="search" autocomplete="off"
                 placeholder="Filtrar: número, peças, frente, estado"
                 aria-label="Filtrar pedidos de betonagem">
          <ul id="lista-pabs" class="lista lista-nav"><li class="vazio">A carregar…</li></ul>
        </div>
      </nav>

      <div class="area-trabalho">
        <div id="doc-pab" hidden></div>

        <div id="zona-submissao">
      ${
        podeSubmeter
          ? `<p id="sem-frentes" class="nota-perfil" hidden>
        Não há frentes nesta obra. Um pedido tem sempre uma frente — cria uma primeiro.
      </p>
      <form id="forma-pab" class="doc doc-preenchimento" hidden>
        <div class="doc-titulo">
          <h1>Pedido de autorização de betonagem</h1>
          <span class="estado estado-novo">por submeter</span>
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
          <span class="numero-por-atribuir">atribuído ao submeter</span>
        </div>

        <section class="doc-bloco">
          <h3>Localização</h3>
          <div class="campos">
            <div class="linha-campos linha-2">
              <div class="campo">
                <label for="frente-pab">Parte da obra</label>
                <select id="frente-pab" name="frente-pab" required></select>
              </div>
              <div class="campo">
                <label for="referencia-desenho">Ref.ª do desenho <span class="op">opcional</span></label>
                <input id="referencia-desenho" class="mono" name="referencia-desenho" type="text"
                       autocomplete="off" placeholder="EST-04-P2">
              </div>
            </div>
            <div class="campo campo-largo">
              <label for="elemento">Peças a betonar</label>
              <textarea id="elemento" name="elemento" rows="3" required minlength="3"
                        placeholder="Pilares P2c P4c P1c&#10;Muro M3c do eixo 12c ao eixo 15c"></textarea>
            </div>
          </div>
        </section>

        <section class="doc-bloco">
          <h3>Elementos técnicos</h3>
          <div class="campos">
            <div class="linha-campos linha-4">
              <div class="campo">
                <label for="classe-betao">Identificação do betão</label>
                <input id="classe-betao" class="mono" name="classe-betao" type="text" required
                       autocomplete="off" placeholder="C30/37" minlength="3">
              </div>
              <div class="campo">
                <label for="classe-exposicao">Classe <span class="op">opcional</span></label>
                <input id="classe-exposicao" class="mono" name="classe-exposicao" type="text"
                       autocomplete="off" placeholder="XC4(P)">
              </div>
              <div class="campo">
                <label for="classe-consistencia">Slump <span class="op">opcional</span></label>
                <input id="classe-consistencia" class="mono" name="classe-consistencia" type="text"
                       autocomplete="off" placeholder="S4">
              </div>
              <div class="campo">
                <label for="volume">Vol. prev. (m³)</label>
                <input id="volume" class="mono" name="volume" type="text" required
                       inputmode="decimal" autocomplete="off" placeholder="40,00">
              </div>
            </div>
            <div class="linha-campos linha-3">
              <div class="campo">
                <label for="dmax">Dmáx do agregado (mm) <span class="op">opcional</span></label>
                <input id="dmax" class="mono" name="dmax" type="text" inputmode="numeric"
                       autocomplete="off" placeholder="22">
              </div>
              <div class="campo">
                <label for="processo-betonagem">Processo de betonagem</label>
                <input id="processo-betonagem" name="processo-betonagem" type="text" required
                       autocomplete="off" placeholder="Bomba / Balde / Descarga directa"
                       minlength="3">
              </div>
              <div class="campo">
                <label for="processo-cura">Processo de cura <span class="op">opcional</span></label>
                <input id="processo-cura" name="processo-cura" type="text" autocomplete="off"
                       placeholder="Rega / manta / cura química">
              </div>
            </div>
          </div>
        </section>

        <section class="doc-bloco">
          <h3>Data prevista para</h3>
          <div class="campos">
            <div class="linha-campos linha-4">
              <div class="campo">
                <label for="data-pedido">Data do pedido</label>
                <input id="data-pedido" class="mono" name="data-pedido" type="date" required>
              </div>
              <div class="campo">
                <label for="data-prevista">Betonagem</label>
                <input id="data-prevista" class="mono" name="data-prevista" type="date" required>
              </div>
              <div class="campo">
                <label for="hora-inicio">Hora de início <span class="op">opcional</span></label>
                <input id="hora-inicio" class="mono" name="hora-inicio" type="time">
              </div>
              <div class="campo">
                <label for="hora-fim">Hora de fim <span class="op">opcional</span></label>
                <input id="hora-fim" class="mono" name="hora-fim" type="time">
              </div>
            </div>
            <div class="linha-campos linha-2">
              <div class="campo">
                <label for="descofragem">Descofragem <span class="op">opcional</span></label>
                <input id="descofragem" class="mono" name="descofragem" type="date">
                <label class="caixa" for="descofragem-na">
                  <input id="descofragem-na" name="descofragem-na" type="checkbox">
                  Não se aplica
                </label>
              </div>
              <div class="campo">
                <label for="escoramento">Retirada do escoramento <span class="op">opcional</span></label>
                <input id="escoramento" class="mono" name="escoramento" type="date">
                <label class="caixa" for="escoramento-na">
                  <input id="escoramento-na" name="escoramento-na" type="checkbox">
                  Não se aplica
                </label>
              </div>
            </div>
          </div>
        </section>

        <section class="doc-bloco">
          <h3>Observações</h3>
          <div class="campos">
            <div class="campo campo-largo">
              <label for="observacoes">Observações <span class="op">opcional</span></label>
              <textarea id="observacoes" name="observacoes" rows="3"
                        placeholder="O que a fiscalização precisa de saber antes de vir ao local."></textarea>
            </div>
          </div>
        </section>

        <div class="doc-accao">
          <button id="botao-submeter" class="btn btn-p" type="submit">Submeter pedido</button>
        </div>
      </form>`
          : `<p class="sem-seleccao">
        O perfil ${utilizador.perfil} não submete pedidos de betonagem.<br>
        Escolha um pedido na lista para o abrir.
      </p>`
      }
        </div>
      </div>
    </section>
  `

  destino.querySelector<HTMLDivElement>('.codigo-obra')!.textContent = obra.codigo
  destino.querySelector<HTMLHeadingElement>('.designacao-obra')!.textContent = obra.designacao

  const listaFrentes = destino.querySelector<HTMLUListElement>('#lista-frentes')!
  const listaPabs = destino.querySelector<HTMLUListElement>('#lista-pabs')!
  const erro = destino.querySelector<HTMLParagraphElement>('#erro-obra')!

  const mostrarErro = (causa: unknown): void => {
    erro.textContent = mensagemDeErro(causa)
    erro.hidden = false
  }

  const formaPab = destino.querySelector<HTMLFormElement>('#forma-pab')
  const semFrentes = destino.querySelector<HTMLParagraphElement>('#sem-frentes')
  const selectFrente = destino.querySelector<HTMLSelectElement>('#frente-pab')

  const seccao = destino.querySelector<HTMLElement>('.ecra-obra')!
  const painelFrentes = destino.querySelector<HTMLDetailsElement>('#painel-frentes')!
  const contaFrentes = destino.querySelector<HTMLSpanElement>('#conta-frentes')!
  const contaPabs = destino.querySelector<HTMLSpanElement>('#conta-pabs')!
  const filtro = destino.querySelector<HTMLInputElement>('#filtro-pabs')!
  const zonaSubmissao = destino.querySelector<HTMLElement>('#zona-submissao')!
  const docPab = destino.querySelector<HTMLElement>('#doc-pab')!

  // ── selecção e filtro ─────────────────────────────────────────────────────
  // O PAB escolhido não sobe ao estado de navegação: se subisse, cada clique
  // redesenharia o ecrã inteiro e levaria consigo o que estivesse escrito no
  // formulário. Fica aqui, e só a área de trabalho é remontada.
  let pabsCarregados: Pab[] = []
  let frentesCarregadas: Frente[] = []
  // O que está aberto na área de trabalho. Uma união e não dois booleanos: com
  // dois, existiria o estado «painel aberto E pedido aberto», que não quer
  // dizer nada e alguém teria de se lembrar de o impedir.
  let aberto: { tipo: 'pab'; pab: Pab } | { tipo: 'painel' } | null = null
  const seleccionadoId = (): string | null => (aberto?.tipo === 'pab' ? aberto.pab.id : null)

  const nomeDaFrente = (id: string): string =>
    frentesCarregadas.find((f) => f.id === id)?.designacao ?? ''

  const desenharLista = (): void => {
    const termo = filtro.value.trim().toLowerCase()
    const visiveis =
      termo === ''
        ? pabsCarregados
        : pabsCarregados.filter((p) =>
            textoPesquisavel(p, nomeDaFrente(p.frente_id)).includes(termo),
          )

    // A contagem diz sempre quantos ficaram de fora. Uma lista filtrada sem o
    // dizer é a maneira mais fácil de alguém concluir que um pedido não existe.
    contaPabs.textContent =
      visiveis.length === pabsCarregados.length
        ? String(pabsCarregados.length)
        : `${visiveis.length} de ${pabsCarregados.length}`

    desenharPabs(listaPabs, visiveis, frentesCarregadas, seleccionadoId(), escolher, termo !== '')
  }

  const mostrarAreaDeTrabalho = (): void => {
    const temCoisa = aberto !== null
    docPab.hidden = !temCoisa
    zonaSubmissao.hidden = temCoisa
    // Em ecrã estreito não cabem as duas zonas: com alguma coisa aberta, a
    // lista sai da frente e volta com o botão de voltar do próprio conteúdo.
    seccao.classList.toggle('a-ver-pab', temCoisa)
  }

  const fechar = (): void => {
    aberto = null
    mostrarAreaDeTrabalho()
    docPab.replaceChildren()
    desenharLista()
  }

  function escolher(pab: Pab): void {
    aberto = { tipo: 'pab', pab }
    mostrarAreaDeTrabalho()
    montarEcraFicha(docPab, obra, pab, utilizador, fechar)
    desenharLista()
  }

  destino.querySelector<HTMLButtonElement>('#botao-painel')!.addEventListener('click', () => {
    aberto = { tipo: 'painel' }
    mostrarAreaDeTrabalho()
    montarEcraPainel(docPab, obra, fechar)
    desenharLista()
  })

  filtro.addEventListener('input', desenharLista)

  const recarregar = (): void => {
    Promise.all([lerFrentes(obra.id), lerPabs(obra.id)])
      .then(([frentes, pabs]) => {
        frentesCarregadas = frentes
        pabsCarregados = pabs

        desenharFrentes(listaFrentes, frentes)
        contaFrentes.textContent = String(frentes.length)
        // Fica aberto enquanto não houver frentes: sem frente não há pedido, e
        // esconder o que falta fazer atrás de um triângulo não ajuda ninguém.
        painelFrentes.open = frentes.length === 0
        desenharLista()

        if (formaPab !== null && semFrentes !== null && selectFrente !== null) {
          preencherFrentes(selectFrente, frentes)
          formaPab.hidden = frentes.length === 0
          semFrentes.hidden = frentes.length > 0
        }
      })
      .catch(mostrarErro)
  }

  destino.querySelector<HTMLButtonElement>('#botao-voltar')!.addEventListener('click', aoVoltar)

  const formaEditar = destino.querySelector<HTMLFormElement>('#forma-editar-obra')
  if (formaEditar !== null) {
    const botao = destino.querySelector<HTMLButtonElement>('#botao-editar-obra')!
    const designacao = destino.querySelector<HTMLInputElement>('#edit-designacao')!
    const donoObra = destino.querySelector<HTMLInputElement>('#edit-dono-obra')!
    const empreiteiro = destino.querySelector<HTMLInputElement>('#edit-empreiteiro')!
    const fiscalizacao = destino.querySelector<HTMLInputElement>('#edit-fiscalizacao')!

    // O formulário mostra o estado actual, porque o servidor SUBSTITUI os
    // quatro campos: enviar um formulário meio vazio apagaria o resto.
    designacao.value = obra.designacao
    donoObra.value = obra.dono_obra ?? ''
    empreiteiro.value = obra.empreiteiro ?? ''
    fiscalizacao.value = obra.fiscalizacao ?? ''

    formaEditar.addEventListener('submit', (evento) => {
      evento.preventDefault()
      erro.hidden = true
      botao.disabled = true
      botao.textContent = 'A gravar…'

      atualizarObra(
        obra.id,
        designacao.value.trim(),
        textoOuNulo(donoObra.value),
        textoOuNulo(empreiteiro.value),
        textoOuNulo(fiscalizacao.value),
      )
        .then((actualizada) => {
          // A mesma referência que o main.ts guarda no estado da vista. Escrever
          // aqui mantém coerente o que se vê ao voltar e ao entrar no PAB, sem
          // enfiar mais um callback pelo main.ts acima.
          obra.designacao = actualizada.designacao
          obra.dono_obra = actualizada.dono_obra
          obra.empreiteiro = actualizada.empreiteiro
          obra.fiscalizacao = actualizada.fiscalizacao

          destino.querySelector<HTMLHeadingElement>('.designacao-obra')!.textContent =
            obra.designacao
          escreverCabecalhoDaObra(destino, obra)
          destino.querySelector<HTMLDetailsElement>('#editar-obra')!.open = false
        })
        .catch(mostrarErro)
        .finally(() => {
          botao.disabled = false
          botao.textContent = 'Gravar cabeçalho'
        })
    })
  }

  const formaFrente = destino.querySelector<HTMLFormElement>('#forma-frente')
  if (formaFrente !== null) {
    const botao = destino.querySelector<HTMLButtonElement>('#botao-criar-frente')!
    const designacao = destino.querySelector<HTMLInputElement>('#designacao-frente')!

    formaFrente.addEventListener('submit', (evento) => {
      evento.preventDefault()
      erro.hidden = true
      botao.disabled = true
      botao.textContent = 'A criar…'

      criarFrente(obra.id, designacao.value.trim())
        .then(() => {
          formaFrente.reset()
          recarregar()
        })
        .catch(mostrarErro)
        .finally(() => {
          botao.disabled = false
          botao.textContent = 'Criar frente'
        })
    })
  }

  if (formaPab !== null && selectFrente !== null) {
    const botao = destino.querySelector<HTMLButtonElement>('#botao-submeter')!
    const elemento = destino.querySelector<HTMLTextAreaElement>('#elemento')!
    const volume = destino.querySelector<HTMLInputElement>('#volume')!
    const classeBetao = destino.querySelector<HTMLInputElement>('#classe-betao')!
    const dataPedido = destino.querySelector<HTMLInputElement>('#data-pedido')!
    const dataPrevista = destino.querySelector<HTMLInputElement>('#data-prevista')!
    const classeExposicao = destino.querySelector<HTMLInputElement>('#classe-exposicao')!
    const classeConsistencia = destino.querySelector<HTMLInputElement>('#classe-consistencia')!
    const dmax = destino.querySelector<HTMLInputElement>('#dmax')!
    const processoBetonagem = destino.querySelector<HTMLInputElement>('#processo-betonagem')!
    const referenciaDesenho = destino.querySelector<HTMLInputElement>('#referencia-desenho')!
    const processoCura = destino.querySelector<HTMLInputElement>('#processo-cura')!
    const horaInicio = destino.querySelector<HTMLInputElement>('#hora-inicio')!
    const horaFim = destino.querySelector<HTMLInputElement>('#hora-fim')!
    const descofragem = destino.querySelector<HTMLInputElement>('#descofragem')!
    const descofragemNA = destino.querySelector<HTMLInputElement>('#descofragem-na')!
    const escoramento = destino.querySelector<HTMLInputElement>('#escoramento')!
    const escoramentoNA = destino.querySelector<HTMLInputElement>('#escoramento-na')!
    const observacoes = destino.querySelector<HTMLTextAreaElement>('#observacoes')!

    escreverCabecalhoDaObra(formaPab, obra)

    // «Não se aplica» e «tem data» excluem-se — é o que os checks da 0016
    // impõem na tabela e o que o submeter_pab recusa com PT422. Marcar a caixa
    // apaga a data à vista de quem a escreveu, em vez de a deitar fora em
    // silêncio na leitura.
    const ligarPar = (caixa: HTMLInputElement, data: HTMLInputElement): void => {
      caixa.addEventListener('change', () => {
        data.disabled = caixa.checked
        if (caixa.checked) data.value = ''
      })
    }
    ligarPar(descofragemNA, descofragem)
    ligarPar(escoramentoNA, escoramento)

    // As peças a betonar são uma descrição longa — «Pilares P2c P4c P1c Muro M3c
    // do eixo 12c ao eixo 15c» é o caso normal, não a excepção. A caixa cresce
    // com o que lá está em vez de esconder o texto atrás de uma barra.
    // Deliberadamente com JS e não com field-sizing: content, que ainda não
    // existe em todo o lado onde isto vai correr.
    const crescerComTexto = (caixa: HTMLTextAreaElement): void => {
      const ajustar = (): void => {
        caixa.style.height = 'auto'
        caixa.style.height = `${caixa.scrollHeight}px`
      }
      caixa.addEventListener('input', ajustar)
    }
    crescerComTexto(elemento)
    crescerComTexto(observacoes)

    // Hoje e amanhã. A data prevista no futuro não é cosmética: R6 só bloqueia a
    // frente por um PAB aprovado cuja data prevista já passou e que não tem
    // guias nenhumas.
    dataPedido.value = dataISO(0)
    dataPrevista.value = dataISO(1)

    formaPab.addEventListener('submit', (evento) => {
      evento.preventDefault()
      erro.hidden = true

      const volumeLido = lerNumero(volume.value)
      if (volumeLido.estado !== 'ok' || volumeLido.valor <= 0) {
        mostrarErro(
          'Indica o volume previsto em metros cúbicos, maior do que zero. ' +
            'Aceita vírgula ou ponto — por exemplo 40,00.',
        )
        volume.focus()
        return
      }

      const dmaxLido = lerNumero(dmax.value)
      if (dmaxLido.estado === 'invalido') {
        mostrarErro('O Dmáx do agregado tem de ser um número em milímetros, ou ficar vazio.')
        dmax.focus()
        return
      }

      botao.disabled = true
      botao.textContent = 'A submeter…'

      submeterPab({
        obraId: obra.id,
        frenteId: selectFrente.value,
        elemento: elemento.value.trim(),
        volumePrevistoM3: volumeLido.valor,
        classeBetao: classeBetao.value.trim(),
        dataPedido: dataPedido.value,
        dataPrevista: dataPrevista.value,
        classeExposicao: textoOuNulo(classeExposicao.value),
        classeConsistencia: textoOuNulo(classeConsistencia.value),
        dmaxAgregadoMm: dmaxLido.estado === 'ok' ? dmaxLido.valor : null,
        referenciaDesenho: textoOuNulo(referenciaDesenho.value),
        processoBetonagem: processoBetonagem.value.trim(),
        processoCura: textoOuNulo(processoCura.value),
        // O <input type="time"> devolve HH:MM ou string vazia, nunca lixo — não
        // há aqui um Number('') à espera de acontecer.
        horaPrevistaInicio: textoOuNulo(horaInicio.value),
        horaPrevistaFim: textoOuNulo(horaFim.value),
        // A data vem vazia quando a caixa está marcada, porque foi apagada
        // quando ela foi marcada. Nada se descarta na leitura.
        descofragemPrevista: textoOuNulo(descofragem.value),
        descofragemAplicavel: !descofragemNA.checked,
        escoramentoRetiradaPrevista: textoOuNulo(escoramento.value),
        escoramentoAplicavel: !escoramentoNA.checked,
        observacoes: textoOuNulo(observacoes.value),
      })
        .then(() => {
          elemento.value = ''
          volume.value = ''
          referenciaDesenho.value = ''
          observacoes.value = ''
          // A altura foi crescida à mão; limpar o texto não a devolve.
          elemento.style.height = ''
          observacoes.style.height = ''
          recarregar()
        })
        .catch(mostrarErro)
        .finally(() => {
          botao.disabled = false
          botao.textContent = 'Submeter pedido'
        })
    })
  }

  recarregar()
}
