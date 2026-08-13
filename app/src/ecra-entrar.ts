// Ecrã de entrada. Email e palavra-passe, e mais nada.
//
// Sem registo público: as contas são nominais e criadas por quem administra a
// organização, através de betonagens.registar_utilizador. Não há auto-inscrição
// porque uma assinatura de FCQ não vale nada se não se souber quem assinou.

import { entrar } from './sessao'

export function montarEcraEntrar(destino: HTMLElement, aoEntrar: () => void): void {
  destino.innerHTML = `
    <section class="ecra">
      <h1>Obrify Betão</h1>
      <p class="sub">Controlo de betonagens · DDN</p>
      <form id="forma-entrar" novalidate>
        <label for="email">Email</label>
        <input id="email" name="email" type="email" autocomplete="username"
               inputmode="email" required>

        <label for="palavra-passe">Palavra-passe</label>
        <input id="palavra-passe" name="palavra-passe" type="password"
               autocomplete="current-password" required>

        <button id="botao-entrar" class="btn btn-p" type="submit">Entrar</button>
      </form>
      <p id="erro-entrar" class="erro" role="alert" hidden></p>
    </section>
  `

  const forma = destino.querySelector<HTMLFormElement>('#forma-entrar')!
  const botao = destino.querySelector<HTMLButtonElement>('#botao-entrar')!
  const email = destino.querySelector<HTMLInputElement>('#email')!
  const palavraPasse = destino.querySelector<HTMLInputElement>('#palavra-passe')!
  const erro = destino.querySelector<HTMLParagraphElement>('#erro-entrar')!

  forma.addEventListener('submit', (evento) => {
    evento.preventDefault()
    erro.hidden = true
    botao.disabled = true
    botao.textContent = 'A entrar…'

    entrar(email.value.trim(), palavraPasse.value)
      .then(aoEntrar)
      .catch((causa: unknown) => {
        // O erro aparece tal como veio. Nada de "credenciais inválidas" genérico
        // por cima de um problema de rede ou de configuração.
        erro.textContent = causa instanceof Error ? causa.message : String(causa)
        erro.hidden = false
        botao.disabled = false
        botao.textContent = 'Entrar'
      })
  })
}
