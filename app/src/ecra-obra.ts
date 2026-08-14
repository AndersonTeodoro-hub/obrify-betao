// Ecrã de uma obra: frentes e pedidos de autorização de betonagem.
//
// A frente é obrigatória para submeter um PAB — pab.frente_id é NOT NULL — e é
// ela que torna aplicável a regra R6, o bloqueio de duas betonagens em curso na
// mesma frente. Sem frente não há pedido, e por isso vem primeiro no ecrã.
//
// O que a submissão faz do outro lado é mais do que inserir uma linha: atribui
// o número sequencial da obra e cria a ficha I.CR.033 em rascunho, 1:1 com o
// PAB. O checklist dessa ficha é a fase C.

import {
  criarFrente,
  lerFrentes,
  lerPabs,
  mensagemDeErro,
  submeterPab,
  type Frente,
  type Obra,
  type Pab,
} from './dominio'
import type { UtilizadorDeDominio } from './sessao'

/** Quem pode criar frentes, segundo betonagens.criar_frente. */
const PODE_CRIAR_FRENTE = ['ADMIN', 'DIRETOR_QUALIDADE', 'FISCALIZACAO']

/** Quem pode submeter um PAB, segundo betonagens.submeter_pab. O ADMIN não:
 *  administra contas e obras, não pede betonagens. */
const PODE_SUBMETER_PAB = ['EMPREITEIRO', 'FISCALIZACAO', 'DIRETOR_QUALIDADE']

/** Quem pode preencher a ficha, segundo betonagens.marcar_item_fcq. É a
 *  fiscalização que inspecciona — o empreiteiro pede, não se auto-verifica. */
const PODE_MARCAR_FICHA = ['FISCALIZACAO', 'DIRETOR_QUALIDADE']

function dataISO(dias: number): string {
  const d = new Date()
  d.setDate(d.getDate() + dias)
  return d.toISOString().slice(0, 10)
}

function textoOuNulo(valor: string): string | null {
  const limpo = valor.trim()
  return limpo === '' ? null : limpo
}

// Number('') é 0. Foi um zero silencioso destes que fez o servidor recusar a
// primeira submissão com «o volume previsto tem de ser maior do que zero» — o
// campo estava vazio e o código transformou isso num valor errado em vez de num
// erro. Aqui os três casos são distintos e quem chama tem de os tratar.
type Numero =
  | { estado: 'vazio' }
  | { estado: 'invalido' }
  | { estado: 'ok'; valor: number }

/**
 * Aceita vírgula ou ponto como separador decimal. Em Portugal escreve-se 40,00,
 * e um <input type="number"> devolve string vazia quando não consegue
 * interpretar o que lá está — o que transformava «40,00» em zero. Por isso os
 * campos são type="text" com inputmode="decimal": o teclado do telemóvel
 * continua a ser o numérico, e a interpretação é nossa e explícita.
 *
 * Uma segunda vírgula ou ponto torna o número ambíguo — 1,000,50 pode ser mil e
 * meio ou um vírgula zero — e nesse caso recusa-se em vez de adivinhar.
 */
