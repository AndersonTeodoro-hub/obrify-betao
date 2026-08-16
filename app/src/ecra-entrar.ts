// Ecrã de entrada. Email e palavra-passe, e o caminho para o registo.
//
// As contas continuam a ser nominais: uma assinatura de FCQ não vale nada se
// não se souber quem assinou. O que mudou é COMO nascem — a fiscalização da DDN
// regista-se com um código da casa, e o empreiteiro continua a ser criado pelo
// ADMIN, uma conta por empresa. Não há auto-inscrição de empreiteiros.

import { mensagemDeErro } from './dominio'
import { entrar } from './sessao'

export function montarEcraEntrar(
  destino: HTMLElement,
  aoEntrar: () => void,
  aoRegistar: () => void,
): void {
  destino.innerHTML = `
    <section class="ecra">
      <h1>Obrify Betão</h1>
      <p class="sub">Controlo de betonagens · DDN</p>
      <form id="forma-entrar">
        <label for="email">Email</label>
        <input id="email" name="email" type="email" autocomplete="username"
               inputmode="email" required>

        <label for="palavra-passe">Palavra-passe</label>
        <input id="palavra-passe" name="palavra-passe" type="password"
               autocomplete="current-password" required>

        <button id="botao-entrar" class="btn btn-p" type="submit">Entrar</button>
      </form>

      <p class="separador-entrar">
        <button id="botao-registar" class="ligacao" type="button">
          Registar como fiscalização (com código da DDN)
        </button>
      </p>

      <p id="erro-entrar" class="erro" role="alert" hidden></p>
    </section>
  `

  destino.querySelector<HTMLButtonElement>('#botao-registar')!.addEventListener('click', aoRegistar)

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
        erro.textContent = mensagemDeErro(causa)
        erro.hidden = false
        botao.disabled = false
        botao.textContent = 'Entrar'
      })
  })
}
