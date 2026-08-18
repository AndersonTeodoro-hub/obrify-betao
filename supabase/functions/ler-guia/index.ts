// Arranque da Edge Function. Só monta o ambiente e serve — a lógica está em
// ler.ts, para poder ser exercitada sem rede.
//
// ANTHROPIC_API_KEY não é injectada pelo Supabase: é um secret da função, posto
// com `supabase secrets set`. Nunca entra no repositório, nunca leva prefixo
// VITE_ — tudo o que tem esse prefixo é embutido no pacote entregue ao browser,
// e uma chave publicada é uma chave de outra pessoa.
//
// Não há SUPABASE_SERVICE_ROLE_KEY aqui, e a ausência é a decisão: esta função
// faz tudo com o JWT de quem chamou, e é a RLS que decide o que ela alcança.
//
// Se faltar alguma variável, a função não arranca. Arrancar sem chave e falhar
// no primeiro pedido daria um erro a apontar para o sítio errado.

import { tratar, type Ambiente } from './ler.ts'

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
  chaveAnon: exigir('SUPABASE_ANON_KEY'),
  chaveAnthropic: exigir('ANTHROPIC_API_KEY'),
  buscar: fetch,
}

Deno.serve((pedido) => tratar(pedido, ambiente))
