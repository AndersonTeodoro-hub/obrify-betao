// Arranque da Edge Function. Só monta o ambiente e serve — a lógica está em
// carregar.ts, para poder ser exercitada sem rede.
//
// As três variáveis vêm do ambiente que o Supabase injecta nas Edge Functions.
// A de service_role NUNCA entra no repositório nem em variável com prefixo
// VITE_ — aqui é lida do ambiente e não sai daqui: é usada só para escrever no
// balde, e o registo na base vai com o JWT de quem chamou.
//
// Se faltar alguma, a função não arranca. Arrancar sem chave e falhar no
// primeiro pedido daria um erro a apontar para o sítio errado.

import { tratar, type Ambiente } from './carregar.ts'

function exigir(nome: string): string {
  const valor = Deno.env.get(nome)
  if (valor === undefined || valor === '') {
    throw new Error(
      `Falta a variável de ambiente ${nome}. A função não arranca sem ela — ` +
        'ver as definições da Edge Function no painel do Supabase.',
    )
  }
  return valor
}

const ambiente: Ambiente = {
  url: exigir('SUPABASE_URL'),
  chaveServico: exigir('SUPABASE_SERVICE_ROLE_KEY'),
  chaveAnon: exigir('SUPABASE_ANON_KEY'),
  buscar: fetch,
}

Deno.serve((pedido) => tratar(pedido, ambiente))
