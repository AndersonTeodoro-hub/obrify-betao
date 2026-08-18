// Testes da Edge Function de leitura. Correm com `deno test` a partir de
// supabase/functions.
//
// A suite SQL cobre o que acontece DEPOIS — a proveniência derivada, a R9, a
// R10, a recusa estrutural. O que aqui se verifica é o que fica fora da base: a
// ordem dos passos, o que se recusa antes de gastar uma chamada ao modelo, e a
// regra que mais importa — que a chave da Anthropic não sai daqui e que tudo o
// que toca no Supabase leva o JWT de quem chamou.
//
// O fetch é substituído por um duplo que grava os pedidos. Não há rede.

import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1'
import {
  base64De,
  ErroDeLeitura,
  ESQUEMA,
  lerEntrada,
  MODELO,
  TECTO_BYTES,
  tratar,
  type Ambiente,
} from './ler.ts'

const CHAVE_ANON = 'chave-anon-de-teste'
const CHAVE_ANTHROPIC = 'sk-ant-chave-de-teste'
const JWT = 'Bearer jwt-do-utilizador'
const FICHEIRO = '30000000-0000-4000-8000-000000000001'
const LEITURA = '40000000-0000-4000-8000-000000000001'
const OBRA = 'b1041e10-3c47-4584-9f89-d13136d122c0'
const CAMINHO = `guias/${OBRA}/abc.jpg`

type Chamada = { url: string; opcoes: RequestInit }

function ambienteFalso(
  respostas: (c: Chamada) => Response,
): { amb: Ambiente; chamadas: Chamada[] } {
  const chamadas: Chamada[] = []
  const amb: Ambiente = {
    url: 'https://projecto.supabase.co',
    chaveAnon: CHAVE_ANON,
    chaveAnthropic: CHAVE_ANTHROPIC,
    buscar: (entrada, opcoes) => {
      const chamada = { url: String(entrada), opcoes: opcoes ?? {} }
      chamadas.push(chamada)
      return Promise.resolve(respostas(chamada))
    },
  }
  return { amb, chamadas }
}

function pedido(corpo: unknown = { ficheiro_id: FICHEIRO }, autorizacao = JWT): Request {
  return new Request('https://f/ler-guia', {
    method: 'POST',
    headers: { Authorization: autorizacao, 'Content-Type': 'application/json' },
    body: JSON.stringify(corpo),
  })
}

const EXTRAIDO = {
  numero_guia: { valor: '118588', confianca: 'ALTA' },
  volume_m3: { valor: 8, confianca: 'ALTA' },
  classe_betao: { valor: 'C30/37', confianca: 'MEDIA' },
  data: { valor: '2026-08-18', confianca: 'ALTA' },
  hora: { valor: '09:14', confianca: 'MEDIA' },
  central_nome: { valor: 'BETAO LIZ - LAGOS', confianca: 'ALTA' },
  classe_exposicao: { valor: null, confianca: 'BAIXA' },
  classe_consistencia: { valor: 'S4', confianca: 'MEDIA' },
  dmax_mm: { valor: 22, confianca: 'MEDIA' },
  cliente_ou_obra: { valor: 'Obra 2602', confianca: 'ALTA' },
  matricula: { valor: '00-AA-00', confianca: 'MEDIA' },
  outros_campos: [{ rotulo: 'Aditivo', valor: 'Plastificante' }],
  nota_legibilidade: null,
}

/** Uma resposta por destino. É o caminho feliz; cada teste substitui o troço
 *  que quer ver falhar. */
function respostasOk(c: Chamada): Response {
  if (c.url.includes('/rest/v1/ficheiro')) {
    return new Response(
      JSON.stringify([
        { obra_id: OBRA, caminho_storage: CAMINHO, mime: 'image/jpeg', tipo: 'GUIA' },
      ]),
      { status: 200 },
    )
  }
  if (c.url.includes('/storage/')) {
    return new Response(new Uint8Array([1, 2, 3]), { status: 200 })
  }
  if (c.url.includes('api.anthropic.com')) {
    return new Response(
      JSON.stringify({
        content: [{ type: 'text', text: JSON.stringify(EXTRAIDO) }],
        stop_reason: 'end_turn',
        usage: { input_tokens: 5200, output_tokens: 380 },
      }),
      { status: 200 },
    )
  }
  return new Response(JSON.stringify({ id: LEITURA }), { status: 200 })
}

const modelo = (c: Chamada): boolean => c.url.includes('api.anthropic.com')
const registo = (c: Chamada): boolean => c.url.includes('registar_leitura_guia')

// ── o que é puro ────────────────────────────────────────────────────────────

Deno.test('base64De bate com o btoa nativo e aguenta megabytes', () => {
  assertEquals(base64De(new TextEncoder().encode('abc')), btoa('abc'))
  // 3 MB de uma vez: é aqui que um String.fromCharCode(...bytes) rebentava
  const grande = new Uint8Array(3 * 1024 * 1024).fill(65)
  assertEquals(base64De(grande).length, Math.ceil(grande.length / 3) * 4)
})

