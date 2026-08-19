// Testes do motor da FCQ. Correm com `deno test` a partir de supabase/functions.
//
// O que aqui se prova é o que se pode provar sem rede: as funções puras que
// decidem o que vai para o papel, e a ordem e as chaves da viagem. Que o
// desenho coincide com o oráculo prova-se noutro sítio e de outra maneira —
// docs/comparar_motor.py, contra o impresso oficial, e o resultado está no
// relatório da entrega. Um teste que rasterizasse PDF aqui dentro seria um
// oráculo pior do que o que já existe.
//
// O impresso destes testes é um PDF em branco criado na hora: assim a suite não
// depende de ficheiros no disco nem de permissões de leitura.

import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1'
import { PDFDocument } from 'npm:pdf-lib@1.17.1'
import {
  BALDE,
  dataLocal,
  desenhar,
  hexDoBytea,
  idDeterministico,
  montarDados,
  paraWinAnsi,
  quebrar,
  sha256Hex,
  tratar,
  type Ambiente,
  type Dados,
  type Ficha,
  type Mapa,
} from './gerar.ts'

const CHAVE_ANON = 'chave-anon-de-teste'
const CHAVE_SERVICO = 'chave-de-servico-de-teste'
const JWT = 'Bearer jwt-do-utilizador'
const FCQ = '70000000-0000-4000-8000-000000000001'
const OBRA = 'b1041e10-3c47-4584-9f89-d13136d122c0'
const PAB = '80000000-0000-4000-8000-000000000001'
const MODELO = '90000000-0000-4000-8000-000000000001'
const FICHEIRO = 'a0000000-0000-4000-8000-000000000001'

const MAPA: Mapa = {
  documento: { largura_pt: 595.276, altura_pt: 841.89, revisao: 9 },
  cabecalho: {
    n_obra: { x: 108, y_baseline: 68.8 },
    designacao: { x: 162, y_baseline: 68.8 },
    numero: { x: 423, y_baseline: 56 },
    n_anexos: { x: 447, y_baseline: 69.1 },
    local_inspecao: { x: 236, y_baseline: 81.3 },
  },
  blocos_assinatura: {
    x_por_coluna: { insp: 305.5, reinsp1: 334.6, reinsp2: 361.7, reinsp3: 388.8 },
    blocos: [
      { y_elaborado: 116.2, y_data: 124.1, seccao: 'implantacao' },
      { y_elaborado: 158.4, y_data: 166.3, seccao: 'cofragem' },
    ],
  },
  observacoes: { x: 90, y_topo: 762 },
  linhas: [
    {
      id: 'L01',
      seccao: 'implantacao',
      check: {
        insp: { x: 320.2, cy: 136.32 },
        reinsp1: { x: 347.2, cy: 136.32 },
        reinsp2: { x: 374.2, cy: 136.32 },
        reinsp3: { x: 401.2, cy: 136.32 },
      },
      anotacao: { x: 416.4, y_baseline: 140.4 },
    },
    {
      id: 'L02',
      seccao: 'cofragem',
      check: {
        insp: { x: 320.2, cy: 178.44 },
        reinsp1: { x: 347.2, cy: 178.44 },
        reinsp2: { x: 374.2, cy: 178.44 },
        reinsp3: { x: 401.2, cy: 178.44 },
      },
      anotacao: { x: 416.4, y_baseline: 182.4 },
    },
  ],
}

async function impressoDeTeste(): Promise<Uint8Array<ArrayBuffer>> {
  const pdf = await PDFDocument.create()
  pdf.addPage([595.276, 841.89])
  return new Uint8Array(await pdf.save())
}

