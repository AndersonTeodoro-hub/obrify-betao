// Arranque. Decide que ecrã mostrar e é o último sítio onde um erro pode
// aparecer sem ninguém o ter tratado — por isso nenhum erro morre aqui em
// silêncio: ou é desenhado no ecrã, ou não foi apanhado de todo.

import { utilizadorDeDominio } from './sessao'
import { montarEcraEntrar } from './ecra-entrar'
import { montarEcraObras } from './ecra-obras'

const destino = document.querySelector<HTMLElement>('#app')
if (destino === null) throw new Error('Falta o elemento #app no index.html.')

function mostrarFalha(causa: unknown): void {
  const mensagem = causa instanceof Error ? causa.message : String(causa)
  destino!.innerHTML = `
    <section class="ecra">
      <h1>Não foi possível arrancar</h1>
      <p class="erro" role="alert"></p>
      <button id="botao-recarregar" class="btn btn-s" type="button">Tentar de novo</button>
    </section>
  `
  destino!.querySelector<HTMLParagraphElement>('.erro')!.textContent = mensagem
  destino!
    .querySelector<HTMLButtonElement>('#botao-recarregar')!
    .addEventListener('click', () => {
      window.location.reload()
    })
}

function desenhar(): void {
  utilizadorDeDominio()
    .then((utilizador) => {
      if (utilizador === null) {
        montarEcraEntrar(destino!, desenhar)
        return
      }
      montarEcraObras(destino!, utilizador, desenhar)
    })
    .catch(mostrarFalha)
}

desenhar()
