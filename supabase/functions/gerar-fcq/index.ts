// Arranque da Edge Function. Só monta o ambiente e serve — a lógica está em
// gerar.ts, e o desenho lá dentro corre sem rede nenhuma, que é o que permite
// compará-lo com o oráculo (docs/comparar_motor.py).
//
// A chave de serviço é lida aqui e serve para UMA coisa: escrever no balde fcq,
// que não tem política de escrita para ninguém. Ler o impresso, ler a ficha,
// registar o ficheiro e emitir a versão vão todos com o JWT de quem chamou —
// se fossem com a chave de serviço, a função passava a ser um desvio ao
// exigir_actor, ao exigir_perfil e à RLS.
//
// Se faltar alguma variável, a função não arranca.

import { tratar, type Ambiente } from './gerar.ts'

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
  chaveServico: exigir('SUPABASE_SERVICE_ROLE_KEY'),
  buscar: fetch,
}

Deno.serve((pedido) => tratar(pedido, ambiente))
