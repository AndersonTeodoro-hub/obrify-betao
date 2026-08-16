// Testes da criação de contas. Sem rede: o fetch é substituído por um duplo.
//
// O que aqui interessa provar é a ordem e as chaves — que não se cria conta
// nenhuma sem confirmar quem pede, e que a base é sempre chamada com o JWT de
// quem pediu, nunca com a chave de serviço.

import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1'
import { lerPedido, tratar, type Ambiente } from './criar.ts'

const SERVICO = 'chave-de-servico'
const ANON = 'chave-anon'
const JWT = 'Bearer jwt-do-admin'
const AUTH_ID = '90000000-0000-4000-8000-000000000001'
const UTIL_ID = '80000000-0000-4000-8000-000000000002'
const OBRA = 'b1041e10-3c47-4584-9f89-d13136d122c0'

type Chamada = { url: string; opcoes: RequestInit }

function ambienteFalso(resp: (c: Chamada) => Response) {
  const chamadas: Chamada[] = []
  const amb: Ambiente = {
    url: 'https://projecto.supabase.co',
    chaveServico: SERVICO,
    chaveAnon: ANON,
    buscar: (entrada, opcoes) => {
      const c = { url: String(entrada), opcoes: opcoes ?? {} }
      chamadas.push(c)
      return Promise.resolve(resp(c))
    },
  }
  return { amb, chamadas }
}

const CORPO = {
  email: 'empresa@exemplo.pt',
  palavra_passe: 'palavra-passe-inicial',
  nome: 'Ferreira Construção',
  perfil: 'EMPREITEIRO',
}

function pedido(corpo: unknown = CORPO, autorizacao = JWT): Request {
  return new Request('https://f/criar-conta', {
    method: 'POST',
    headers: { Authorization: autorizacao, 'Content-Type': 'application/json' },
    body: JSON.stringify(corpo),
  })
}

const TUDO_BEM = (c: Chamada): Response => {
  if (c.url.includes('/rest/v1/utilizador?')) {
    return new Response(JSON.stringify([{ perfil: 'ADMIN', ativo: true }]), { status: 200 })
  }
  if (c.url.includes('/auth/v1/admin/users')) {
    return new Response(JSON.stringify({ id: AUTH_ID }), { status: 200 })
  }
  if (c.url.includes('registar_utilizador')) {
    return new Response(JSON.stringify({ id: UTIL_ID }), { status: 200 })
  }
  return new Response('null', { status: 200 })
}

Deno.test('palavra-passe curta é recusada antes de tudo', () => {
  let apanhou = false
  try {
    lerPedido({ ...CORPO, palavra_passe: 'curta' })
  } catch (e) {
    apanhou = true
    assertStringIncludes(String(e), '10 caracteres')
  }
  assert(apanhou, 'devia ter recusado')
})

Deno.test('perfil ADMIN não se cria por aqui', () => {
  let apanhou = false
  try {
    lerPedido({ ...CORPO, perfil: 'ADMIN' })
  } catch {
    apanhou = true
  }
  assert(apanhou, 'ADMIN não devia ser aceite')
})

Deno.test('sem Authorization não chama nada', async () => {
  const { amb, chamadas } = ambienteFalso(TUDO_BEM)
  const r = await tratar(pedido(CORPO, 'nenhuma'), amb)
  assertEquals(r.status, 401)
  assertEquals(chamadas.length, 0)
})

Deno.test('quem não é ADMIN não chega a criar conta no Auth', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    c.url.includes('/rest/v1/utilizador?')
      ? new Response(JSON.stringify([{ perfil: 'FISCALIZACAO', ativo: true }]), { status: 200 })
      : TUDO_BEM(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 403)
  assertEquals(chamadas.filter((c) => c.url.includes('/auth/v1/admin/users')).length, 0)
})

Deno.test('caminho feliz: confirma, cria no Auth, regista na base', async () => {
  const { amb, chamadas } = ambienteFalso(TUDO_BEM)
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 200)
  assertEquals(await r.json(), { auth_user_id: AUTH_ID, utilizador_id: UTIL_ID })

  const ordem = chamadas.map((c) =>
    c.url.includes('/rest/v1/utilizador?') ? 'confirmar'
    : c.url.includes('/auth/v1/admin/users') ? 'auth'
    : 'registar')
  assertEquals(ordem, ['confirmar', 'auth', 'registar'])
})

Deno.test('o Auth leva a chave de serviço; a base leva o JWT do ADMIN', async () => {
  const { amb, chamadas } = ambienteFalso(TUDO_BEM)
  await tratar(pedido(), amb)

  const auth = chamadas.find((c) => c.url.includes('/auth/v1/admin/users'))!
  const base = chamadas.find((c) => c.url.includes('registar_utilizador'))!
  const cabAuth = auth.opcoes.headers as Record<string, string>
  const cabBase = base.opcoes.headers as Record<string, string>

  assertEquals(cabAuth['Authorization'], `Bearer ${SERVICO}`)
  // Se isto passar a levar a chave de serviço, o exigir_perfil do
  // registar_utilizador deixa de ser aplicado a quem pediu.
  assertEquals(cabBase['Authorization'], JWT)
  assert(!JSON.stringify(cabBase).includes(SERVICO), 'a chave de serviço fugiu para a base')
})

Deno.test('com obra, atribui-a com o id devolvido pelo registo', async () => {
  const { amb, chamadas } = ambienteFalso(TUDO_BEM)
  const r = await tratar(pedido({ ...CORPO, obra_id: OBRA }), amb)
  assertEquals(r.status, 200)

  const atribuir = chamadas.find((c) => c.url.includes('atribuir_obra'))!
  assertEquals(JSON.parse(String(atribuir.opcoes.body)), {
    p_utilizador_id: UTIL_ID,
    p_obra_id: OBRA,
  })
})

Deno.test('conta criada no Auth e registo falhado é dito, não escondido', async () => {
  const { amb } = ambienteFalso((c) =>
    c.url.includes('registar_utilizador')
      ? new Response(JSON.stringify({ code: 'PT403', message: 'não é ADMIN' }), { status: 403 })
      : TUDO_BEM(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 403)
  const texto = JSON.stringify(await r.json())
  assertStringIncludes(texto, AUTH_ID)
  assertStringIncludes(texto, 'não tem acesso a nada')
})
