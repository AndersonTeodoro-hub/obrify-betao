// Testes da Edge Function. Correm com `deno test` a partir de supabase/functions.
//
// A suite SQL não pode cobrir isto: testes_brechas.sql é SQL e a função é Deno.
// O que aqui se verifica é o que fica FORA da base — o hash, o caminho, as
// recusas antes de qualquer escrita, e a regra que mais importa: que o registo
// na base vai com o JWT de quem chamou e não com a chave de serviço.
//
// O fetch é substituído por um duplo que grava os pedidos. Não há rede.

import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1'
import {
  caminhoDe,
  sha256Hex,
  TECTO_BYTES,
  tratar,
  type Ambiente,
} from './carregar.ts'

const CHAVE_SERVICO = 'chave-de-servico-de-teste'
const CHAVE_ANON = 'chave-anon-de-teste'
const JWT = 'Bearer jwt-do-utilizador'
const OBRA = 'b1041e10-3c47-4584-9f89-d13136d122c0'
const ID = '30000000-0000-4000-8000-000000000001'

type Chamada = { url: string; opcoes: RequestInit }

function ambienteFalso(
  respostas: (c: Chamada) => Response,
): { amb: Ambiente; chamadas: Chamada[] } {
  const chamadas: Chamada[] = []
  const amb: Ambiente = {
    url: 'https://projecto.supabase.co',
    chaveServico: CHAVE_SERVICO,
    chaveAnon: CHAVE_ANON,
    buscar: (entrada, opcoes) => {
      const chamada = { url: String(entrada), opcoes: opcoes ?? {} }
      chamadas.push(chamada)
      return Promise.resolve(respostas(chamada))
    },
  }
  return { amb, chamadas }
}

function pedidoCom(campos: Record<string, string | File>, autorizacao = JWT): Request {
  const forma = new FormData()
  for (const [chave, valor] of Object.entries(campos)) forma.append(chave, valor)
  return new Request('https://f/carregar-guia', {
    method: 'POST',
    headers: { Authorization: autorizacao },
    body: forma,
  })
}

function foto(bytes = new Uint8Array([1, 2, 3]), mime = 'image/jpeg'): File {
  return new File([bytes], 'guia.jpg', { type: mime })
}

const OK = (c: Chamada): Response =>
  c.url.includes('/storage/')
    ? new Response('', { status: 200 })
    : new Response(JSON.stringify({ id: ID }), { status: 200 })

// ── o que é puro ────────────────────────────────────────────────────────────

Deno.test('sha256Hex bate com o vector conhecido de "abc"', async () => {
  assertEquals(
    await sha256Hex(new TextEncoder().encode('abc')),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  )
})

Deno.test('o caminho é derivado do conteúdo e é estável', () => {
  const sha = 'a'.repeat(64)
  assertEquals(caminhoDe(OBRA, sha, 'image/jpeg'), `${OBRA}/${sha}.jpg`)
  assertEquals(caminhoDe(OBRA, sha, 'image/png'), `${OBRA}/${sha}.png`)
  // os mesmos bytes na mesma obra dão sempre a mesma chave — é isto que torna
  // o carregamento idempotente sem perguntar nada ao Storage
  assertEquals(caminhoDe(OBRA, sha, 'image/jpeg'), caminhoDe(OBRA, sha, 'image/jpeg'))
})

// ── o que se recusa, e antes de escrever ────────────────────────────────────

Deno.test('sem Authorization não escreve nada', async () => {
  const { amb, chamadas } = ambienteFalso(OK)
  const r = await tratar(
    pedidoCom({ id: ID, obra_id: OBRA, origem: 'CAMARA', ficheiro: foto() }, 'nenhuma'),
    amb,
  )
  assertEquals(r.status, 401)
  assertEquals(chamadas.length, 0)
})

Deno.test('tipo não aceite é recusado antes de escrever', async () => {
  const { amb, chamadas } = ambienteFalso(OK)
  const r = await tratar(
    pedidoCom({
      id: ID,
      obra_id: OBRA,
      origem: 'CAMARA',
      ficheiro: new File([new Uint8Array([1])], 'g.pdf', { type: 'application/pdf' }),
    }),
    amb,
  )
  assertEquals(r.status, 415)
  assertEquals(chamadas.length, 0)
})

Deno.test('acima do tecto é recusado antes de escrever', async () => {
  const { amb, chamadas } = ambienteFalso(OK)
  const r = await tratar(
    pedidoCom({
      id: ID,
      obra_id: OBRA,
      origem: 'CAMARA',
      ficheiro: foto(new Uint8Array(TECTO_BYTES + 1)),
    }),
    amb,
  )
  assertEquals(r.status, 413)
  assertEquals(chamadas.length, 0)
})

Deno.test('galeria sem justificação é recusada antes de escrever', async () => {
  const { amb, chamadas } = ambienteFalso(OK)
  const r = await tratar(
    pedidoCom({ id: ID, obra_id: OBRA, origem: 'GALERIA', ficheiro: foto() }),
    amb,
  )
  assertEquals(r.status, 400)
  assertStringIncludes(JSON.stringify(await r.json()), 'justificação')
  assertEquals(chamadas.length, 0)
})

