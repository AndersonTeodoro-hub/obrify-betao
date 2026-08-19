// O motor da FCQ: pega no impresso oficial I.CR.033 Rev. 9 e escreve por cima.
//
// ── O IMPRESSO NÃO SE RECRIA ────────────────────────────────────────────────
// O documento que sai daqui É o PDF da DDN, com uma camada por cima. Não é um
// documento parecido nem uma reconstrução: são os mesmos bytes do impresso,
// verificados contra o sha256 que a 0010 fixou, mais o que a ficha diz. Se o
// ficheiro do balde divergir do hash, isto pára — um impresso trocado é um
// documento controlado trocado, e nenhuma FCQ vale mais do que o impresso em
// que foi feita.
//
// ── AS COORDENADAS NÃO SÃO DAQUI ────────────────────────────────────────────
// Vêm de modelo_impresso.mapa_campos, que a 0010 semeou a partir do
// docs/mapa_campos.json medido sobre o próprio PDF. O mapa viaja com o modelo e
// com o hash: mudar de revisão é uma linha nova em modelo_impresso, não uma
// alteração deste ficheiro. O sistema do mapa tem origem no canto superior
// esquerdo com y para baixo; o PDF tem origem em baixo. A conversão é uma
// subtracção e está numa função só, `Y()`.
//
// ── O ORÁCULO ───────────────────────────────────────────────────────────────
// docs/preencher.py é a via validada (reportlab + pypdf) e foi por ela que as
// coordenadas se mediram. Este motor reproduz-lhe o desenho: mesmas fontes,
// mesmos tamanhos, mesmos deslocamentos, mesmo traço do visto. docs/comparar_motor.py
// põe os dois PDF lado a lado, texto e posições. Onde o oráculo desenha o visto
// como dois segmentos vectoriais num caminho só, este desenha o mesmo caminho:
// o «√» não existe em WinAnsi e desenhá-lo como texto seria trocar o símbolo.

import {
  lineTo,
  moveTo,
  PDFDocument,
  popGraphicsState,
  pushGraphicsState,
  rgb,
  setLineWidth,
  setStrokingColor,
  StandardFonts,
  stroke,
} from 'npm:pdf-lib@1.17.1'

/** Azul-escuro, como no oráculo: distingue o que foi preenchido do impresso. */
export const TINTA = rgb(0, 0, 0.55)

export type Coluna = 'insp' | 'reinsp1' | 'reinsp2' | 'reinsp3'
export type Valor = 'C' | 'NC' | 'NA'
export type Seccao =
  | 'implantacao'
  | 'cofragem'
  | 'armaduras'
  | 'juntas'
  | 'betonagem'
  | 'pos_betonagem'

export type Mapa = {
  documento: { largura_pt: number; altura_pt: number; revisao: number }
  cabecalho: Record<string, { x: number; y_baseline: number }>
  blocos_assinatura: {
    x_por_coluna: Record<Coluna, number>
    blocos: { y_elaborado: number; y_data: number; seccao: Seccao }[]
  }
  observacoes: { x: number; y_topo: number }
  linhas: {
    id: string
    seccao: Seccao
    check: Record<Coluna, { x: number; cy: number }>
    anotacao: { x: number; y_baseline: number }
  }[]
}

/** O que se escreve no impresso. É esta a forma que o oráculo recebe, e é esta
 *  que fica em fcq_versao.dados: o instantâneo do que foi impresso, não uma
 *  descrição dele. */
export type Dados = {
  n_obra: string | null
  designacao: string | null
  numero: string | null
  n_anexos: string | null
  local_inspecao: string | null
  checks: Record<string, Partial<Record<Coluna, Valor>>>
  anotacoes: Record<string, string>
  assinaturas: Partial<Record<Seccao, Partial<Record<Coluna, { por: string; data: string }>>>>
  observacoes: string | null
  avisos: string[]
}