const FICHA_BASE = (): Ficha => ({
  fcq: { id: FCQ, obra_id: OBRA, pab_id: PAB, modelo_impresso_id: MODELO, numero: '001' },
  pab: { numero: 1, elemento: 'Sapatas S12 a S15', frente_id: 'f', observacoes: 'Tudo conforme.' },
  obra: { codigo: '2602', designacao: 'Marina Sul - Bloco B' },
  frente: { designacao: 'Bloco B / Piso 0' },
  modelo: { codigo: 'I.CR.033', revisao: 9, caminho_storage: 'templates/icr033_rev9.pdf', mapa_campos: MAPA },
  itens: [
    { linha_codigo: 'L01', coluna: 'insp', valor: 'C', anotacao: null },
    { linha_codigo: 'L02', coluna: 'insp', valor: 'NC', anotacao: 'Escoramento por reforçar' },
    { linha_codigo: 'L02', coluna: 'reinsp1', valor: 'C', anotacao: 'Reforçado em 14/07' },
  ],
  seccoes: [
    { seccao: 'implantacao', coluna: 'insp', nome_impresso: 'J. Salvador', assinado_em: '2026-07-10T09:30:00Z', em_vigor: true },
  ],
  anexos: 3,
  proximaVersao: 1,
})

// ── o que é puro ────────────────────────────────────────────────────────────

Deno.test('quebrar corta como o textwrap do oráculo', () => {
  const obs =
    'Betonagem coberta pelo PAB n.º 47. Guias de remessa 118432, 118433 e 118441 em anexo (3 anexos). Volume total 42,50 m3 para 40,00 m3 previstos (+6,3%). Classe C30/37 conforme aprovado.'
  const linhas = quebrar(obs, 105)
  assertEquals(linhas.length, 2)
  assert(linhas.every((l) => l.length <= 105), 'nenhuma linha passa a largura')
  assertEquals(linhas.join(' '), obs)
})

// Os três casos foram corridos no textwrap.wrap do Python, que é o que o
// oráculo usa, e é essa a saída que aqui se exige.
Deno.test('quebrar parte uma palavra maior do que a largura, como o textwrap', () => {
  assertEquals(quebrar('aaaaaa bb', 4), ['aaaa', 'aa', 'bb'])
  assertEquals(quebrar('abc de fghi', 4), ['abc', 'de', 'fghi'])
  assertEquals(quebrar('um dois tres', 4), ['um', 'dois', 'tres'])
})

Deno.test('paraWinAnsi troca o que a fonte não codifica e diz o que trocou', () => {
  const { texto, trocas } = paraWinAnsi('Volume ≤ 40 m³ — ver anexo')
  assertEquals(texto, 'Volume <= 40 m³ - ver anexo')
  assertEquals(trocas, ['≤ -> <=', '— -> -'])
})

Deno.test('paraWinAnsi deixa passar os acentos, que estão em WinAnsi', () => {
  const { texto, trocas } = paraWinAnsi('Núcleo A — betão à vista, ç')
  assertEquals(trocas, ['— -> -'])
  assertStringIncludes(texto, 'Núcleo A - betão à vista, ç')
})

Deno.test('idDeterministico é estável e depende da semente', async () => {
  const a = await idDeterministico('fcq:1:abc')
  assertEquals(a, await idDeterministico('fcq:1:abc'))
  assert(a !== (await idDeterministico('fcq:2:abc')))
  assert(/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(a), a)
})

Deno.test('hexDoBytea tira o prefixo do PostgREST', () => {
  assertEquals(hexDoBytea('\\x5D9E61'), '5d9e61')
  assertEquals(hexDoBytea('5d9e61'), '5d9e61')
})

Deno.test('dataLocal escreve como o impresso pede', () => {
  assertEquals(dataLocal('2026-07-10T09:30:00Z'), '10/07/2026')
  // 00:30 UTC de 1 de Julho é ainda 01:30 em Lisboa — o dia não recua
  assertEquals(dataLocal('2026-07-01T00:30:00Z'), '01/07/2026')
  assertEquals(dataLocal('nao-e-data'), '')
})

Deno.test('montarDados põe no papel o que a ficha diz', () => {
  const dados = montarDados(FICHA_BASE())

  assertEquals(dados.n_obra, '2602')
  assertEquals(dados.numero, '033 / 001')
  assertEquals(dados.n_anexos, '3')
  assertEquals(dados.local_inspecao, 'Bloco B / Piso 0 / Sapatas S12 a S15')
  assertEquals(dados.checks, { L01: { insp: 'C' }, L02: { insp: 'NC', reinsp1: 'C' } })
  // uma linha de anotação por critério: fica a da coluna mais à direita
  assertEquals(dados.anotacoes, { L02: 'Reforçado em 14/07' })
  assertEquals(dados.assinaturas, {
    implantacao: { insp: { por: 'J. Salvador', data: '10/07/2026' } },
  })
  assertEquals(dados.observacoes, 'Tudo conforme.')
  assertEquals(dados.avisos, [])
})

