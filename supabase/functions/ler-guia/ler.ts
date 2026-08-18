// A leitura da fotografia de uma guia por modelo de visão, separada do arranque
// do servidor para poder ser exercitada sem rede.
//
// ── PORQUE É QUE ISTO NÃO É FEITO NO BROWSER ────────────────────────────────
// A chave da API da Anthropic. Tudo o que chega ao telemóvel é legível por quem
// tem o telemóvel — uma chave embutida no pacote é uma chave publicada. Aqui
// vive no ambiente da função, entra por Deno.env e não sai deste ficheiro.
//
// ── SEM CHAVE DE SERVIÇO, EM PASSO NENHUM ───────────────────────────────────
// Ao contrário da carregar-guia, esta função não precisa de service_role: lê a
// linha do ficheiro, descarrega a fotografia do balde e regista a leitura, tudo
// com o JWT de quem chamou. Quem decide se a pode ver é a RLS — a política de
// leitura da 0018 já é exactamente a pergunta certa. Uma chave de serviço aqui
// seria um desvio ao controlo de acesso a troco de nada.
//
// ── O QUE NÃO SE MANDA AO MODELO ────────────────────────────────────────────
// O PAB. Dizer ao modelo o que devia estar na guia é ensiná-lo a confirmar o
// pedido em vez de ler o papel. O cruzamento faz-se depois, na base de dados,
// onde há regras escritas e uma recusa com frase.
//
// ── ZERO DEPENDÊNCIAS ───────────────────────────────────────────────────────
// fetch, btoa e crypto.randomUUID. Tudo nativo do Deno.

/** O tecto da fotografia, o mesmo do balde (0018) e da carregar-guia. Repetido
 *  aqui pela mesma razão de sempre: quem recusa mais cedo dá melhor mensagem. */
export const TECTO_BYTES = 10 * 1024 * 1024

/** O que o balde aceita, e que o modelo também lê. */
export const TIPOS = ['image/jpeg', 'image/png', 'image/webp']

/** O modelo. Fase 1 com o Opus: ler um impresso denso de uma central
 *  desconhecida, sem exemplares, é o caso difícil. A troca decide-se na fase 2,
 *  com uma guia real e números medidos — e é uma string. */
export const MODELO = 'claude-opus-5'

export const URL_ANTHROPIC = 'https://api.anthropic.com/v1/messages'
export const VERSAO_ANTHROPIC = '2023-06-01'

/** Curto de propósito: a saída é um objecto pequeno. Se algum dia bater no
 *  tecto, o stop_reason diz max_tokens e a função recusa em vez de devolver
 *  meio JSON. */
export const TECTO_TOKENS = 4000

export type Ambiente = {
  url: string
  chaveAnon: string
  chaveAnthropic: string
  buscar: typeof fetch
}

/** Um erro com o código HTTP que lhe corresponde. Nada é engolido: o que sobe
 *  daqui chega ao cliente com a frase que se escreveu. */