// ── WinAnsi ─────────────────────────────────────────────────────────────────
// As fontes normalizadas do PDF codificam WinAnsi. Um carácter fora dela faz o
// pdf-lib atirar, e a FCQ inteira deixaria de sair por causa de uma seta que
// alguém colou nas observações. Troca-se pelo equivalente mais próximo — e o
// aviso vai para fcq_versao.dados, portanto a troca fica registada em vez de
// acontecer às escondidas.
const EQUIVALENTE: Record<string, string> = {
  '–': '-', '—': '-', '‘': "'", '’': "'",
  '“': '"', '”': '"', '…': '...', '≤': '<=',
  '≥': '>=', '≈': '~', '×': 'x', '√': 'v',
  '→': '->', '•': '-', ' ': ' ',
}

/** Devolve o texto codificável e, se houve troca, o que se trocou. */
export function paraWinAnsi(texto: string): { texto: string; trocas: string[] } {
  const trocas: string[] = []
  let saida = ''
  for (const c of texto) {
    const ponto = c.codePointAt(0) ?? 0
    if (ponto === 9 || ponto === 10 || (ponto >= 32 && ponto <= 126) || (ponto >= 160 && ponto <= 255)) {
      saida += c
      continue
    }
    const troca = EQUIVALENTE[c]
    if (troca !== undefined) {
      saida += troca
      trocas.push(`${c} -> ${troca}`)
    } else {
      saida += '?'
      trocas.push(`${c} -> ?`)
    }
  }
  return { texto: saida, trocas }
}

/**
 * A mesma quebra gulosa do textwrap.wrap(texto, largura) do oráculo: corta nos
 * espaços, e uma palavra maior do que a largura é cortada à força.
 */
export function quebrar(texto: string, largura: number): string[] {
  const linhas: string[] = []
  let actual = ''
  for (const palavra of texto.split(/\s+/).filter((p) => p !== '')) {
    let p = palavra
    while (p.length > largura) {
      if (actual !== '') {
        linhas.push(actual)
        actual = ''
      }
      linhas.push(p.slice(0, largura))
      p = p.slice(largura)
    }
    if (actual === '') actual = p
    else if (actual.length + 1 + p.length <= largura) actual = `${actual} ${p}`
    else {
      linhas.push(actual)
      actual = p
    }
  }
  if (actual !== '') linhas.push(actual)
  return linhas
}

export async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const resumo = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(resumo))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

/**
 * Escreve os dados sobre o impresso e devolve o PDF.
 *
 * Sem rede e sem base de dados: recebe os bytes do impresso, o mapa e os dados,
 * e devolve bytes. É o que permite compará-la com o oráculo fora do Supabase.
 */