Deno.test('o esquema fecha a porta a campos inventados', () => {
  assertEquals(ESQUEMA.additionalProperties, false)
  // os quatro que a base compara para derivar a proveniência
  for (const campo of ['numero_guia', 'volume_m3', 'classe_betao', 'data']) {
    assert(ESQUEMA.required.includes(campo), `${campo} tem de ser obrigatório no esquema`)
  }
})

Deno.test('ficheiro_id que não é UUID é recusado antes de tudo', async () => {
  try {
    await lerEntrada(pedido({ ficheiro_id: 'nao-e-uuid' }))
    throw new Error('devia ter atirado')
  } catch (causa) {
    assert(causa instanceof ErroDeLeitura)
    assertEquals(causa.estado, 400)
  }
})

// ── o que se recusa, e antes de gastar uma leitura ──────────────────────────

Deno.test('sem Authorization não faz chamada nenhuma', async () => {
  const { amb, chamadas } = ambienteFalso(respostasOk)
  const r = await tratar(pedido({ ficheiro_id: FICHEIRO }, 'nenhuma'), amb)
  assertEquals(r.status, 401)
  assertEquals(chamadas.length, 0)
})

Deno.test('corpo que não é JSON é recusado antes de tudo', async () => {
  const { amb, chamadas } = ambienteFalso(respostasOk)
  const r = await tratar(
    new Request('https://f/ler-guia', {
      method: 'POST',
      headers: { Authorization: JWT },
      body: 'isto não é json',
    }),
    amb,
  )
  assertEquals(r.status, 400)
  assertEquals(chamadas.length, 0)
})

Deno.test('ficheiro que a RLS não mostra é 404 e não chega ao modelo', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    c.url.includes('/rest/v1/ficheiro')
      ? new Response('[]', { status: 200 })
      : respostasOk(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 404)
  assertEquals(chamadas.filter(modelo).length, 0)
})

Deno.test('ficheiro que não é GUIA não se lê', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    c.url.includes('/rest/v1/ficheiro')
      ? new Response(
        JSON.stringify([
          { obra_id: OBRA, caminho_storage: CAMINHO, mime: 'image/jpeg', tipo: 'PAB_IMPRESSO' },
        ]),
        { status: 200 },
      )
      : respostasOk(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 422)
  assertEquals(chamadas.filter(modelo).length, 0)
})

Deno.test('tipo de imagem não aceite é recusado antes do Storage', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    c.url.includes('/rest/v1/ficheiro')
      ? new Response(
        JSON.stringify([
          { obra_id: OBRA, caminho_storage: CAMINHO, mime: 'application/pdf', tipo: 'GUIA' },
        ]),
        { status: 200 },
      )
      : respostasOk(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 415)
  assertEquals(chamadas.filter((c) => c.url.includes('/storage/')).length, 0)
})

Deno.test('fotografia acima do tecto não vai para o modelo', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    c.url.includes('/storage/')
      ? new Response(new Uint8Array(TECTO_BYTES + 1), { status: 200 })
      : respostasOk(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 413)
  assertEquals(chamadas.filter(modelo).length, 0)
})

Deno.test('uma falha do Storage não passa por leitura', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    c.url.includes('/storage/')
      ? new Response('sem espaço', { status: 507 })
      : respostasOk(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 502)
  assertStringIncludes(JSON.stringify(await r.json()), 'sem espaço')
  assertEquals(chamadas.filter(modelo).length, 0)
})

// ── o caminho feliz, e as chaves ────────────────────────────────────────────

Deno.test('caminho feliz: ficheiro, foto, modelo, registo — por esta ordem', async () => {
  const { amb, chamadas } = ambienteFalso(respostasOk)
  const r = await tratar(pedido(), amb)

  assertEquals(r.status, 200)
  const corpo = (await r.json()) as {
    leitura_id: string
    modelo: string
    extraido: typeof EXTRAIDO
    tokens_entrada: number
    tokens_saida: number
  }
  assertEquals(corpo.leitura_id, LEITURA)
  assertEquals(corpo.modelo, MODELO)
  assertEquals(corpo.extraido, EXTRAIDO)
  assertEquals(corpo.tokens_entrada, 5200)
  assertEquals(corpo.tokens_saida, 380)

  assertEquals(chamadas.length, 4)
  assert(chamadas[0]!.url.includes('/rest/v1/ficheiro'))
  assert(chamadas[1]!.url.includes(`/storage/v1/object/${CAMINHO}`))
  assert(chamadas[2]!.url.includes('api.anthropic.com'))
  assert(chamadas[3]!.url.includes('registar_leitura_guia'))
})