Deno.test('montarDados regista a substituição de caracteres em vez de a esconder', () => {
  const ficha = FICHA_BASE()
  ficha.pab.observacoes = 'Volume ≤ 40 m3'
  const dados = montarDados(ficha)
  assertEquals(dados.observacoes, 'Volume <= 40 m3')
  assertEquals(dados.avisos, ['carácter substituído: ≤ -> <='])
})

Deno.test('desenhar devolve um PDF maior do que o impresso, e não rebenta com o visto', async () => {
  const impresso = await impressoDeTeste()
  const dados = montarDados(FICHA_BASE())
  const saida = await desenhar(impresso, MAPA, dados)

  assertEquals(new TextDecoder().decode(saida.slice(0, 5)), '%PDF-')
  assert(saida.byteLength > impresso.byteLength, 'o desenho tem de acrescentar conteúdo')
})

Deno.test('desenhar recusa uma linha que o impresso não tem', async () => {
  const impresso = await impressoDeTeste()
  const dados: Dados = {
    ...montarDados(FICHA_BASE()),
    checks: { L99: { insp: 'C' } },
  }
  let mensagem = ''
  try {
    await desenhar(impresso, MAPA, dados)
  } catch (causa) {
    mensagem = String(causa)
  }
  assertStringIncludes(mensagem, 'L99')
})

// ── a viagem ────────────────────────────────────────────────────────────────

type Chamada = { url: string; opcoes: RequestInit }

async function ambienteFalso(
  ajuste: (c: Chamada) => Response | null = () => null,
): Promise<{ amb: Ambiente; chamadas: Chamada[]; impresso: Uint8Array<ArrayBuffer> }> {
  const impresso = await impressoDeTeste()
  const sha = await sha256Hex(impresso)
  const chamadas: Chamada[] = []

  const respostas = (c: Chamada): Response => {
    const feito = ajuste(c)
    if (feito !== null) return feito
    const lista = (linhas: unknown[]): Response =>
      new Response(JSON.stringify(linhas), { status: 200 })

    if (c.url.includes('/rest/v1/fcq?')) {
      return lista([{ id: FCQ, obra_id: OBRA, pab_id: PAB, modelo_impresso_id: MODELO, numero: '001', estado: 'RASCUNHO' }])
    }
    if (c.url.includes('/rest/v1/pab?')) {
      return lista([{ numero: 1, elemento: 'Sapatas S12 a S15', frente_id: 'f', observacoes: 'Tudo conforme.', estado: 'BETONADO' }])
    }
    if (c.url.includes('/rest/v1/obra?')) return lista([{ codigo: '2602', designacao: 'Marina Sul' }])
    if (c.url.includes('/rest/v1/frente?')) return lista([{ designacao: 'Bloco B / Piso 0' }])
    if (c.url.includes('/rest/v1/modelo_impresso?')) {
      return lista([{
        codigo: 'I.CR.033', revisao: 9,
        caminho_storage: 'templates/icr033_rev9.pdf',
        sha256: `\\x${sha}`, mapa_campos: MAPA,
      }])
    }
    if (c.url.includes('/rest/v1/fcq_item?')) {
      return lista([{ linha_codigo: 'L01', coluna: 'insp', valor: 'C', anotacao: null }])
    }
    if (c.url.includes('/rest/v1/fcq_seccao_estado?')) {
      return lista([{ seccao: 'implantacao', coluna: 'insp', nome_impresso: 'J. Salvador', assinado_em: '2026-07-10T09:30:00Z', em_vigor: true }])
    }
    if (c.url.includes('/rest/v1/guia_remessa?')) return lista([{ id: 'g1' }, { id: 'g2' }])
    if (c.url.includes('/rest/v1/fcq_versao?')) return lista([])
    if (c.url.includes('/storage/v1/object/templates/')) {
      return new Response(impresso, { status: 200 })
    }
    if (c.url.includes(`/storage/v1/object/${BALDE}/`)) return new Response('', { status: 200 })
    if (c.url.includes('rpc/registar_ficheiro')) {
      return new Response(JSON.stringify({ id: FICHEIRO }), { status: 200 })
    }
    if (c.url.includes('rpc/emitir_fcq')) {
      return new Response(
        JSON.stringify({ id: 'v1', versao: 1, conformidade: 'CONFORME' }),
        { status: 200 },
      )
    }
    return new Response('rota inesperada: ' + c.url, { status: 500 })
  }

  const amb: Ambiente = {
    url: 'https://projecto.supabase.co',
    chaveAnon: CHAVE_ANON,
    chaveServico: CHAVE_SERVICO,
    buscar: (entrada, opcoes) => {
      const chamada = { url: String(entrada), opcoes: opcoes ?? {} }
      chamadas.push(chamada)
      return Promise.resolve(respostas(chamada))
    },
  }
  return { amb, chamadas, impresso }
}