export async function desenhar(
  impresso: Uint8Array,
  mapa: Mapa,
  dados: Dados,
): Promise<Uint8Array<ArrayBuffer>> {
  const pdf = await PDFDocument.load(impresso)
  const pagina = pdf.getPages()[0]
  if (pagina === undefined) throw new Error('O impresso não tem páginas.')

  const helvetica = await pdf.embedFont(StandardFonts.Helvetica)
  const negrito = await pdf.embedFont(StandardFonts.HelveticaBold)

  const altura = mapa.documento.altura_pt
  /** O mapa mede de cima para baixo; o PDF conta de baixo para cima. */
  const Y = (topo: number): number => altura - topo

  const escrever = (
    texto: string,
    x: number,
    y: number,
    tamanho: number,
    fonte = helvetica,
  ): void => {
    pagina.drawText(texto, { x, y, size: tamanho, font: fonte, color: TINTA })
  }

  const centrar = (
    texto: string,
    x: number,
    y: number,
    tamanho: number,
    fonte = helvetica,
  ): void => {
    escrever(texto, x - fonte.widthOfTextAtSize(texto, tamanho) / 2, y, tamanho, fonte)
  }

  // ── cabeçalho ─────────────────────────────────────────────────────────────
  const tamanhoDoCampo: Record<string, number> = {
    n_obra: 7, designacao: 7, numero: 7, n_anexos: 7, local_inspecao: 6.5,
  }
  for (const [campo, tamanho] of Object.entries(tamanhoDoCampo)) {
    const valor = dados[campo as keyof Dados]
    const posicao = mapa.cabecalho[campo]
    // O que não vem preenchido sai por preencher, como o papel.
    if (typeof valor !== 'string' || valor === '' || posicao === undefined) continue
    escrever(valor, posicao.x, Y(posicao.y_baseline) + 1, tamanho)
  }

  // ── os 34 critérios ───────────────────────────────────────────────────────
  const porId = new Map(mapa.linhas.map((l) => [l.id, l]))

  for (const [linhaId, colunas] of Object.entries(dados.checks)) {
    const linha = porId.get(linhaId)
    if (linha === undefined) {
      throw new Error(`A linha ${linhaId} não existe no mapa de campos do impresso.`)
    }
    for (const [coluna, valor] of Object.entries(colunas)) {
      const pos = linha.check[coluna as Coluna]
      if (pos === undefined) {
        throw new Error(`A coluna ${coluna} não existe na linha ${linhaId} do mapa.`)
      }
      const x = pos.x
      const y = Y(pos.cy)

      if (valor === 'C') {
        // O visto é vectorial, não é texto: «√» não existe em WinAnsi, e
        // desenhá-lo com outra fonte seria pôr no impresso um símbolo que não é
        // o do impresso. São os dois segmentos do oráculo, ponto por ponto.
        //
        // Com os operadores em vez de dois drawLine: o drawLine do pdf-lib
        // fecha e reabre o caminho a meio, e dois traços independentes juntam-se
        // com dois topos rectos onde um caminho só faz um vértice. Ao corpo a
        // que isto se desenha vê-se — e o visto é o símbolo que mais conta no
        // documento. Um caminho, três pontos, como o oráculo.
        pagina.pushOperators(
          pushGraphicsState(),
          setStrokingColor(TINTA),
          setLineWidth(1.1),
          moveTo(x - 2.8, y - 0.2),
          lineTo(x - 0.9, y - 2.4),
          lineTo(x + 3.0, y + 2.8),
          stroke(),
          popGraphicsState(),
        )
      } else if (valor === 'NC') {
        centrar('X', x, y - 2.6, 7.5, negrito)
      } else if (valor === 'NA') {
        centrar('/', x, y - 2.6, 8)
      } else {
        throw new Error(`Valor ${String(valor)} desconhecido na linha ${linhaId}.`)
      }
    }
  }

  // ── anotações ─────────────────────────────────────────────────────────────
  for (const [linhaId, texto] of Object.entries(dados.anotacoes)) {
    const linha = porId.get(linhaId)
    if (linha === undefined) {
      throw new Error(`A anotação refere a linha ${linhaId}, que não existe no mapa.`)
    }
    escrever(texto.slice(0, 38), linha.anotacao.x, Y(linha.anotacao.y_baseline) + 1.5, 5.5)
  }

  // ── elaborado por / data, por secção ──────────────────────────────────────
  const xDaColuna = mapa.blocos_assinatura.x_por_coluna
  for (const bloco of mapa.blocos_assinatura.blocos) {
    const daSeccao = dados.assinaturas[bloco.seccao]
    if (daSeccao === undefined) continue
    for (const [coluna, assinatura] of Object.entries(daSeccao)) {
      const x = xDaColuna[coluna as Coluna]
      if (x === undefined || assinatura === undefined) continue
      escrever(assinatura.por.slice(0, 11), x + 0.5, Y(bloco.y_elaborado) + 1.5, 5.2)
      escrever(assinatura.data.slice(0, 11), x + 0.5, Y(bloco.y_data) + 1.5, 5.2)
    }
  }

  // ── observações ───────────────────────────────────────────────────────────
  if (dados.observacoes !== null && dados.observacoes !== '') {
    const o = mapa.observacoes
    let y = Y(o.y_topo)
    for (const linha of quebrar(dados.observacoes, 105).slice(0, 3)) {
      escrever(linha, o.x + 38, y, 6.5)
      y -= 8 // o leading do oráculo
    }
  }

  // Cópia para um ArrayBuffer próprio: o que sai daqui vai ser resumido em
  // sha256 e enviado como corpo de um pedido, e ambos exigem uma vista sobre um
  // ArrayBuffer e não sobre um buffer partilhado.
  return new Uint8Array(await pdf.save())
}