Deno.test('a chave da Anthropic não sai para o Supabase, e o JWT não sai para a Anthropic', async () => {
  const { amb, chamadas } = ambienteFalso(respostasOk)
  await tratar(pedido(), amb)

  for (const c of chamadas.filter((c) => c.url.includes('supabase.co'))) {
    const cabecalhos = JSON.stringify(c.opcoes.headers ?? {})
    assertEquals((c.opcoes.headers as Record<string, string>)['Authorization'], JWT)
    assert(!cabecalhos.includes(CHAVE_ANTHROPIC), `a chave da Anthropic fugiu para ${c.url}`)
  }

  const aoModelo = chamadas.find(modelo)!
  const cabModelo = aoModelo.opcoes.headers as Record<string, string>
  assertEquals(cabModelo['x-api-key'], CHAVE_ANTHROPIC)
  assert(cabModelo['Authorization'] === undefined, 'o JWT da sessão fugiu para a Anthropic')

  // e o registo vai com o JWT, no schema certo: se algum dia levar chave de
  // serviço, a função passa a ser um desvio ao exigir_actor
  const aoRegisto = chamadas.find(registo)!
  const cabRegisto = aoRegisto.opcoes.headers as Record<string, string>
  assertEquals(cabRegisto['Authorization'], JWT)
  assertEquals(cabRegisto['Content-Profile'], 'betonagens')
})

Deno.test('ao modelo vai a imagem e o esquema — e não vai o PAB', async () => {
  const { amb, chamadas } = ambienteFalso(respostasOk)
  await tratar(pedido(), amb)

  const corpo = JSON.parse(String(chamadas.find(modelo)!.opcoes.body)) as {
    model: string
    output_config: { format: { type: string; schema: unknown } }
    messages: { content: { type: string; source?: { data?: string; media_type?: string } }[] }[]
  }

  assertEquals(corpo.model, MODELO)
  assertEquals(corpo.output_config.format.type, 'json_schema')
  assertEquals(corpo.output_config.format.schema, ESQUEMA)

  const imagem = corpo.messages[0]!.content.find((b) => b.type === 'image')!
  assertEquals(imagem.source?.media_type, 'image/jpeg')
  assertEquals(imagem.source?.data, base64De(new Uint8Array([1, 2, 3])))

  // O que NÃO se manda: nem classe pedida, nem volume previsto, nem número de
  // PAB. Um modelo a quem se diz o que devia encontrar confirma o pedido em vez
  // de ler o papel.
  const inteiro = String(chamadas.find(modelo)!.opcoes.body)
  for (const proibido of ['pab', 'volume_previsto', 'C30/37']) {
    assert(!inteiro.toLowerCase().includes(proibido.toLowerCase()), `${proibido} foi ao modelo`)
  }
})

// ── o que não se engole ─────────────────────────────────────────────────────

Deno.test('resposta truncada do modelo não passa por leitura', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    modelo(c)
      ? new Response(
        JSON.stringify({
          content: [{ type: 'text', text: '{"numero_guia":' }],
          stop_reason: 'max_tokens',
          usage: { input_tokens: 5200, output_tokens: 4000 },
        }),
        { status: 200 },
      )
      : respostasOk(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 502)
  assertStringIncludes(JSON.stringify(await r.json()), 'max_tokens')
  assertEquals(chamadas.filter(registo).length, 0)
})

Deno.test('texto que não é o JSON pedido não passa por leitura', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    modelo(c)
      ? new Response(
        JSON.stringify({
          content: [{ type: 'text', text: 'Não consigo ler esta guia.' }],
          stop_reason: 'end_turn',
          usage: { input_tokens: 5200, output_tokens: 12 },
        }),
        { status: 200 },
      )
      : respostasOk(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 502)
  assertEquals(chamadas.filter(registo).length, 0)
})

Deno.test('sem contagem de tokens não se regista nada', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    modelo(c)
      ? new Response(
        JSON.stringify({
          content: [{ type: 'text', text: JSON.stringify(EXTRAIDO) }],
          stop_reason: 'end_turn',
          usage: {},
        }),
        { status: 200 },
      )
      : respostasOk(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 502)
  assertEquals(chamadas.filter(registo).length, 0)
})

Deno.test('a API da Anthropic em baixo é 502 com o corpo original', async () => {
  const { amb, chamadas } = ambienteFalso((c) =>
    modelo(c)
      ? new Response('{"type":"error","error":{"type":"overloaded_error"}}', { status: 529 })
      : respostasOk(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 502)
  assertStringIncludes(JSON.stringify(await r.json()), 'overloaded_error')
  assertEquals(chamadas.filter(registo).length, 0)
})

Deno.test('o erro do PostgREST sobe com o código e o corpo originais', async () => {
  const recusa = {
    code: 'PT422',
    message: 'O ficheiro não é uma fotografia de guia.',
  }
  const { amb } = ambienteFalso((c) =>
    registo(c) ? new Response(JSON.stringify(recusa), { status: 422 }) : respostasOk(c),
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 422)
  assertEquals(await r.json(), recusa)
})
