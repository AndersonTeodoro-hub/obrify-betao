// Arranque e estado de vista. Decide que ecrã mostrar e é o último sítio onde
// um erro pode aparecer sem ninguém o ter tratado — por isso nenhum erro morre
// aqui em silêncio: ou é desenhado no ecrã, ou não foi apanhado de todo.
//
// Não é um router: não há URL, não há histórico do browser, não há dependência.
// Uma variável, uma função que desenha, e a vista muda quando alguém a muda.

import { utilizadorDeDominio } from './sessao'
import { montarEcraEntrar } from './ecra-entrar'
import { montarEcraObras } from './ecra-obras'
import { montarEcraObra } from './ecra-obra'
import { montarEcraFicha } from './ecra-ficha'
import { mensagemDeErro, type Obra, type Pab } from './dominio'

const destino = document.querySelector<HTMLElement>('#app')
if (destino === null) throw new Error('Falta o elemento #app no index.html.')
const app = destino

type Vista =
  | { nome: 'obras' }
  | { nome: 'obra'; obra: Obra }
  | { nome: 'ficha'; obra: Obra; pab: Pab }

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
  utilizadorDeDominio()
    .then((utilizador) => {
      if (utilizador === null) {
        vista = { nome: 'obras' }
        montarEcraEntrar(app, desenhar)
        return
      }

      switch (vista.nome) {
        case 'obras':
          montarEcraObras(
            app,
            utilizador,
            () => irPara({ nome: 'obras' }),
            (obra) => irPara({ nome: 'obra', obra }),
          )
          return
        // Os blocos existem para prender a vista já estreitada numa constante:
        // dentro de um fecho, o `vista` volta a ser a união inteira.
        case 'obra': {
          const { obra } = vista
          montarEcraObra(
            app,
            obra,
            utilizador,
            () => irPara({ nome: 'obras' }),
            (pab) => irPara({ nome: 'ficha', obra, pab }),
          )
          return
        }
        case 'ficha': {
          const { obra, pab } = vista
          montarEcraFicha(app, obra, pab, utilizador, () => irPara({ nome: 'obra', obra }))
          return
        }
      }
    })
    .catch(mostrarFalha)
}

desenhar()
