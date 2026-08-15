// Ecrã de obras — e, no incremento 1, a prova de que a API funciona.
//
// Faz as duas coisas que precisam de estar provadas antes de existir qualquer
// outro ecrã:
//   ler   → select em betonagens.obra, que exige o schema alcançável, o SELECT
//           concedido a authenticated, e a RLS a filtrar por obra
//   escrever → rpc criar_obra, que exige EXECUTE na camada de serviço e prova
//           que a escrita passa pelas funções e não pela tabela
//
// Nenhuma tabela do domínio aceita INSERT de papel nenhum. Se um dia este
// ecrã conseguir escrever sem passar pelo rpc, é incidente.

import { criarObra, lerObras, mensagemDeErro, type Obra } from './dominio'
import { sair, type UtilizadorDeDominio } from './sessao'

/** Quem pode criar obras. O servidor recusa na mesma; isto só evita mostrar
 *  um formulário que ia dar erro. */
const PODE_CRIAR_OBRA = ['ADMIN', 'DIRETOR_QUALIDADE']

// A lista é construída com o DOM e não com innerHTML: os valores vêm da base de
// dados, foram escritos por pessoas, e interpolá-los em HTML seria injecção à
// espera de acontecer. textContent não interpreta nada.
function desenharLista(
  destino: HTMLElement,
  obras: Obra[],
  aoAbrirObra: (obra: Obra) => void,
): void {
  destino.replaceChildren()

  if (obras.length === 0) {
    const vazio = document.createElement('li')
    vazio.className = 'vazio'
    vazio.textContent = 'Nenhuma obra visível para esta conta.'
    destino.append(vazio)
    return
  }

  for (const obra of obras) {
    const codigo = document.createElement('span')
    codigo.className = 'mono codigo'
    codigo.textContent = obra.codigo

    const designacao = document.createElement('span')
    designacao.className = 'designacao'
    designacao.textContent = obra.designacao

    const botao = document.createElement('button')
    botao.type = 'button'
    botao.className = 'linha-botao'
    botao.append(codigo, designacao)

    if (!obra.ativa) {
      const inactiva = document.createElement('span')
      inactiva.className = 'inactiva'
      inactiva.textContent = 'inactiva'
      botao.append(inactiva)
    }

    const seta = document.createElement('span')
    seta.className = 'seta'
    seta.setAttribute('aria-hidden', 'true')
    seta.textContent = '›'
    botao.append(seta)

    botao.addEventListener('click', () => aoAbrirObra(obra))

    const item = document.createElement('li')
    item.append(botao)
    destino.append(item)
  }
}

export function montarEcraObras(
  destino: HTMLElement,
  utilizador: UtilizadorDeDominio,
  aoSair: () => void,
  aoAbrirObra: (obra: Obra) => void,
): void {
  const podeCriar = PODE_CRIAR_OBRA.includes(utilizador.perfil)

  destino.innerHTML = `
    <section class="ecra">
      <header class="topo">
        <div>
          <div class="nome"></div>
          <div class="mono perfil"></div>
        </div>
        <button id="botao-sair" class="btn btn-s" type="button">Sair</button>
      </header>

      <h2>Obras</h2>
      <ul id="lista-obras" class="lista"><li class="vazio">A carregar…</li></ul>

      ${
        podeCriar
          ? `<h2>Criar obra</h2>
      <form id="forma-obra">
        <label for="codigo">Código</label>
        <input id="codigo" class="mono" name="codigo" type="text" required
               autocomplete="off" placeholder="2602">

        <label for="designacao">Designação</label>
        <input id="designacao" name="designacao" type="text" required
               autocomplete="off" placeholder="Marina Sul — Bloco B">

        <fieldset class="grupo">
          <legend>Cabeçalho do impresso</legend>
          <p class="nota-grupo">
            É o que aparece no topo de cada pedido de betonagem desta obra.
          </p>

          <label for="dono-obra">Dono de obra</label>
          <input id="dono-obra" name="dono-obra" type="text" autocomplete="off"
                 placeholder="Palmares — Comp. Empreendimentos Turísticos, SA">

          <label for="empreiteiro">Adjudicatário</label>
          <input id="empreiteiro" name="empreiteiro" type="text" autocomplete="off"
                 placeholder="Ferreira Construção, S.A.">

          <label for="fiscalizacao">Fiscalização</label>
          <input id="fiscalizacao" name="fiscalizacao" type="text" autocomplete="off"
                 placeholder="DDN — Engenharia e Fiscalização">
        </fieldset>

        <button id="botao-criar" class="btn btn-p" type="submit">Criar obra</button>
      </form>`
          : ''
      }
      <p id="erro-obras" class="erro" role="alert" hidden></p>
    </section>
  `

  destino.querySelector<HTMLDivElement>('.topo .nome')!.textContent = utilizador.nome
  destino.querySelector<HTMLDivElement>('.topo .perfil')!.textContent = utilizador.perfil

  const lista = destino.querySelector<HTMLUListElement>('#lista-obras')!
  const erro = destino.querySelector<HTMLParagraphElement>('#erro-obras')!

  const mostrarErro = (causa: unknown): void => {
    erro.textContent = mensagemDeErro(causa)
    erro.hidden = false
  }

  const recarregar = (): void => {
    lerObras()
      .then((obras) => desenharLista(lista, obras, aoAbrirObra))
      .catch(mostrarErro)
  }

  destino.querySelector<HTMLButtonElement>('#botao-sair')!.addEventListener('click', () => {
    sair().then(aoSair).catch(mostrarErro)
  })

  const forma = destino.querySelector<HTMLFormElement>('#forma-obra')
  if (forma !== null) {
    const botaoCriar = destino.querySelector<HTMLButtonElement>('#botao-criar')!
    const codigo = destino.querySelector<HTMLInputElement>('#codigo')!
    const designacao = destino.querySelector<HTMLInputElement>('#designacao')!
    const donoObra = destino.querySelector<HTMLInputElement>('#dono-obra')!
    const empreiteiro = destino.querySelector<HTMLInputElement>('#empreiteiro')!
    const fiscalizacao = destino.querySelector<HTMLInputElement>('#fiscalizacao')!

    const textoOuNulo = (valor: string): string | null => {
      const limpo = valor.trim()
      return limpo === '' ? null : limpo
    }

    forma.addEventListener('submit', (evento) => {
      evento.preventDefault()
      erro.hidden = true
      botaoCriar.disabled = true
      botaoCriar.textContent = 'A criar…'

      criarObra(
        codigo.value.trim(),
        designacao.value.trim(),
        textoOuNulo(donoObra.value),
        textoOuNulo(empreiteiro.value),
        textoOuNulo(fiscalizacao.value),
      )
        .then(() => {
          forma.reset()
          recarregar()
        })
        .catch(mostrarErro)
        .finally(() => {
          botaoCriar.disabled = false
          botaoCriar.textContent = 'Criar obra'
        })
    })
  }

  recarregar()
}