function pedido(corpo: unknown = { fcq_id: FCQ }, autorizacao = JWT): Request {
  return new Request('https://f/gerar-fcq', {
    method: 'POST',
    headers: { Authorization: autorizacao, 'Content-Type': 'application/json' },
    body: JSON.stringify(corpo),
  })
}

const aoBalde = (c: Chamada): boolean =>
  c.url.includes(`/storage/v1/object/${BALDE}/`)
const aoRegisto = (c: Chamada): boolean => c.url.includes('rpc/registar_ficheiro')
const aEmitir = (c: Chamada): boolean => c.url.includes('rpc/emitir_fcq')

Deno.test('sem Authorization não faz chamada nenhuma', async () => {
  const { amb, chamadas } = await ambienteFalso()
  const r = await tratar(pedido({ fcq_id: FCQ }, 'nenhuma'), amb)
  assertEquals(r.status, 401)
  assertEquals(chamadas.length, 0)
})

Deno.test('fcq_id que não é UUID é recusado antes de tudo', async () => {
  const { amb, chamadas } = await ambienteFalso()
  const r = await tratar(pedido({ fcq_id: 'nao-e-uuid' }), amb)
  assertEquals(r.status, 400)
  assertEquals(chamadas.length, 0)
})

Deno.test('impresso com outro hash pára a geração — nada é escrito', async () => {
  const { amb, chamadas } = await ambienteFalso((c) =>
    c.url.includes('/storage/v1/object/templates/')
      ? new Response(new Uint8Array([1, 2, 3]), { status: 200 })
      : null,
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 409)
  assertStringIncludes(JSON.stringify(await r.json()), 'impresso oficial')
  assertEquals(chamadas.filter(aoBalde).length, 0)
  assertEquals(chamadas.filter(aEmitir).length, 0)
})

Deno.test('caminho feliz: lê, verifica, desenha, guarda, regista e emite', async () => {
  const { amb, chamadas } = await ambienteFalso()
  const r = await tratar(pedido(), amb)

  assertEquals(r.status, 200)
  const corpo = (await r.json()) as Record<string, unknown>
  assertEquals(corpo.versao, 1)
  assertEquals(corpo.conformidade, 'CONFORME')
  assertEquals(corpo.ficheiro_id, FICHEIRO)
  assertEquals(corpo.impresso, 'I.CR.033 Rev. 9')
  assertEquals(corpo.avisos, [])
  assert(String(corpo.caminho_storage).startsWith(`${BALDE}/${OBRA}/${FCQ}/v1-`))

  // a ordem importa: o balde antes do registo, o registo antes da emissão
  const ordem = chamadas.map((c) => c.url)
  assert(ordem.findIndex(aoBaldeUrl) < ordem.findIndex((u) => u.includes('registar_ficheiro')))
  assert(
    ordem.findIndex((u) => u.includes('registar_ficheiro')) <
      ordem.findIndex((u) => u.includes('emitir_fcq')),
  )
})

