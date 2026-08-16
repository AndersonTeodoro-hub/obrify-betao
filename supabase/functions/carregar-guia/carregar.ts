// A lógica do carregamento da fotografia de uma guia, separada do arranque do
// servidor para poder ser exercitada sem rede.
//
// ── PORQUE É QUE ISTO NÃO É FEITO NO BROWSER ────────────────────────────────
// A fotografia da guia é prova, e o que lhe dá valor é o sha256 gravado em
// betonagens.ficheiro. Se o hash fosse calculado no cliente, alguém carregava a
// fotografia A e declarava o hash da B — e o INV3, «a mesma fotografia não
// entra duas vezes», passava a proteger nada. O hash é calculado aqui, sobre os
// bytes que acabaram de chegar, e é esse que vai para a base.
//
// ── DUAS CHAVES, DOIS PAPÉIS, DE PROPÓSITO ─────────────────────────────────
// O Storage é escrito com service_role, que contorna a RLS: assim o balde não
// precisa de política de escrita nenhuma e a única porta de entrada é esta.
// O registo na base é feito com o JWT DE QUEM CHAMOU, para que exigir_actor e
// exigir_acesso_obra continuem a aplicar-se. Se aqui se usasse service_role, a
// função passava a ser um desvio ao controlo de acesso.
//
// ── ZERO DEPENDÊNCIAS ───────────────────────────────────────────────────────
// crypto.subtle para o hash, Request.formData() para o multipart, fetch para o
// Storage e para o PostgREST. Tudo nativo do Deno. Uma biblioteca aqui só
// pouparia dois fetch e traria uma importação remota para fixar.

/** O tecto da fotografia. Uma fotografia de telemóvel comprimida anda pelos 2
 *  a 4 MB; o dobro disso dá folga sem servir de porta a um carregamento
 *  absurdo. O mesmo valor está no balde, na 0018 — aqui recusa-se mais cedo,
 *  para dar melhor mensagem. */
export const TECTO_BYTES = 10 * 1024 * 1024

/** O que o balde aceita, na 0018. Repetido aqui pela mesma razão. */
export const TIPOS: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
}

export const BALDE = 'guias'

export type Ambiente = {
  url: string
  chaveServico: string
  chaveAnon: string
  buscar: typeof fetch
}

/** Um erro com o código HTTP que lhe corresponde. Nada é engolido: o que sobe
 *  daqui chega ao cliente com a frase que se escreveu. */
export class ErroDeCarregamento extends Error {
  constructor(
    readonly estado: number,
    mensagem: string,
  ) {
    super(mensagem)
    this.name = 'ErroDeCarregamento'
  }
}

export function hexDe(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

export async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  return hexDe(await crypto.subtle.digest('SHA-256', bytes))
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * A chave do objecto dentro do balde: {obra}/{sha256}.{extensão}.
 *
 * Derivada do conteúdo de propósito — os mesmos bytes caem sempre no mesmo
 * sítio, e é isso que torna o carregamento idempotente sem ninguém ter de
 * perguntar ao Storage se já lá está.
 */
export function caminhoDe(obraId: string, sha: string, mime: string): string {
  return `${obraId}/${sha}.${TIPOS[mime]}`
}

export type Entrada = {
  id: string
  obraId: string
  origem: 'CAMARA' | 'GALERIA'
  justificacao: string | null
  bytes: Uint8Array<ArrayBuffer>
  mime: string
}

/** Lê e valida o multipart. Recusa antes de escrever seja o que for. */
export async function lerEntrada(pedido: Request): Promise<Entrada> {
  let forma: FormData
  try {
    forma = await pedido.formData()
  } catch (causa) {
    throw new ErroDeCarregamento(
      400,
      `O corpo do pedido não é multipart/form-data legível. ${String(causa)}`,
    )
  }

  const id = String(forma.get('id') ?? '')
  const obraId = String(forma.get('obra_id') ?? '')
  const origem = String(forma.get('origem') ?? '')
  const justificacaoBruta = forma.get('justificacao_galeria')
  const ficheiro = forma.get('ficheiro')

  if (!UUID.test(id)) throw new ErroDeCarregamento(400, `O campo id não é um UUID: "${id}".`)
  if (!UUID.test(obraId)) {
    throw new ErroDeCarregamento(400, `O campo obra_id não é um UUID: "${obraId}".`)
  }
  if (origem !== 'CAMARA' && origem !== 'GALERIA') {
    throw new ErroDeCarregamento(400, `A origem tem de ser CAMARA ou GALERIA, veio "${origem}".`)
  }

  const justificacao =
    justificacaoBruta === null ? null : String(justificacaoBruta).trim() || null

  // A justificação da galeria não é decorativa: registar_ficheiro grava uma
  // exceção nominal com ela. Sem ela, a exceção ficaria por explicar.
  if (origem === 'GALERIA' && justificacao === null) {
    throw new ErroDeCarregamento(
      400,
      'Uma fotografia vinda da galeria exige justificação escrita: diga porque não foi tirada na hora.',
    )
  }

  if (!(ficheiro instanceof File)) {
    throw new ErroDeCarregamento(400, 'Falta a fotografia no campo "ficheiro".')
  }

  const mime = ficheiro.type
  if (!(mime in TIPOS)) {
    throw new ErroDeCarregamento(
      415,
      `Tipo de ficheiro não aceite: "${mime}". Aceita-se ${Object.keys(TIPOS).join(', ')}.`,
    )
  }
  if (ficheiro.size > TECTO_BYTES) {
    throw new ErroDeCarregamento(
      413,
      `A fotografia tem ${ficheiro.size} bytes e o tecto é ${TECTO_BYTES}.`,
    )
  }
  if (ficheiro.size === 0) {
    throw new ErroDeCarregamento(400, 'A fotografia está vazia.')
  }

  return {
    id,
    obraId,
    origem,
    justificacao,
    bytes: new Uint8Array(await ficheiro.arrayBuffer()),
    mime,
  }
}

/**
 * Põe os bytes no balde. Um 409 do Storage não é falha: o caminho é derivado do
 * hash, portanto um objecto já lá com este nome tem, por construção, estes
 * bytes. Devolve se foi reaproveitado, porque quem chamou tem direito a saber.
 */
export async function guardarNoBalde(
  amb: Ambiente,
  caminho: string,
  bytes: Uint8Array<ArrayBuffer>,
  mime: string,
): Promise<boolean> {
  const resposta = await amb.buscar(`${amb.url}/storage/v1/object/${BALDE}/${caminho}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${amb.chaveServico}`,
      'Content-Type': mime,
      'x-upsert': 'false',
    },
    body: bytes,
  })

  if (resposta.ok) return false
  if (resposta.status === 409) return true

  throw new ErroDeCarregamento(
    502,
    `O Storage recusou a fotografia (${resposta.status}): ${await resposta.text()}`,
  )
}