export class ErroDeLeitura extends Error {
  constructor(
    readonly estado: number,
    mensagem: string,
  ) {
    super(mensagem)
    this.name = 'ErroDeLeitura'
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// ── o que se pede ao modelo ─────────────────────────────────────────────────

/**
 * A instrução. É aqui que mora a decisão de não calibrar por central.
 *
 * Não há mapa de campos, não há coordenadas, não há modelo por central: há o
 * significado de cada campo, a proibição de adivinhar, e um saco para o que o
 * esquema não previu. Na obra seguinte as guias são de outra central e os
 * rótulos mudam — os significados não.
 *
 * A caligrafia fica de fora por decisão: o slump anotado à mão e a assinatura
 * são prova na fotografia, não dado a transcrever por uma máquina.
 */
export const PROMPT = [
  'És um leitor de guias de remessa de betão pronto.',
  '',
  'Lê APENAS o que está impresso ou dactilografado.',
  'Não leias caligrafia, assinaturas nem anotações à mão: se um valor só existir',
  'manuscrito, devolve null com confiança BAIXA.',
  'Não infiras, não completes, não corrijas. Se não consegues ler, é null.',
  'Não conheces esta central. Os rótulos, a ordem e o desenho variam de central',
  'para central — procura o significado, não a posição.',
  'Tudo o que estiver impresso e não couber nos campos do esquema vai para',
  'outros_campos, com o rótulo tal como aparece no papel.',
  '',
  'A confiança é por campo: ALTA quando o valor está nítido e sem ambiguidade,',
  'MEDIA quando é legível mas duvidoso, BAIXA quando é palpite. Na dúvida entre',
  'dois níveis, escolhe o mais baixo — quem confirma é a pessoa que tem o papel',
  'na mão, e um ALTA errado tira-lhe essa oportunidade.',
].join('\n')

const CONFIANCA = { type: 'string', enum: ['ALTA', 'MEDIA', 'BAIXA'] }

function campo(tipo: 'string' | 'number'): unknown {
  return {
    type: 'object',
    additionalProperties: false,
    required: ['valor', 'confianca'],
    properties: {
      valor: { anyOf: [{ type: tipo }, { type: 'null' }] },
      confianca: CONFIANCA,
    },
  }
}

/**
 * O esquema da resposta, imposto pelo próprio pedido (structured outputs).
 *
 * Os quatro primeiros campos são os que a base compara por igualdade para
 * derivar a proveniência; os outros existem para o empreiteiro e o fiscal
 * verem, e para nada se perder do que estava impresso.
 */
export const ESQUEMA = {
  type: 'object',
  additionalProperties: false,
  required: [
    'numero_guia',
    'volume_m3',
    'classe_betao',
    'data',
    'hora',
    'central_nome',
    'classe_exposicao',
    'classe_consistencia',
    'dmax_mm',
    'cliente_ou_obra',
    'matricula',
    'outros_campos',
    'nota_legibilidade',
  ],
  properties: {
    numero_guia: campo('string'),
    volume_m3: campo('number'),
    classe_betao: campo('string'),
    // Data e hora separadas: a data compara-se com o dia da betonagem, a hora
    // impressa é quase sempre a de carga e é sugestão, não facto do registo.
    data: campo('string'),
    hora: campo('string'),
    central_nome: campo('string'),
    classe_exposicao: campo('string'),
    classe_consistencia: campo('string'),
    dmax_mm: campo('number'),
    cliente_ou_obra: campo('string'),
    matricula: campo('string'),
    outros_campos: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['rotulo', 'valor'],
        properties: { rotulo: { type: 'string' }, valor: { type: 'string' } },
      },
    },
    nota_legibilidade: { anyOf: [{ type: 'string' }, { type: 'null' }] },
  },
}

// ── passos ──────────────────────────────────────────────────────────────────

export type Entrada = { ficheiroId: string }

/** Lê e valida o corpo. Recusa antes de tocar em rede nenhuma. */
export async function lerEntrada(pedido: Request): Promise<Entrada> {
  let corpo: unknown
  try {
    corpo = await pedido.json()
  } catch (causa) {
    throw new ErroDeLeitura(400, `O corpo do pedido não é JSON legível. ${String(causa)}`)
  }

  const ficheiroId = String((corpo as Record<string, unknown> | null)?.ficheiro_id ?? '')
  if (!UUID.test(ficheiroId)) {
    throw new ErroDeLeitura(400, `O campo ficheiro_id não é um UUID: "${ficheiroId}".`)
  }
  return { ficheiroId }
}

export type Ficheiro = { obraId: string; caminho: string; mime: string }

/**
 * A linha do ficheiro, LIDA COM O JWT DE QUEM CHAMOU.
 *
 * É este o controlo de acesso: se a RLS não mostra a linha, o ficheiro não
 * existe para esta sessão e a função pára aqui. Não há segunda pergunta nem
 * chave que a contorne.
 */
export async function buscarFicheiro(
  amb: Ambiente,
  autorizacao: string,
  ficheiroId: string,
): Promise<Ficheiro> {
  const resposta = await amb.buscar(
    `${amb.url}/rest/v1/ficheiro?id=eq.${ficheiroId}&select=obra_id,caminho_storage,mime,tipo`,
    {
      headers: {
        apikey: amb.chaveAnon,
        Authorization: autorizacao,
        'Accept-Profile': 'betonagens',
        Accept: 'application/json',
      },
    },
  )

  const texto = await resposta.text()
  if (!resposta.ok) throw new ErroDeLeitura(resposta.status, texto)

  let linhas: unknown
  try {
    linhas = JSON.parse(texto)
  } catch (causa) {
    throw new ErroDeLeitura(502, `A leitura do ficheiro não devolveu JSON: ${String(causa)}`)
  }

  if (!Array.isArray(linhas) || linhas.length === 0) {
    throw new ErroDeLeitura(
      404,
      `O ficheiro ${ficheiroId} não está registado, ou não é visível nesta sessão.`,
    )
  }

  const linha = linhas[0] as Record<string, unknown>
  if (linha.tipo !== 'GUIA') {
    throw new ErroDeLeitura(422, `O ficheiro ${ficheiroId} não é uma fotografia de guia.`)
  }

  const mime = String(linha.mime ?? '')
  if (!TIPOS.includes(mime)) {
    throw new ErroDeLeitura(
      415,
      `Tipo de ficheiro não legível: "${mime}". Aceita-se ${TIPOS.join(', ')}.`,
    )
  }

  return {
    obraId: String(linha.obra_id ?? ''),
    caminho: String(linha.caminho_storage ?? ''),
    mime,
  }
}

