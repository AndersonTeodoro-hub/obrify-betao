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

import { betonagens } from './supabase'
import { sair, type UtilizadorDeDominio } from './sessao'

type Obra = {
  id: string
  codigo: string
  designacao: string
  ativa: boolean
}

async function lerObras(): Promise<Obra[]> {
  const { data, error } = await betonagens()
    .from('obra')
    .select('id, codigo, designacao, ativa')
    .order('codigo')
  if (error) throw error
  return (data ?? []) as Obra[]
}

async function criarObra(codigo: string, designacao: string): Promise<void> {
  const { error } = await betonagens().rpc('criar_obra', {
    p_codigo: codigo,
    p_designacao: designacao,
  })
  if (error) throw error
}

function desenharLista(destino: HTMLElement, obras: Obra[]): void {
  if (obras.length === 0) {
    destino.innerHTML = `<p class="vazio">Nenhuma obra visível para esta conta.</p>`
    return
  }
  destino.innerHTML = obras
    .map(
      (obra) => `
        <li class="obra">
          <span class="mono codigo">${obra.codigo}</span>
          <span class="designacao">${obra.designacao}</span>
          ${obra.ativa ? '' : '<span class="inactiva">inactiva</span>'}
        </li>`,
    )
    .join('')
}

export function montarEcraObras(
  destino: HTMLElement,
  utilizador: UtilizadorDeDominio,
  aoSair: () => void,
): void {
  destino.innerHTML = `
    <section class="ecra">
      <header class="topo">
        <div>
          <div class="nome">${utilizador.nome}</div>
          <div class="mono perfil">${utilizador.perfil}</div>
        </div>
        <button id="botao-sair" class="btn btn-s" type="button">Sair</button>
      </header>

      <h2>Obras</h2>
      <ul id="lista-obras" class="lista"><li class="vazio">A carregar…</li></ul>

      <h2>Criar obra</h2>
      <form id="forma-obra" novalidate>
        <label for="codigo">Código</label>
        <input id="codigo" class="mono" name="codigo" type="text" required
               autocomplete="off" placeholder="2602">

        <label for="designacao">Designação</label>
        <input id="designacao" name="designacao" type="text" required
               autocomplete="off" placeholder="Marina Sul — Bloco B">

        <button id="botao-criar" class="btn btn-p" type="submit">Criar obra</button>
      </form>
      <p id="erro-obras" class="erro" role="alert" hidden></p>
    </section>
  `

  const lista = destino.querySelector<HTMLUListElement>('#lista-obras')!
  const forma = destino.querySelector<HTMLFormElement>('#forma-obra')!
  const botaoCriar = destino.querySelector<HTMLButtonElement>('#botao-criar')!
  const codigo = destino.querySelector<HTMLInputElement>('#codigo')!
  const designacao = destino.querySelector<HTMLInputElement>('#designacao')!
  const erro = destino.querySelector<HTMLParagraphElement>('#erro-obras')!

  const mostrarErro = (causa: unknown): void => {
    erro.textContent = causa instanceof Error ? causa.message : String(causa)
    erro.hidden = false
  }

  const recarregar = (): void => {
    lerObras()
      .then((obras) => desenharLista(lista, obras))
      .catch(mostrarErro)
  }

  destino.querySelector<HTMLButtonElement>('#botao-sair')!.addEventListener('click', () => {
    sair().then(aoSair).catch(mostrarErro)
  })

  forma.addEventListener('submit', (evento) => {
    evento.preventDefault()
    erro.hidden = true
    botaoCriar.disabled = true
    botaoCriar.textContent = 'A criar…'

    criarObra(codigo.value.trim(), designacao.value.trim())
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

  recarregar()
}
