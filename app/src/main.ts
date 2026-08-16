// Arranque e estado de vista. Decide que ecrã mostrar e é o último sítio onde
// um erro pode aparecer sem ninguém o ter tratado — por isso nenhum erro morre
// aqui em silêncio: ou é desenhado no ecrã, ou não foi apanhado de todo.
//
// Não é um router: não há URL, não há histórico do browser, não há dependência.
// Uma variável, uma função que desenha, e a vista muda quando alguém a muda.

import { estadoDaSessao } from './sessao'
import { montarEcraEntrar } from './ecra-entrar'
import { montarEcraObras } from './ecra-obras'
import { montarEcraObra } from './ecra-obra'
import { montarEcraGestao } from './ecra-gestao'
import { montarEcraRegisto } from './ecra-registo'
import { mensagemDeErro, type Obra } from './dominio'

const destino = document.querySelector<HTMLElement>('#app')
if (destino === null) throw new Error('Falta o elemento #app no index.html.')
const app = destino

// A ficha deixou de ser vista própria. O PAB escolhido é estado INTERNO do
// ecrã da obra, e não do estado de navegação, por duas razões:
//   · em desktop as duas zonas coexistem no mesmo ecrã — uma vista separada não
//     pode estar ao lado de outra;
//   · se a escolha subisse até aqui, cada clique num pedido redesenharia o ecrã
//     inteiro e levaria consigo o que estivesse escrito no formulário e a
//     posição da lista.
// O que se perde é poder abrir um PAB directamente. Não havia como: não há URL.
type Vista =
  | { nome: 'obras' }
  | { nome: 'obra'; obra: Obra }
  | { nome: 'registo' }
  | { nome: 'gestao' }

let vista: Vista = { nome: 'obras' }

function irPara(proxima: Vista): void {
  vista = proxima
  desenhar()
}

function mostrarFalha(causa: unknown): void {
  const mensagem = mensagemDeErro(causa)
  app.innerHTML = `
    <section class="ecra">
      <h1>Não foi possível arrancar</h1>
      <p class="erro" role="alert"></p>
      <button id="botao-recarregar" class="btn btn-s" type="button">Tentar de novo</button>
    </section>
  `
  app.querySelector<HTMLParagraphElement>('.erro')!.textContent = mensagem
  app.querySelector<HTMLButtonElement>('#botao-recarregar')!.addEventListener('click', () => {
    window.location.reload()
  })
}

function desenhar(): void {
  estadoDaSessao()
    .then((sessao) => {
      // Uma sessão autenticada sem utilizador de domínio não é erro: é quem
      // criou a conta e ainda não apresentou o código. Vai para o registo.
      if (sessao.estado === 'por-registar') {
        montarEcraRegisto(app, true, desenhar, desenhar)
        return
      }

      if (sessao.estado === 'anonima') {
        if (vista.nome === 'registo') {
          montarEcraRegisto(app, false, desenhar, () => irPara({ nome: 'obras' }))
          return
        }
        vista = { nome: 'obras' }
        montarEcraEntrar(app, desenhar, () => irPara({ nome: 'registo' }))
        return
      }

      const utilizador = sessao.utilizador

      switch (vista.nome) {
        case 'registo':
          // Registo concluído: já há utilizador, o ecrã de registo não tem mais
          // nada para fazer.
          irPara({ nome: 'obras' })
          return
        case 'obras':
          montarEcraObras(
            app,
            utilizador,
            () => irPara({ nome: 'obras' }),
            (obra) => irPara({ nome: 'obra', obra }),
            () => irPara({ nome: 'gestao' }),
          )
          return
        case 'gestao':
          montarEcraGestao(app, utilizador, () => irPara({ nome: 'obras' }))
          return
        // Os blocos existem para prender a vista já estreitada numa constante:
        // dentro de um fecho, o `vista` volta a ser a união inteira.
        case 'obra': {
          const { obra } = vista
          montarEcraObra(app, obra, utilizador, () => irPara({ nome: 'obras' }))
          return
        }
      }
    })
    .catch(mostrarFalha)
}

desenhar()