function lerNumero(texto: string): Numero {
  const limpo = texto.trim().replace(',', '.')
  if (limpo === '') return { estado: 'vazio' }
  const valor = Number(limpo)
  return Number.isFinite(valor) ? { estado: 'ok', valor } : { estado: 'invalido' }
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

function desenharPabs(
  destino: HTMLElement,
  pabs: Pab[],
  frentes: Frente[],
  podeAbrirFicha: boolean,
  aoAbrirFicha: (pab: Pab) => void,
): void {
  destino.replaceChildren()

  if (pabs.length === 0) {
    const vazio = document.createElement('li')
    vazio.className = 'vazio'
    vazio.textContent = 'Ainda não há pedidos de betonagem nesta obra.'
    destino.append(vazio)
    return
  }

  const designacaoDaFrente = new Map(frentes.map((f) => [f.id, f.designacao]))

  for (const pab of pabs) {
    const numero = document.createElement('span')
    numero.className = 'mono numero-pab'
    numero.textContent = String(pab.numero)

    const elemento = document.createElement('div')
    elemento.className = 'elemento'
    elemento.textContent = pab.elemento

    // classe · exposição · consistência · dmáx — só o que existir
    const especificacao = [
      pab.classe_betao,
      pab.classe_exposicao,
      pab.classe_consistencia,
      pab.dmax_agregado_mm === null ? null : `Dmáx ${pab.dmax_agregado_mm} mm`,
    ]
      .filter((parte): parte is string => parte !== null && parte !== '')
      .join(' · ')

    const detalhe = document.createElement('div')
    detalhe.className = 'detalhe'
    detalhe.textContent =
      `${designacaoDaFrente.get(pab.frente_id) ?? 'frente desconhecida'} · ` +
      `${especificacao} · ${pab.volume_previsto_m3} m³ · prevista ${pab.data_prevista}`

    const texto = document.createElement('div')
    texto.className = 'texto-pab'
    texto.append(elemento, detalhe)

    const estado = document.createElement('span')
    estado.className = `estado estado-${pab.estado}`
    estado.textContent = pab.estado.replace('_', ' ')

    const item = document.createElement('li')

    // Quem não pode marcar a ficha vê a linha, mas ela não abre — é a mesma
    // regra que betonagens.marcar_item_fcq aplica, dita antes de o utilizador
    // bater nela.
    if (podeAbrirFicha) {
      const seta = document.createElement('span')
      seta.className = 'seta'
      seta.setAttribute('aria-hidden', 'true')
      seta.textContent = '›'

      const botao = document.createElement('button')
      botao.type = 'button'
      botao.className = 'linha-botao pab'
      botao.append(numero, texto, estado, seta)
      botao.addEventListener('click', () => aoAbrirFicha(pab))
      item.append(botao)
    } else {
      item.className = 'pab'
      item.append(numero, texto, estado)
    }

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
  aoAbrirFicha: (pab: Pab) => void,
): void {
  const podeCriarFrente = PODE_CRIAR_FRENTE.includes(utilizador.perfil)
  const podeSubmeter = PODE_SUBMETER_PAB.includes(utilizador.perfil)
  const podeAbrirFicha = PODE_MARCAR_FICHA.includes(utilizador.perfil)

  destino.innerHTML = `
    <section class="ecra">
      <button id="botao-voltar" class="voltar" type="button">‹ Obras</button>

      <header class="cabecalho-obra">
        <div class="mono codigo-obra"></div>
        <h1 class="designacao-obra"></h1>
      </header>

      <h2>Frentes</h2>
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

      <h2>Pedidos de betonagem</h2>
      <ul id="lista-pabs" class="lista"><li class="vazio">A carregar…</li></ul>

      ${
        podeSubmeter
          ? `<h2>Submeter pedido</h2>
      <p id="sem-frentes" class="nota-perfil" hidden>
        Não há frentes nesta obra. Um pedido tem sempre uma frente — cria uma primeiro.
      </p>
      <form id="forma-pab" hidden>
        <label for="frente-pab">Frente</label>
        <select id="frente-pab" name="frente-pab" required></select>

        <label for="elemento">Peças a betonar</label>
        <input id="elemento" name="elemento" type="text" required autocomplete="off"
               placeholder="Sapatas S12 a S15" minlength="3">

        <label for="volume">Volume previsto (m³)</label>
        <input id="volume" class="mono" name="volume" type="text" required
               inputmode="decimal" autocomplete="off" placeholder="40,00">

        <label for="classe-betao">Classe de betão</label>
        <input id="classe-betao" class="mono" name="classe-betao" type="text" required
               autocomplete="off" placeholder="C30/37" minlength="3">

        <label for="data-pedido">Data do pedido</label>
        <input id="data-pedido" class="mono" name="data-pedido" type="date" required>

        <label for="data-prevista">Data prevista da betonagem</label>
        <input id="data-prevista" class="mono" name="data-prevista" type="date" required>

        <fieldset class="opcionais">
          <legend>Opcional</legend>

          <label for="classe-exposicao">Classe de exposição</label>
          <input id="classe-exposicao" class="mono" name="classe-exposicao" type="text"
                 autocomplete="off" placeholder="XC4(P)">

          <label for="classe-consistencia">Classe de consistência</label>
          <input id="classe-consistencia" class="mono" name="classe-consistencia" type="text"
                 autocomplete="off" placeholder="S4">

          <label for="dmax">Dmáx do agregado (mm)</label>
          <input id="dmax" class="mono" name="dmax" type="text" inputmode="numeric"
                 autocomplete="off" placeholder="22">
        </fieldset>

        <button id="botao-submeter" class="btn btn-p" type="submit">Submeter pedido</button>
      </form>`
          : `<p class="nota-perfil">O perfil ${utilizador.perfil} não submete pedidos de betonagem.</p>`
      }

      <p id="erro-obra" class="erro" role="alert" hidden></p>
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

  const recarregar = (): void => {
    Promise.all([lerFrentes(obra.id), lerPabs(obra.id)])
      .then(([frentes, pabs]) => {
        desenharFrentes(listaFrentes, frentes)
        desenharPabs(listaPabs, pabs, frentes, podeAbrirFicha, aoAbrirFicha)

        if (formaPab !== null && semFrentes !== null && selectFrente !== null) {
          preencherFrentes(selectFrente, frentes)
          formaPab.hidden = frentes.length === 0
          semFrentes.hidden = frentes.length > 0
        }
      })
      .catch(mostrarErro)
  }

  destino.querySelector<HTMLButtonElement>('#botao-voltar')!.addEventListener('click', aoVoltar)

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
    const elemento = destino.querySelector<HTMLInputElement>('#elemento')!
    const volume = destino.querySelector<HTMLInputElement>('#volume')!
    const classeBetao = destino.querySelector<HTMLInputElement>('#classe-betao')!
    const dataPedido = destino.querySelector<HTMLInputElement>('#data-pedido')!
    const dataPrevista = destino.querySelector<HTMLInputElement>('#data-prevista')!
    const classeExposicao = destino.querySelector<HTMLInputElement>('#classe-exposicao')!
    const classeConsistencia = destino.querySelector<HTMLInputElement>('#classe-consistencia')!
    const dmax = destino.querySelector<HTMLInputElement>('#dmax')!

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
      })
        .then(() => {
          elemento.value = ''
          volume.value = ''
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