// ── daqui para baixo: a viagem ──────────────────────────────────────────────
// O desenho acima não sabe o que é uma base de dados nem um balde. O que se
// segue vai buscar o impresso, os dados, e devolve o documento registado.

export const BALDE = 'fcq'

export type Ambiente = {
  url: string
  chaveAnon: string
  /** Só para ESCREVER no balde. O balde não tem política de escrita nenhuma —
   *  nem para authenticated nem para ninguém — e é isso que faz da função a
   *  única porta de entrada, como na carregar-guia. Ler o impresso, ler a ficha
   *  e registar a versão vão todos com o JWT de quem chamou. */
  chaveServico: string
  buscar: typeof fetch
}

export class ErroDeGeracao extends Error {
  constructor(
    readonly estado: number,
    mensagem: string,
  ) {
    super(mensagem)
    this.name = 'ErroDeGeracao'
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const COLUNAS: Coluna[] = ['insp', 'reinsp1', 'reinsp2', 'reinsp3']

/**
 * Um id de ficheiro derivado do conteúdo, para a geração ser idempotente.
 *
 * Mesma ficha, mesma versão e mesmos bytes dão sempre o mesmo id — portanto
 * repetir a segunda metade da viagem depois de uma falha de rede reaproveita o
 * registo em vez de criar outro. Bytes diferentes dão id diferente e caminho
 * diferente, e aí nada colide.
 */
export async function idDeterministico(semente: string): Promise<string> {
  const resumo = new Uint8Array(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(semente)),
  )
  const b = resumo.slice(0, 16)
  b[6] = (b[6]! & 0x0f) | 0x50 // versão 5, como manda o RFC para um id derivado
  b[8] = (b[8]! & 0x3f) | 0x80 // variante
  const hex = Array.from(b).map((n) => n.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

export type Entrada = { fcqId: string; motivo: string | null }

export async function lerEntrada(pedido: Request): Promise<Entrada> {
  let corpo: unknown
  try {
    corpo = await pedido.json()
  } catch (causa) {
    throw new ErroDeGeracao(400, `O corpo do pedido não é JSON legível. ${String(causa)}`)
  }
  const campos = (corpo ?? {}) as Record<string, unknown>
  const fcqId = String(campos.fcq_id ?? '')
  if (!UUID.test(fcqId)) {
    throw new ErroDeGeracao(400, `O campo fcq_id não é um UUID: "${fcqId}".`)
  }
  const motivo = campos.motivo_reemissao === undefined || campos.motivo_reemissao === null
    ? null
    : String(campos.motivo_reemissao).trim() || null
  return { fcqId, motivo }
}

/** Um GET ao PostgREST com o JWT de quem chamou. É a RLS que decide o que volta. */
async function ler(
  amb: Ambiente,
  autorizacao: string,
  recurso: string,
): Promise<Record<string, unknown>[]> {
  const resposta = await amb.buscar(`${amb.url}/rest/v1/${recurso}`, {
    headers: {
      apikey: amb.chaveAnon,
      Authorization: autorizacao,
      'Accept-Profile': 'betonagens',
      Accept: 'application/json',
    },
  })
  const texto = await resposta.text()
  if (!resposta.ok) throw new ErroDeGeracao(resposta.status, texto)
  const linhas = JSON.parse(texto) as unknown
  if (!Array.isArray(linhas)) {
    throw new ErroDeGeracao(502, `A leitura de ${recurso} não devolveu uma lista: ${texto}`)
  }
  return linhas as Record<string, unknown>[]
}

async function umaLinha(
  amb: Ambiente,
  autorizacao: string,
  recurso: string,
  oQue: string,
): Promise<Record<string, unknown>> {
  const linhas = await ler(amb, autorizacao, recurso)
  const linha = linhas[0]
  if (linha === undefined) {
    throw new ErroDeGeracao(404, `${oQue} não existe, ou não é visível nesta sessão.`)
  }
  return linha
}

export type Ficha = {
  fcq: Record<string, unknown>
  pab: Record<string, unknown>
  obra: Record<string, unknown>
  frente: Record<string, unknown> | null
  modelo: Record<string, unknown>
  itens: Record<string, unknown>[]
  seccoes: Record<string, unknown>[]
  anexos: number
  proximaVersao: number
}

/** Tudo o que o impresso precisa, lido com o JWT de quem chamou. */
export async function buscarFicha(
  amb: Ambiente,
  autorizacao: string,
  fcqId: string,
): Promise<Ficha> {
  const fcq = await umaLinha(
    amb, autorizacao,
    `fcq?id=eq.${fcqId}&select=id,obra_id,pab_id,modelo_impresso_id,numero,estado`,
    `A ficha ${fcqId}`,
  )
  const pab = await umaLinha(
    amb, autorizacao,
    `pab?id=eq.${String(fcq.pab_id)}&select=numero,elemento,frente_id,observacoes,estado`,
    'O PAB da ficha',
  )
  const obra = await umaLinha(
    amb, autorizacao,
    `obra?id=eq.${String(fcq.obra_id)}&select=codigo,designacao`,
    'A obra da ficha',
  )
  const frentes = await ler(
    amb, autorizacao,
    `frente?id=eq.${String(pab.frente_id)}&select=designacao`,
  )
  const modelo = await umaLinha(
    amb, autorizacao,
    `modelo_impresso?id=eq.${String(fcq.modelo_impresso_id)}&select=codigo,revisao,caminho_storage,sha256,mapa_campos`,
    'O modelo do impresso',
  )
  const itens = await ler(
    amb, autorizacao,
    `fcq_item?fcq_id=eq.${fcqId}&substituido_por_id=is.null&select=linha_codigo,coluna,valor,anotacao`,
  )
  const seccoes = await ler(
    amb, autorizacao,
    `fcq_seccao_estado?fcq_id=eq.${fcqId}&assinada=is.true&select=seccao,coluna,nome_impresso,assinado_em,em_vigor`,
  )
  const guias = await ler(
    amb, autorizacao,
    `guia_remessa?pab_id=eq.${String(fcq.pab_id)}&substituida_por_id=is.null&select=id`,
  )
  const versoes = await ler(
    amb, autorizacao,
    `fcq_versao?fcq_id=eq.${fcqId}&select=versao&order=versao.desc&limit=1`,
  )

  return {
    fcq,
    pab,
    obra,
    frente: frentes[0] ?? null,
    modelo,
    itens,
    seccoes,
    anexos: guias.length,
    proximaVersao: Number(versoes[0]?.versao ?? 0) + 1,
  }
}

/** dd/mm/aaaa em hora de Lisboa, como o impresso pede. */
export function dataLocal(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const partes = new Intl.DateTimeFormat('pt-PT', {
    timeZone: 'Europe/Lisbon',
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  }).formatToParts(d)
  const parte = (tipo: string): string => partes.find((p) => p.type === tipo)?.value ?? ''
  return `${parte('day')}/${parte('month')}/${parte('year')}`
}

/**
 * Traduz a ficha para o que se escreve no impresso.
 *
 * É esta estrutura que fica em fcq_versao.dados: o instantâneo do que saiu
 * impresso, campo a campo. Quem daqui a dois anos quiser saber porque é que o
 * papel diz o que diz não tem de reconstruir nada.
 */
export function montarDados(ficha: Ficha): Dados {
  const avisos: string[] = []
  const limpar = (valor: unknown): string | null => {
    if (valor === null || valor === undefined) return null
    const { texto, trocas } = paraWinAnsi(String(valor))
    for (const t of trocas) avisos.push(`carácter substituído: ${t}`)
    return texto === '' ? null : texto
  }

  const checks: Dados['checks'] = {}
  const anotacoesPorColuna: Record<string, { coluna: Coluna; texto: string }> = {}

  for (const item of ficha.itens) {
    const linha = String(item.linha_codigo)
    const coluna = String(item.coluna) as Coluna
    const valor = String(item.valor) as Valor
    checks[linha] = { ...(checks[linha] ?? {}), [coluna]: valor }

    const anotacao = limpar(item.anotacao)
    if (anotacao === null) continue
    // O impresso tem UMA linha de anotação por critério. Fica a da coluna mais
    // à direita — a mais recente, que é a que descreve o estado actual.
    const jaLa = anotacoesPorColuna[linha]
    if (jaLa === undefined || COLUNAS.indexOf(coluna) >= COLUNAS.indexOf(jaLa.coluna)) {
      anotacoesPorColuna[linha] = { coluna, texto: anotacao }
    }
  }

  const anotacoes: Dados['anotacoes'] = {}
  for (const [linha, a] of Object.entries(anotacoesPorColuna)) anotacoes[linha] = a.texto

  const assinaturas: Dados['assinaturas'] = {}
  for (const s of ficha.seccoes) {
    const seccao = String(s.seccao) as Seccao
    const coluna = String(s.coluna) as Coluna
    const por = limpar(s.nome_impresso)
    if (por === null) continue
    // Uma assinatura fora de vigor — os itens mudaram depois de assinada —
    // continua a ter existido, e o impresso é o registo do que aconteceu. Sai
    // na mesma; quem quer saber se ainda cobre os itens tem a coluna em_vigor.
    assinaturas[seccao] = {
      ...(assinaturas[seccao] ?? {}),
      [coluna]: { por, data: dataLocal(String(s.assinado_em)) },
    }
  }

  const frente = limpar(ficha.frente?.designacao)
  const elemento = limpar(ficha.pab.elemento)
  const local = [frente, elemento].filter((p) => p !== null).join(' / ')

  return {
    n_obra: limpar(ficha.obra.codigo),
    designacao: limpar(ficha.obra.designacao),
    // O código do impresso é 033; o número da ficha vem a seguir, como no papel.
    numero: `033 / ${String(ficha.fcq.numero)}`,
    n_anexos: String(ficha.anexos),
    local_inspecao: local === '' ? null : local,
    checks,
    anotacoes,
    assinaturas,
    observacoes: limpar(ficha.pab.observacoes),
    avisos,
  }
}

/** O impresso oficial, do balde templates, com o JWT de quem chamou. */
export async function descarregarImpresso(
  amb: Ambiente,
  autorizacao: string,
  caminho: string,
): Promise<Uint8Array<ArrayBuffer>> {
  const resposta = await amb.buscar(`${amb.url}/storage/v1/object/${caminho}`, {
    headers: { apikey: amb.chaveAnon, Authorization: autorizacao },
  })
  if (!resposta.ok) {
    throw new ErroDeGeracao(
      502,
      `O impresso oficial não veio do Storage (${resposta.status}): ${await resposta.text()}. ` +
        'Sem impresso não há FCQ — não se gera um documento parecido.',
    )
  }
  return new Uint8Array(await resposta.arrayBuffer())
}

/** bytea do PostgREST: "\\x5d9e..." → "5d9e...". */
export function hexDoBytea(valor: unknown): string {
  const texto = String(valor ?? '')
  return (texto.startsWith('\\x') ? texto.slice(2) : texto).toLowerCase()
}

/** Põe o documento no balde. 409 é o mesmo objecto: o caminho leva o hash. */
export async function guardarNoBalde(
  amb: Ambiente,
  caminho: string,
  bytes: Uint8Array<ArrayBuffer>,
): Promise<boolean> {
  const resposta = await amb.buscar(`${amb.url}/storage/v1/object/${BALDE}/${caminho}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${amb.chaveServico}`,
      'Content-Type': 'application/pdf',
      'x-upsert': 'false',
    },
    body: bytes,
  })
  if (resposta.ok) return false
  if (resposta.status === 409) return true
  throw new ErroDeGeracao(
    502,
    `O Storage recusou a FCQ (${resposta.status}): ${await resposta.text()}`,
  )
}

/** Chama uma função de serviço com o JWT de quem chamou. */
async function rpc(
  amb: Ambiente,
  autorizacao: string,
  funcao: string,
  corpo: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const resposta = await amb.buscar(`${amb.url}/rest/v1/rpc/${funcao}`, {
    method: 'POST',
    headers: {
      apikey: amb.chaveAnon,
      Authorization: autorizacao,
      'Content-Type': 'application/json',
      'Content-Profile': 'betonagens',
      Accept: 'application/json',
    },
    body: JSON.stringify(corpo),
  })
  const texto = await resposta.text()
  if (!resposta.ok) throw new ErroDeGeracao(resposta.status, texto)
  const linha = JSON.parse(texto) as Record<string, unknown> | null
  if (linha === null || typeof linha !== 'object') {
    throw new ErroDeGeracao(502, `${funcao} não devolveu uma linha. Veio: ${texto}`)
  }
  return linha
}

/** O caminho completo, do pedido à resposta. */
export async function tratar(pedido: Request, amb: Ambiente): Promise<Response> {
  if (pedido.method !== 'POST') return resposta(405, { erro: 'Só POST.' })

  const autorizacao = pedido.headers.get('Authorization')
  if (autorizacao === null || !autorizacao.startsWith('Bearer ')) {
    return resposta(401, {
      erro: 'Falta o cabeçalho Authorization com o token da sessão. Esta função não emite nada em nome de ninguém.',
    })
  }

  try {
    const entrada = await lerEntrada(pedido)
    const ficha = await buscarFicha(amb, autorizacao, entrada.fcqId)

    // ── o impresso é o impresso ──────────────────────────────────────────────
    const impresso = await descarregarImpresso(
      amb, autorizacao, String(ficha.modelo.caminho_storage),
    )
    const shaImpresso = await sha256Hex(impresso)
    const shaEsperado = hexDoBytea(ficha.modelo.sha256)
    if (shaImpresso !== shaEsperado) {
      throw new ErroDeGeracao(
        409,
        `O impresso no Storage não é o que a 0010 registou. Esperado ${shaEsperado}, veio ${shaImpresso}. ` +
          'A FCQ faz-se sobre o impresso oficial ou não se faz.',
      )
    }

    const mapa = ficha.modelo.mapa_campos as Mapa
    const dados = montarDados(ficha)
    const pdf = await desenhar(impresso, mapa, dados)

    const shaPdf = await sha256Hex(pdf)
    const versao = ficha.proximaVersao
    const caminho = `${String(ficha.fcq.obra_id)}/${entrada.fcqId}/v${versao}-${shaPdf}.pdf`
    const ficheiroId = await idDeterministico(`${entrada.fcqId}:${versao}:${shaPdf}`)

    const reaproveitado = await guardarNoBalde(amb, caminho, pdf)

    const ficheiro = await rpc(amb, autorizacao, 'registar_ficheiro', {
      p_id: ficheiroId,
      p_obra_id: String(ficha.fcq.obra_id),
      p_tipo: 'FCQ_PDF',
      p_origem: 'GERADO',
      p_caminho_storage: `${BALDE}/${caminho}`,
      p_sha256: `\\x${shaPdf}`,
      p_bytes: pdf.byteLength,
      p_mime: 'application/pdf',
    })

    const emitida = await rpc(amb, autorizacao, 'emitir_fcq', {
      p_fcq_id: entrada.fcqId,
      p_versao: versao,
      p_ficheiro_pdf_id: String(ficheiro.id),
      p_sha256_pdf: `\\x${shaPdf}`,
      p_dados: dados,
      p_motivo_reemissao: entrada.motivo,
    })

    return resposta(200, {
      versao_id: emitida.id,
      versao: emitida.versao,
      conformidade: emitida.conformidade,
      ficheiro_id: ficheiro.id,
      caminho_storage: `${BALDE}/${caminho}`,
      sha256: shaPdf,
      bytes: pdf.byteLength,
      impresso: `${String(ficha.modelo.codigo)} Rev. ${String(ficha.modelo.revisao)}`,
      reaproveitado,
      avisos: dados.avisos,
    })
  } catch (causa) {
    if (causa instanceof ErroDeGeracao) {
      const corpo = tentarJson(causa.message)
      return resposta(causa.estado, corpo ?? { erro: causa.message })
    }
    // Nada é engolido: o que não se previu sobe como 500 com o texto do erro.
    return resposta(500, { erro: `Falha inesperada na geração da FCQ: ${String(causa)}` })
  }
}

function tentarJson(texto: string): unknown {
  try {
    const v: unknown = JSON.parse(texto)
    return typeof v === 'object' && v !== null ? v : null
  } catch {
    return null
  }
}

function resposta(estado: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), {
    status: estado,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  })
}
