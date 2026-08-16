// Ecrã de gestão — contas e código de registo. Só para ADMIN e direção de
// qualidade.
//
// ── DUAS PORTAS DE ENTRADA, DE PROPÓSITO DIFERENTES ─────────────────────────
// A fiscalização da DDN entra pelo código: são dezenas de pessoas da casa, e
// obrigar o ADMIN a criar cada conta à mão não escala.
//
// O empreiteiro é criado aqui, uma conta por empresa, com palavra-passe
// inicial. É deliberado: o empreiteiro submete pedidos que comprometem a obra,
// e quem entra tem de ser decidido, não convidado. Não existe código para
// EMPREITEIRO — a constraint da 0020 impede-o mesmo que alguém tente.
//
// O que se mostra aqui é cortesia; quem decide é o servidor. Todas as funções
// exigem ADMIN outra vez, e a Edge Function confirma-o antes de tocar no Auth.

import {
  criarContaDeUtilizador,
  gerarCodigoRegisto,
  lerCodigoAtivo,
  lerObras,
  lerUtilizadores,
  mensagemDeErro,
  revogarCodigoRegisto,
  type CodigoRegisto,
  type Obra,
  type UtilizadorDaOrganizacao,
} from './dominio'
import type { UtilizadorDeDominio } from './sessao'

/** Quem vê este ecrã. O servidor recusa na mesma a quem não for ADMIN — isto
 *  só evita mostrar um formulário que ia dar PT403. */
export const PODE_GERIR = ['ADMIN', 'DIRETOR_QUALIDADE']

/** Só o ADMIN gera códigos e cria contas. A direção de qualidade vê. */
const PODE_ADMINISTRAR = ['ADMIN']

function dataCurta(iso: string): string {
  const d = new Date(iso)
  return Number.isFinite(d.getTime()) ? d.toLocaleDateString('pt-PT') : iso
}

