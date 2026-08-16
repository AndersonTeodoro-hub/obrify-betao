// Arranque da Edge Function que cria contas. Como no carregar-guia: só monta o
// ambiente e serve. A chave de serviço é lida do ambiente e não sai daqui.

import { tratar, type Ambiente } from './criar.ts'

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
