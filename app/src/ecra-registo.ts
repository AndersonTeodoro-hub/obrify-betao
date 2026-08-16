// Registo de fiscalização com código da DDN.
//
// Dois passos, e o ecrã sabe em qual está:
//   1. criar a conta — email e palavra-passe pessoal, no Supabase Auth
//   2. apresentar o código — que liga a conta a um utilizador da organização
//
// Quem chega aqui com sessão já iniciada e sem utilizador de domínio salta o
// passo 1: é exactamente o caso de quem criou a conta, foi confirmar o email, e
// voltou.
//
// ── O QUE O CÓDIGO É, E NÃO É ───────────────────────────────────────────────
// Não é uma credencial de acesso. Uma conta do Auth sem utilizador de domínio
// não vê nem faz nada — as funções de serviço recusam com PT403 e a RLS não
// devolve linha nenhuma. O código decide QUEM entra, não O QUE pode fazer.
//
// Por isso o passo 1 pode ser aberto: criar uma conta sem código não dá acesso
// a coisa nenhuma.

import { mensagemDeErro } from './dominio'
import { criarConta, registarComCodigo, sair } from './sessao'

export function montarEcraRegisto(
  destino: HTMLElement,
  contaJaExiste: boolean,
  aoRegistar: () => void,
  aoVoltar: () => void,
): void {
  destino.innerHTML = `
    <section class="ecra">
      <button id="registo-voltar" class="voltar" type="button">‹ Entrar</button>

      <h1>Registo de fiscalização</h1>
      <p class="sub">
        Para quem faz fiscalização na DDN. O empreiteiro não se regista aqui —
        a conta da empresa é criada pela DDN.
      </p>

      ${
        contaJaExiste
          ? `<p class="nota-grupo">
        A conta já está criada e a sessão iniciada. Falta o código que a liga à
        organização.
      </p>`
          : `<form id="forma-conta">
        <h2>1 · A sua conta</h2>
        <label for="reg-email">Email</label>
        <input id="reg-email" name="reg-email" type="email" required
               autocomplete="username" inputmode="email">

        <label for="reg-passe">Palavra-passe</label>
        <input id="reg-passe" name="reg-passe" type="password" required
               autocomplete="new-password" minlength="10">
        <p class="nota-grupo">Pelo menos 10 caracteres. É sua e ninguém a vê.</p>

        <button id="botao-conta" class="btn btn-p" type="submit">Criar conta</button>
      </form>

      <p id="aviso-confirmar" class="nota-grupo" hidden></p>`
      }

      <form id="forma-codigo" ${contaJaExiste ? '' : 'hidden'}>
        <h2>${contaJaExiste ? 'Código da DDN' : '2 · Código da DDN'}</h2>

        <label for="reg-nome">Nome completo</label>
        <input id="reg-nome" name="reg-nome" type="text" required minlength="3"
               autocomplete="name" placeholder="Joaquim Salvador">
        <p class="nota-grupo">É o que fica nas assinaturas das fichas de controlo.</p>

        <label for="reg-codigo">Código de registo</label>
        <input id="reg-codigo" class="mono" name="reg-codigo" type="text" required
               autocomplete="off" placeholder="A1B2-C3D4-E5F6">

        <button id="botao-codigo" class="btn btn-p" type="submit">Concluir registo</button>
      </form>

      <p id="erro-registo" class="erro" role="alert" hidden></p>
    </section>
  `

  const erro = destino.querySelector<HTMLParagraphElement>('#erro-registo')!
  const formaCodigo = destino.querySelector<HTMLFormElement>('#forma-codigo')!
  const botaoCodigo = destino.querySelector<HTMLButtonElement>('#botao-codigo')!
  const nome = destino.querySelector<HTMLInputElement>('#reg-nome')!
  const codigo = destino.querySelector<HTMLInputElement>('#reg-codigo')!

  const mostrarErro = (causa: unknown): void => {
    erro.textContent = mensagemDeErro(causa)
    erro.hidden = false
  }

  destino.querySelector<HTMLButtonElement>('#registo-voltar')!.addEventListener('click', () => {
    // Quem desiste a meio fica com uma conta do Auth iniciada e sem domínio, e
    // isso prendia-o neste ecrã para sempre. Termina-se a sessão à saída.
    if (contaJaExiste) sair().then(aoVoltar).catch(mostrarErro)
    else aoVoltar()
  })

  const formaConta = destino.querySelector<HTMLFormElement>('#forma-conta')
  if (formaConta !== null) {
    const botaoConta = destino.querySelector<HTMLButtonElement>('#botao-conta')!
    const email = destino.querySelector<HTMLInputElement>('#reg-email')!
    const passe = destino.querySelector<HTMLInputElement>('#reg-passe')!
    const aviso = destino.querySelector<HTMLParagraphElement>('#aviso-confirmar')!

    formaConta.addEventListener('submit', (evento) => {
      evento.preventDefault()
      erro.hidden = true
      botaoConta.disabled = true
      botaoConta.textContent = 'A criar…'

      criarConta(email.value.trim(), passe.value)
        .then((comSessao) => {
          formaConta.hidden = true
          if (comSessao) {
            // Confirmação de email desligada: segue-se logo para o código.
            formaCodigo.hidden = false
            nome.focus()
            return
          }
          // Confirmação ligada: a sessão só existe depois de confirmar, e sem
          // sessão o código não pode ser apresentado. Dizê-lo é melhor do que
          // mostrar um formulário que ia falhar com PT403.
          aviso.hidden = false
          aviso.textContent =
            `Conta criada para ${email.value.trim()}. Confirme o email na sua caixa de ` +
            'correio e volte a esta página para apresentar o código.'
        })
        .catch(mostrarErro)
        .finally(() => {
          botaoConta.disabled = false
          botaoConta.textContent = 'Criar conta'
        })
    })
  }

  formaCodigo.addEventListener('submit', (evento) => {
    evento.preventDefault()
    erro.hidden = true
    botaoCodigo.disabled = true
    botaoCodigo.textContent = 'A registar…'

    registarComCodigo(codigo.value.trim().toUpperCase(), nome.value.trim())
      .then(aoRegistar)
      .catch(mostrarErro)
      .finally(() => {
        botaoCodigo.disabled = false
        botaoCodigo.textContent = 'Concluir registo'
      })
  })
}