export function montarEcraGestao(
  destino: HTMLElement,
  utilizador: UtilizadorDeDominio,
  aoVoltar: () => void,
): void {
  const podeAdministrar = PODE_ADMINISTRAR.includes(utilizador.perfil)

  destino.innerHTML = `
    <section class="ecra">
      <button id="gestao-voltar" class="voltar" type="button">‹ Obras</button>
      <h1>Gestão</h1>
      <p class="sub">Contas e acessos · ${utilizador.perfil}</p>

      <p id="erro-gestao" class="erro" role="alert" hidden></p>

      <article class="doc">
        <div class="doc-barra"><span>Código de registo da fiscalização</span></div>
        <div class="campos" id="bloco-codigo"></div>
        ${
          podeAdministrar
            ? `<form id="forma-codigo-novo" class="forma-curta dobra-clara">
          <label for="validade">Validade (dias)</label>
          <input id="validade" class="mono" name="validade" type="number" min="1" max="365"
                 value="30" required>
          <p class="nota-grupo">
            Gerar um código novo revoga o anterior. Quem já se registou não é
            afectado — o código só serve para entrar, não para ficar.
          </p>
          <button id="botao-gerar" class="btn btn-p" type="submit">Gerar código novo</button>
          <button id="botao-revogar" class="btn btn-s" type="button" hidden>Revogar sem substituir</button>
        </form>`
            : `<p class="nota-grupo" style="padding:0.85rem">
          Só o ADMIN gera e revoga códigos.
        </p>`
        }
      </article>

      ${
        podeAdministrar
          ? `<article class="doc" style="margin-top:1.5rem">
        <div class="doc-barra"><span>Criar conta de empreiteiro</span></div>
        <form id="forma-conta">
          <div class="campos">
            <div class="linha-campos linha-2">
              <div class="campo">
                <label for="conta-nome">Nome da empresa</label>
                <input id="conta-nome" name="conta-nome" type="text" required minlength="3"
                       autocomplete="off" placeholder="Ferreira Construção, S.A.">
              </div>
              <div class="campo">
                <label for="conta-email">Email</label>
                <input id="conta-email" name="conta-email" type="email" required
                       autocomplete="off" placeholder="obra@ferreira.pt">
              </div>
            </div>
            <div class="linha-campos linha-2">
              <div class="campo">
                <label for="conta-passe">Palavra-passe inicial</label>
                <input id="conta-passe" name="conta-passe" type="text" required minlength="10"
                       autocomplete="off">
                <p class="nota-grupo">
                  Pelo menos 10 caracteres. Vai ser comunicada à empresa — e devia
                  ser mudada por ela na primeira entrada.
                </p>
              </div>
              <div class="campo">
                <label for="conta-obra">Obra a atribuir <span class="op">opcional</span></label>
                <select id="conta-obra" name="conta-obra"></select>
              </div>
            </div>
          </div>
          <div class="doc-accao">
            <button id="botao-criar-conta" class="btn btn-p" type="submit">Criar conta</button>
          </div>
        </form>
      </article>`
          : ''
      }

      <article class="doc" style="margin-top:1.5rem">
        <div class="doc-barra"><span>Utilizadores da organização</span></div>
        <div id="lista-utilizadores"></div>
      </article>
    </section>
  `

  const erro = destino.querySelector<HTMLParagraphElement>('#erro-gestao')!
  const blocoCodigo = destino.querySelector<HTMLElement>('#bloco-codigo')!
  const listaUtilizadores = destino.querySelector<HTMLElement>('#lista-utilizadores')!
  const botaoRevogar = destino.querySelector<HTMLButtonElement>('#botao-revogar')
  const selectObra = destino.querySelector<HTMLSelectElement>('#conta-obra')

  let codigoActual: CodigoRegisto | null = null

  const mostrarErro = (causa: unknown): void => {
    erro.textContent = mensagemDeErro(causa)
    erro.hidden = false
  }

  destino.querySelector<HTMLButtonElement>('#gestao-voltar')!.addEventListener('click', aoVoltar)

  const campo = (etiqueta: string, valor: string, mono = false): HTMLElement => {
    const rotulo = document.createElement('span')
    rotulo.className = 'etiqueta'
    rotulo.textContent = etiqueta
    const conteudo = document.createElement('span')
    conteudo.className = mono ? 'valor mono valor-grande' : 'valor'
    conteudo.textContent = valor
    const linha = document.createElement('div')
    linha.className = 'campo'
    linha.append(rotulo, conteudo)
    return linha
  }

  const desenharCodigo = (codigo: CodigoRegisto | null): void => {
    codigoActual = codigo
    blocoCodigo.replaceChildren()
    if (botaoRevogar !== null) botaoRevogar.hidden = codigo === null

    if (codigo === null) {
      const vazio = document.createElement('p')
      vazio.className = 'vazio'
      vazio.textContent =
        'Não há código activo. Sem código, nenhum fiscal se pode registar sozinho.'
      blocoCodigo.append(vazio)
      return
    }

    const expirado = new Date(codigo.expira_em).getTime() < Date.now()
    blocoCodigo.append(
      campo('Código', codigo.codigo, true),
      campo('Perfil que concede', codigo.perfil),
      campo(
        'Válido até',
        `${dataCurta(codigo.expira_em)}${expirado ? ' — já expirou' : ''}`,
      ),
      campo('Criado em', dataCurta(codigo.criado_em)),
    )
  }

  const desenharUtilizadores = (utilizadores: UtilizadorDaOrganizacao[]): void => {
    listaUtilizadores.replaceChildren()
    if (utilizadores.length === 0) {
      const vazio = document.createElement('p')
      vazio.className = 'vazio'
      vazio.textContent = 'Nenhum utilizador visível.'
      listaUtilizadores.append(vazio)
      return
    }

    for (const u of utilizadores) {
      const nome = document.createElement('span')
      nome.className = 'painel-nome'
      nome.textContent = u.nome

      const sub = document.createElement('span')
      sub.className = 'sub-doc'
      sub.textContent = u.email + (u.ativo ? '' : ' · desactivado')

      const corpo = document.createElement('span')
      corpo.className = 'corpo-doc'
      corpo.append(nome, sub)

      const perfil = document.createElement('span')
      perfil.className = 'estado'
      perfil.textContent = u.perfil.replace('_', ' ')

      const linha = document.createElement('div')
      linha.className = 'painel-linha'
      linha.append(corpo, perfil)
      listaUtilizadores.append(linha)
    }
  }

  const recarregar = (): void => {
    Promise.all([lerCodigoAtivo(), lerUtilizadores(), lerObras()])
      .then(([codigo, utilizadores, obras]) => {
        desenharCodigo(codigo)
        desenharUtilizadores(utilizadores)
        if (selectObra !== null) preencherObras(selectObra, obras)
      })
      .catch(mostrarErro)
  }

  const formaCodigo = destino.querySelector<HTMLFormElement>('#forma-codigo-novo')
  if (formaCodigo !== null) {
    const botao = destino.querySelector<HTMLButtonElement>('#botao-gerar')!
    const validade = destino.querySelector<HTMLInputElement>('#validade')!

    formaCodigo.addEventListener('submit', (evento) => {
      evento.preventDefault()
      erro.hidden = true
      botao.disabled = true
      botao.textContent = 'A gerar…'
      gerarCodigoRegisto(Number(validade.value))
        .then(desenharCodigo)
        .catch(mostrarErro)
        .finally(() => {
          botao.disabled = false
          botao.textContent = 'Gerar código novo'
        })
    })

    botaoRevogar!.addEventListener('click', () => {
      if (codigoActual === null) return
      erro.hidden = true
      revogarCodigoRegisto(codigoActual.id)
        .then(() => desenharCodigo(null))
        .catch(mostrarErro)
    })
  }

  const formaConta = destino.querySelector<HTMLFormElement>('#forma-conta')
  if (formaConta !== null) {
    const botao = destino.querySelector<HTMLButtonElement>('#botao-criar-conta')!
    const nome = destino.querySelector<HTMLInputElement>('#conta-nome')!
    const email = destino.querySelector<HTMLInputElement>('#conta-email')!
    const passe = destino.querySelector<HTMLInputElement>('#conta-passe')!

    formaConta.addEventListener('submit', (evento) => {
      evento.preventDefault()
      erro.hidden = true
      botao.disabled = true
      botao.textContent = 'A criar…'

      criarContaDeUtilizador({
        email: email.value.trim(),
        palavraPasse: passe.value,
        nome: nome.value.trim(),
        perfil: 'EMPREITEIRO',
        obraId: selectObra === null || selectObra.value === '' ? null : selectObra.value,
      })
        .then(() => {
          formaConta.reset()
          recarregar()
        })
        .catch(mostrarErro)
        .finally(() => {
          botao.disabled = false
          botao.textContent = 'Criar conta'
        })
    })
  }

  recarregar()
}

function preencherObras(select: HTMLSelectElement, obras: Obra[]): void {
  select.replaceChildren()
  const nenhuma = document.createElement('option')
  nenhuma.value = ''
  nenhuma.textContent = '— sem obra por agora —'
  select.append(nenhuma)

  for (const obra of obras) {
    const opcao = document.createElement('option')
    opcao.value = obra.id
    opcao.textContent = `${obra.codigo} — ${obra.designacao}`
    select.append(opcao)
  }
}