/**
 * Os bytes, também com o JWT de quem chamou.
 *
 * São os bytes tal como foram guardados, sem recompressão: é sobre eles que o
 * sha256 da 0003 foi calculado, e recodificar aqui seria mandar ao modelo uma
 * imagem que já não é a prova.
 */
export async function descarregarFoto(
  amb: Ambiente,
  autorizacao: string,
  caminho: string,
): Promise<Uint8Array<ArrayBuffer>> {
  const resposta = await amb.buscar(`${amb.url}/storage/v1/object/${caminho}`, {
    headers: { apikey: amb.chaveAnon, Authorization: autorizacao },
  })

  if (!resposta.ok) {
    throw new ErroDeLeitura(
      resposta.status === 404 || resposta.status === 400 ? 404 : 502,
      `O Storage não devolveu a fotografia (${resposta.status}): ${await resposta.text()}`,
    )
  }

  const bytes = new Uint8Array(await resposta.arrayBuffer())
  if (bytes.byteLength === 0) {
    throw new ErroDeLeitura(502, 'A fotografia veio vazia do Storage.')
  }
  if (bytes.byteLength > TECTO_BYTES) {
    throw new ErroDeLeitura(
      413,
      `A fotografia tem ${bytes.byteLength} bytes e o tecto de leitura é ${TECTO_BYTES}.`,
    )
  }
  return bytes
}

/** base64 aos pedaços: `String.fromCharCode(...bytes)` de uma vez rebenta a
 *  pilha em ficheiros de megabytes. */
export function base64De(bytes: Uint8Array): string {
  const PEDACO = 0x8000
  let binario = ''
  for (let i = 0; i < bytes.length; i += PEDACO) {
    binario += String.fromCharCode(...bytes.subarray(i, i + PEDACO))
  }
  return btoa(binario)
}

export type Leitura = { extraido: unknown; tokensEntrada: number; tokensSaida: number }

/**
 * A pergunta ao modelo.
 *
 * effort baixo porque isto é extracção e não raciocínio; o pensamento fica no
 * valor por defeito, que no Opus 5 é adaptativo — desligá-lo tem modos de falha
 * conhecidos e não poupava aqui nada que o effort não poupe.
 */
export async function perguntarAoModelo(
  amb: Ambiente,
  bytes: Uint8Array,
  mime: string,
): Promise<Leitura> {
  const resposta = await amb.buscar(URL_ANTHROPIC, {
    method: 'POST',
    headers: {
      'x-api-key': amb.chaveAnthropic,
      'anthropic-version': VERSAO_ANTHROPIC,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: MODELO,
      max_tokens: TECTO_TOKENS,
      system: PROMPT,
      output_config: {
        effort: 'low',
        format: { type: 'json_schema', schema: ESQUEMA },
      },
      messages: [
        {
          role: 'user',
          content: [
            { type: 'image', source: { type: 'base64', media_type: mime, data: base64De(bytes) } },
            { type: 'text', text: 'Lê esta guia de remessa.' },
          ],
        },
      ],
    }),
  })

  const texto = await resposta.text()
  if (!resposta.ok) {
    throw new ErroDeLeitura(502, `O modelo recusou o pedido (${resposta.status}): ${texto}`)
  }

  let corpo: {
    content?: { type?: string; text?: string }[]
    stop_reason?: string
    usage?: { input_tokens?: number; output_tokens?: number }
  }
  try {
    corpo = JSON.parse(texto)
  } catch (causa) {
    throw new ErroDeLeitura(502, `A resposta do modelo não é JSON: ${String(causa)}`)
  }

  // Um stop_reason que não seja fim de turno é resposta incompleta. Devolver
  // meio JSON como se fosse leitura é o pior dos dois mundos: parece que leu.
  if (corpo.stop_reason !== undefined && corpo.stop_reason !== 'end_turn') {
    throw new ErroDeLeitura(
      502,
      `O modelo parou por "${corpo.stop_reason}" e a leitura não está completa. Registe a guia à mão.`,
    )
  }

  const bloco = (corpo.content ?? []).find((b) => b.type === 'text')
  if (bloco === undefined || typeof bloco.text !== 'string') {
    throw new ErroDeLeitura(502, `A resposta do modelo não traz texto. Veio: ${texto}`)
  }

  let extraido: unknown
  try {
    extraido = JSON.parse(bloco.text)
  } catch (causa) {
    throw new ErroDeLeitura(502, `O que o modelo devolveu não é o JSON pedido: ${String(causa)}`)
  }
  if (typeof extraido !== 'object' || extraido === null || Array.isArray(extraido)) {
    throw new ErroDeLeitura(502, `O modelo devolveu ${typeof extraido} em vez de um objecto.`)
  }

  const tokensEntrada = Number(corpo.usage?.input_tokens ?? 0)
  const tokensSaida = Number(corpo.usage?.output_tokens ?? 0)
  if (!(tokensEntrada > 0) || !(tokensSaida > 0)) {
    throw new ErroDeLeitura(
      502,
      `A resposta do modelo não traz contagem de tokens utilizável (entrada ${tokensEntrada}, saída ${tokensSaida}).`,
    )
  }

  return { extraido, tokensEntrada, tokensSaida }
}