/**
 * Regista o ficheiro na base, COM O JWT DE QUEM CHAMOU.
 *
 * O que o PostgREST devolver em caso de erro sobe tal e qual — código e corpo.
 * Reescrever a mensagem do servidor aqui seria trocar uma frase que diz o que
 * se passou por outra que diz o que este código julga que se passou.
 */
export async function registarNaBase(
  amb: Ambiente,
  autorizacao: string,
  entrada: Entrada,
  caminho: string,
  sha: string,
): Promise<{ id: string }> {
  const resposta = await amb.buscar(`${amb.url}/rest/v1/rpc/registar_ficheiro`, {
    method: 'POST',
    headers: {
      apikey: amb.chaveAnon,
      Authorization: autorizacao,
      'Content-Type': 'application/json',
      'Content-Profile': 'betonagens',
      Accept: 'application/json',
    },
    body: JSON.stringify({
      p_id: entrada.id,
      p_obra_id: entrada.obraId,
      p_tipo: 'GUIA',
      p_origem: entrada.origem,
      p_caminho_storage: `${BALDE}/${caminho}`,
      // bytea em PostgREST: hexadecimal com o prefixo \x
      p_sha256: `\\x${sha}`,
      p_bytes: entrada.bytes.byteLength,
      p_mime: entrada.mime,
      p_justificacao_galeria: entrada.justificacao,
    }),
  })

  const corpo = await resposta.text()
  if (!resposta.ok) throw new ErroDeCarregamento(resposta.status, corpo)

  const linha = JSON.parse(corpo) as { id?: string } | null
  if (linha === null || typeof linha.id !== 'string') {
    throw new ErroDeCarregamento(
      502,
      `registar_ficheiro não devolveu um ficheiro com id. Veio: ${corpo}`,
    )
  }
  return { id: linha.id }
}

/** O caminho completo, do pedido à resposta. */
export async function tratar(pedido: Request, amb: Ambiente): Promise<Response> {
  if (pedido.method !== 'POST') {
    return resposta(405, { erro: 'Só POST.' })
  }

  const autorizacao = pedido.headers.get('Authorization')
  if (autorizacao === null || !autorizacao.startsWith('Bearer ')) {
    return resposta(401, {
      erro: 'Falta o cabeçalho Authorization com o token da sessão. Esta função não regista nada em nome de ninguém.',
    })
  }

  try {
    const entrada = await lerEntrada(pedido)
    const sha = await sha256Hex(entrada.bytes)
    const caminho = caminhoDe(entrada.obraId, sha, entrada.mime)
    const reaproveitado = await guardarNoBalde(amb, caminho, entrada.bytes, entrada.mime)
    const ficheiro = await registarNaBase(amb, autorizacao, entrada, caminho, sha)

    return resposta(200, { ficheiro_id: ficheiro.id, sha256: sha, reaproveitado })
  } catch (causa) {
    if (causa instanceof ErroDeCarregamento) {
      // O corpo do PostgREST é JSON e vai inteiro; o resto é uma frase nossa.
      const corpo = tentarJson(causa.message)
      return resposta(causa.estado, corpo ?? { erro: causa.message })
    }
    // Nada é engolido: o que não se previu sobe como 500 com o texto do erro.
    return resposta(500, { erro: `Falha inesperada no carregamento: ${String(causa)}` })
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