function aoBaldeUrl(url: string): boolean {
  return url.includes(`/storage/v1/object/${BALDE}/`)
}

Deno.test('a chave de serviço só toca no balde; tudo o resto leva o JWT', async () => {
  const { amb, chamadas } = await ambienteFalso()
  await tratar(pedido(), amb)

  for (const c of chamadas) {
    const cabecalhos = (c.opcoes.headers ?? {}) as Record<string, string>
    if (aoBalde(c)) {
      assertEquals(cabecalhos['Authorization'], `Bearer ${CHAVE_SERVICO}`)
    } else {
      assertEquals(cabecalhos['Authorization'], JWT, `chave errada em ${c.url}`)
      assert(
        !JSON.stringify(cabecalhos).includes(CHAVE_SERVICO),
        `a chave de serviço fugiu para ${c.url}`,
      )
    }
  }

  // o impresso lê-se com o JWT de quem chamou: a política da 0021 é que decide
  const template = chamadas.find((c) => c.url.includes('/object/templates/'))!
  assertEquals((template.opcoes.headers as Record<string, string>)['Authorization'], JWT)
})

Deno.test('o ficheiro é registado como FCQ_PDF gerado, com o hash do que foi escrito', async () => {
  const { amb, chamadas } = await ambienteFalso()
  await tratar(pedido(), amb)

  const registo = chamadas.find(aoRegisto)!
  const corpo = JSON.parse(String(registo.opcoes.body)) as Record<string, unknown>
  assertEquals(corpo.p_tipo, 'FCQ_PDF')
  assertEquals(corpo.p_origem, 'GERADO')
  assertEquals(corpo.p_mime, 'application/pdf')
  assert(String(corpo.p_sha256).startsWith('\\x'))
  assert(String(corpo.p_caminho_storage).startsWith(`${BALDE}/`))

  // o mesmo hash que foi para o ficheiro vai para a versão: os dois registos
  // não podem falar de PDF diferentes
  const emissao = JSON.parse(String(chamadas.find(aEmitir)!.opcoes.body)) as Record<string, unknown>
  assertEquals(emissao.p_sha256_pdf, corpo.p_sha256)
  assertEquals(emissao.p_versao, 1)
  assertEquals(emissao.p_motivo_reemissao, null)
  assert(typeof emissao.p_dados === 'object')
})

Deno.test('a segunda versão leva o motivo da reemissão', async () => {
  const { amb, chamadas } = await ambienteFalso((c) =>
    c.url.includes('/rest/v1/fcq_versao?')
      ? new Response(JSON.stringify([{ versao: 1 }]), { status: 200 })
      : null,
  )
  await tratar(pedido({ fcq_id: FCQ, motivo_reemissao: 'Reinspeccao da cofragem apos correccao do escoramento.' }), amb)

  const emissao = JSON.parse(String(chamadas.find(aEmitir)!.opcoes.body)) as Record<string, unknown>
  assertEquals(emissao.p_versao, 2)
  assertStringIncludes(String(emissao.p_motivo_reemissao), 'Reinspeccao')
})

Deno.test('a recusa do servidor sobe com o código e o corpo originais', async () => {
  const recusa = {
    code: 'PT422',
    message: 'Reemitir a ficha exige um motivo escrito com pelo menos 20 caracteres.',
  }
  const { amb } = await ambienteFalso((c) =>
    aEmitir(c) ? new Response(JSON.stringify(recusa), { status: 422 }) : null,
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 422)
  assertEquals(await r.json(), recusa)
})

Deno.test('uma falha do Storage não passa por emissão', async () => {
  const { amb, chamadas } = await ambienteFalso((c) =>
    aoBalde(c) ? new Response('sem espaço', { status: 507 }) : null,
  )
  const r = await tratar(pedido(), amb)
  assertEquals(r.status, 502)
  assertStringIncludes(JSON.stringify(await r.json()), 'sem espaço')
  assertEquals(chamadas.filter(aoRegisto).length, 0)
  assertEquals(chamadas.filter(aEmitir).length, 0)
})