/**
 * Regista a leitura na base, COM O JWT DE QUEM CHAMOU.
 *
 * O id é gerado aqui e não recebido: duas leituras da mesma fotografia dão
 * resultados que podem não ser idênticos, e reaproveitar o id faria a segunda
 * bater contra a idempotência da registar_leitura_guia. Cada leitura é uma
 * leitura; a guia diz qual delas usou.
 */
export async function registarNaBase(
  amb: Ambiente,
  autorizacao: string,
  ficheiroId: string,
  leitura: Leitura,
): Promise<string> {
  const id = crypto.randomUUID()
  const resposta = await amb.buscar(`${amb.url}/rest/v1/rpc/registar_leitura_guia`, {
    method: 'POST',
    headers: {
      apikey: amb.chaveAnon,
      Authorization: autorizacao,
      'Content-Type': 'application/json',
      'Content-Profile': 'betonagens',
      Accept: 'application/json',
    },
    body: JSON.stringify({
      p_id: id,
      p_ficheiro_id: ficheiroId,
      p_modelo: MODELO,
      p_extraido: leitura.extraido,
      p_tokens_entrada: leitura.tokensEntrada,
      p_tokens_saida: leitura.tokensSaida,
    }),
  })

  const corpo = await resposta.text()
  if (!resposta.ok) throw new ErroDeLeitura(resposta.status, corpo)

  const linha = JSON.parse(corpo) as { id?: string } | null
  if (linha === null || typeof linha.id !== 'string') {
    throw new ErroDeLeitura(502, `registar_leitura_guia não devolveu uma leitura com id. Veio: ${corpo}`)
  }
  return linha.id
}

/** O caminho completo, do pedido à resposta. */
export async function tratar(pedido: Request, amb: Ambiente): Promise<Response> {
  if (pedido.method !== 'POST') {
    return resposta(405, { erro: 'Só POST.' })
  }

  const autorizacao = pedido.headers.get('Authorization')
  if (autorizacao === null || !autorizacao.startsWith('Bearer ')) {
    return resposta(401, {
      erro: 'Falta o cabeçalho Authorization com o token da sessão. Esta função não lê nada em nome de ninguém.',
    })
  }

  try {
    const entrada = await lerEntrada(pedido)
    const ficheiro = await buscarFicheiro(amb, autorizacao, entrada.ficheiroId)
    const bytes = await descarregarFoto(amb, autorizacao, ficheiro.caminho)
    const leitura = await perguntarAoModelo(amb, bytes, ficheiro.mime)
    const leituraId = await registarNaBase(amb, autorizacao, entrada.ficheiroId, leitura)

    return resposta(200, {
      leitura_id: leituraId,
      modelo: MODELO,
      extraido: leitura.extraido,
      tokens_entrada: leitura.tokensEntrada,
      tokens_saida: leitura.tokensSaida,
    })
  } catch (causa) {
    if (causa instanceof ErroDeLeitura) {
      // O corpo do PostgREST é JSON e vai inteiro; o resto é uma frase nossa.
      const corpo = tentarJson(causa.message)
      return resposta(causa.estado, corpo ?? { erro: causa.message })
    }
    // Nada é engolido: o que não se previu sobe como 500 com o texto do erro.
    return resposta(500, { erro: `Falha inesperada na leitura: ${String(causa)}` })
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