Deno.test('id que não é UUID é recusado', async () => {
  const { amb, chamadas } = ambienteFalso(OK)
  const r = await tratar(
    pedidoCom({ id: 'nao-e-uuid', obra_id: OBRA, origem: 'CAMARA', ficheiro: foto() }),
    amb,
  )
  assertEquals(r.status, 400)
  assertEquals(chamadas.length, 0)
})

// ── o caminho feliz, e as chaves ────────────────────────────────────────────

Deno.test('caminho feliz: guarda, regista e devolve o id', async () => {
  const { amb, chamadas } = ambienteFalso(OK)
  const r = await tratar(
    pedidoCom({ id: ID, obra_id: OBRA, origem: 'CAMARA', ficheiro: foto() }),
    amb,
  )
  assertEquals(r.status, 200)
  const corpo = (await r.json()) as { ficheiro_id: string; sha256: string; reaproveitado: boolean }
  assertEquals(corpo.ficheiro_id, ID)
  assertEquals(corpo.sha256, await sha256Hex(new Uint8Array([1, 2, 3])))
  assertEquals(corpo.reaproveitado, false)
  assertEquals(chamadas.length, 2)
})

Deno.test('o Storage leva a chave de serviço; a base leva o JWT de quem chamou', async () => {
  const { amb, chamadas } = ambienteFalso(OK)
  await tratar(pedidoCom({ id: ID, obra_id: OBRA, origem: 'CAMARA', ficheiro: foto() }), amb)

  const storage = chamadas.find((c) => c.url.includes('/storage/'))!
  const base = chamadas.find((c) => c.url.includes('/rest/v1/rpc/registar_ficheiro'))!

  const cabStorage = storage.opcoes.headers as Record<string, string>
  const cabBase = base.opcoes.headers as Record<string, string>

  assertEquals(cabStorage['Authorization'], `Bearer ${CHAVE_SERVICO}`)

  // A regra que mais importa: se isto passar a levar a chave de serviço, a
  // função torna-se um desvio ao exigir_actor e ao exigir_acesso_obra.
  assertEquals(cabBase['Authorization'], JWT)
  assert(!JSON.stringify(cabBase).includes(CHAVE_SERVICO), 'a chave de serviço fugiu para a base')
  assertEquals(cabBase['Content-Profile'], 'betonagens')
})

Deno.test('o sha vai para a base em hexadecimal com o prefixo do bytea', async () => {
  const { amb, chamadas } = ambienteFalso(OK)
  await tratar(pedidoCom({ id: ID, obra_id: OBRA, origem: 'CAMARA', ficheiro: foto() }), amb)

  const base = chamadas.find((c) => c.url.includes('registar_ficheiro'))!
  const corpo = JSON.parse(String(base.opcoes.body)) as Record<string, unknown>
  const sha = await sha256Hex(new Uint8Array([1, 2, 3]))

  assertEquals(corpo.p_sha256, `\\x${sha}`)
  assertEquals(corpo.p_caminho_storage, `guias/${OBRA}/${sha}.jpg`)
  assertEquals(corpo.p_tipo, 'GUIA')
  assertEquals(corpo.p_bytes, 3)
})

// ── idempotência e erros que não se engolem ─────────────────────────────────

Deno.test('objecto já no balde não é falha: o caminho vem do hash', async () => {
  const { amb } = ambienteFalso((c) =>
    c.url.includes('/storage/')
      ? new Response('Duplicate', { status: 409 })
      : new Response(JSON.stringify({ id: ID }), { status: 200 }),
  )
  const r = await tratar(
    pedidoCom({ id: ID, obra_id: OBRA, origem: 'CAMARA', ficheiro: foto() }),
    amb,
  )
  assertEquals(r.status, 200)
  assertEquals((await r.json()).reaproveitado, true)
})

Deno.test('o erro do PostgREST sobe com o código e o corpo originais', async () => {
  const inv3 = {
    code: 'PT409',
    message: 'Esta fotografia já foi carregada nesta organização (INV3).',
  }
  const { amb } = ambienteFalso((c) =>
    c.url.includes('/storage/')
      ? new Response('', { status: 200 })
      : new Response(JSON.stringify(inv3), { status: 409 }),
  )
  const r = await tratar(
    pedidoCom({ id: ID, obra_id: OBRA, origem: 'CAMARA', ficheiro: foto() }),
    amb,
  )
  assertEquals(r.status, 409)
  assertEquals(await r.json(), inv3)
})

Deno.test('uma falha do Storage não passa por registada', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    c.url.includes('/storage/')
      ? new Response('sem espaço', { status: 507 })
      : new Response(JSON.stringify({ id: ID }), { status: 200 }),
  )
  const r = await tratar(
    pedidoCom({ id: ID, obra_id: OBRA, origem: 'CAMARA', ficheiro: foto() }),
    amb,
  )
  assertEquals(r.status, 502)
  assertStringIncludes(JSON.stringify(await r.json()), 'sem espaço')
  // e sobretudo: não chegou a registar nada na base
  assertEquals(chamadas.filter((c) => c.url.includes('registar_ficheiro')).length, 0)
})
