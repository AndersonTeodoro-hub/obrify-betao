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
import { mensagemDeErro, type Obra } from './dominio'

const destino = document.querySelector<HTMLElement>('#app')
if (destino === null) throw new Error('Falta o elemento #app no index.html.')
const app = destino

// A vista da ficha entra na fase C, quando existir ecrã que a desenhe.
type Vista = { nome: 'obras' } | { nome: 'obra'; obra: Obra }

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
        case 'obra':
          montarEcraObra(app, vista.obra, utilizador, () => irPara({ nome: 'obras' }))
          return
      }
    })
    .catch(mostrarFalha)
}

desenhar()
