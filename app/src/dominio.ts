// Todas as leituras e todas as chamadas de função de serviço deste fluxo, num
// sítio só. Os ecrãs desenham; este ficheiro fala com a base de dados.
//
// Nenhuma destas funções escreve numa tabela: as escritas passam todas por
// betonagens.<função>, que é a camada de serviço. O papel `authenticated` não
// tem INSERT, UPDATE nem DELETE em tabela nenhuma do domínio — se um dia uma
// escrita daqui funcionar sem rpc, é incidente.

import { betonagens } from './supabase'

// ── erros ───────────────────────────────────────────────────────────────────

/**
 * O que o servidor disse, legível, sem perder nada pelo caminho.
 *
 * O supabase-js só constrói um PostgrestError — que é uma Error a sério —
 * quando se usa .throwOnError(). No caminho normal, o `error` devolvido é o
 * resultado directo de JSON.parse sobre o corpo da resposta: um objecto simples
 * com message, details, hint e code. Um teste `instanceof Error` falha nele, e
 * String(objecto) dá "[object Object]" — que foi como se perdeu a primeira
 * recusa do servidor e se ficou a depurar às cegas.
 *
 * Aqui sai tudo o que veio, uma linha por campo. O .erro do CSS tem
 * white-space: pre-wrap, portanto as quebras aparecem.
 */
export function mensagemDeErro(causa: unknown): string {
  if (typeof causa === 'string') return causa
  if (causa === null || causa === undefined) return 'Erro sem mensagem.'
  if (typeof causa !== 'object') return String(causa)

  const campos = causa as Record<string, unknown>
  const texto = (chave: string): string | null => {
    const valor = campos[chave]
    return typeof valor === 'string' && valor.trim() !== '' ? valor : null
  }

  const linhas: string[] = [texto('message') ?? 'Erro sem mensagem legível.']
  const detalhe = texto('details')
  const sugestao = texto('hint')
  const codigo = texto('code')
  if (detalhe !== null) linhas.push(`detalhe: ${detalhe}`)
  if (sugestao !== null) linhas.push(`sugestão: ${sugestao}`)
  if (codigo !== null) linhas.push(`código: ${codigo}`)

  return linhas.join('\n')
}

// ── tipos ───────────────────────────────────────────────────────────────────

export type Obra = {
  id: string
  codigo: string
  designacao: string
  ativa: boolean
}

export type Frente = {
  id: string
  designacao: string
  ativa: boolean
}

export type EstadoPab =
  | 'SUBMETIDO'
  | 'APROVADO'
  | 'EM_BETONAGEM'
  | 'BETONADO'
  | 'FCQ_FECHADA'
  | 'REJEITADO'
  | 'ANULADO'

export type Pab = {
  id: string
  numero: number
  frente_id: string
  elemento: string
  volume_previsto_m3: number
  classe_betao: string
  classe_exposicao: string | null
  dmax_agregado_mm: number | null
  classe_consistencia: string | null
  data_pedido: string
  data_prevista: string
  estado: EstadoPab
}

export type NovoPab = {
  obraId: string
  frenteId: string
  elemento: string
  volumePrevistoM3: number
  classeBetao: string
  dataPedido: string
  dataPrevista: string
  classeExposicao: string | null
  dmaxAgregadoMm: number | null
  classeConsistencia: string | null
}

// ── relógio ─────────────────────────────────────────────────────────────────

let derivaMs: number | null = null
let medicao: Promise<number> | null = null

/**
 * Quanto é que o relógio desta máquina difere do da base de dados, em
 * milissegundos. Positivo = máquina atrasada; negativo = adiantada.
 *
 * Mede-se contra betonagens.agora(), que devolve o now() do servidor — o mesmo
 * instante com que as funções de serviço comparam o momento declarado. O
 * cabeçalho Date do HTTP não serve: não é da lista segura do CORS e o Supabase
 * não o expõe, portanto do browser vem sempre null.
 */
async function medirDeriva(): Promise<number> {
  const antes = Date.now()
  const { data, error } = await betonagens().rpc('agora')
  const depois = Date.now()
  if (error) throw error

  const servidor = new Date(String(data)).getTime()
  if (!Number.isFinite(servidor)) {
    throw new Error(`betonagens.agora() devolveu uma hora ilegível: ${String(data)}`)
  }
  return servidor - (antes + depois) / 2
}

/**
 * O instante que o dispositivo declara, já corrigido da deriva medida.
 *
 * Continua a ser metadado — o servidor grava o seu próprio relógio em separado
 * e a divergência entre os dois é, por si só, um sinal de risco. O que a
 * correcção evita é a recusa de registos legítimos: as funções de serviço
 * rejeitam com PT422 qualquer momento à frente do relógio do servidor, sem
 * margem nenhuma, e nesta máquina bastaram 339 ms de avanço para a primeira
 * submissão de PAB ser recusada.
 *
 * Não há margem fixa inventada: aplica-se a diferença medida, e mais nada.
 *
 * Se a medição falhar, esta função ATIRA em vez de assumir zero. Assumir zero
 * seria devolver ao utilizador o mesmo PT422 incompreensível que nos trouxe
 * aqui; assim, quem não conseguir acertar o relógio sabe-o e sabe porquê.
 */
export async function agoraDeclarado(): Promise<string> {
  let deriva = derivaMs
  if (deriva === null) {
    medicao ??= medirDeriva()
    try {
      deriva = await medicao
    } catch (causa) {
      medicao = null // a próxima tentativa volta a medir
      throw new Error(
        'Não foi possível acertar o relógio com o servidor, e sem isso o registo ' +
          `seria recusado. ${mensagemDeErro(causa)}`,
      )
    }
    derivaMs = deriva
  }
  return new Date(Date.now() + deriva).toISOString()
}

// ── obras ───────────────────────────────────────────────────────────────────

export async function lerObras(): Promise<Obra[]> {
  const { data, error } = await betonagens()
    .from('obra')
    .select('id, codigo, designacao, ativa')
    .order('codigo')
  if (error) throw error
  return (data ?? []) as Obra[]
}

export async function criarObra(codigo: string, designacao: string): Promise<void> {
  const { error } = await betonagens().rpc('criar_obra', {
    p_codigo: codigo,
    p_designacao: designacao,
  })
  if (error) throw error
}

// ── frentes ─────────────────────────────────────────────────────────────────

export async function lerFrentes(obraId: string): Promise<Frente[]> {
  const { data, error } = await betonagens()
    .from('frente')
    .select('id, designacao, ativa')
    .eq('obra_id', obraId)
    .order('designacao')
  if (error) throw error
  return (data ?? []) as Frente[]
}

export async function criarFrente(obraId: string, designacao: string): Promise<void> {
  const { error } = await betonagens().rpc('criar_frente', {
    p_obra_id: obraId,
    p_designacao: designacao,
  })
  if (error) throw error
}

// ── pedidos de autorização de betonagem ─────────────────────────────────────

// O select tem de ser um literal numa linha só: o supabase-js infere o tipo do
// resultado a partir do texto, e uma concatenação transforma-o em string comum,
// o que faz o tipo cair para GenericStringError[].
export async function lerPabs(obraId: string): Promise<Pab[]> {
  const { data, error } = await betonagens()
    .from('pab')
    .select('id, numero, frente_id, elemento, volume_previsto_m3, classe_betao, classe_exposicao, dmax_agregado_mm, classe_consistencia, data_pedido, data_prevista, estado')
    .eq('obra_id', obraId)
    .order('numero', { ascending: false })
  if (error) throw error
  return (data ?? []) as Pab[]
}

/**
 * Submete o pedido. Do lado do servidor isto faz mais do que inserir uma linha:
 * atribui o número sequencial da obra sob bloqueio, e cria a ficha I.CR.033 em
 * rascunho, 1:1 com o PAB. É por a ficha nascer aqui que é possível exigir as
 * secções pré-betonagem assinadas antes da aprovação.
 */
export async function submeterPab(dados: NovoPab): Promise<void> {
  const { error } = await betonagens().rpc('submeter_pab', {
    p_obra_id: dados.obraId,
    p_frente_id: dados.frenteId,
    p_elemento: dados.elemento,
    p_volume_previsto_m3: dados.volumePrevistoM3,
    p_classe_betao: dados.classeBetao,
    p_data_pedido: dados.dataPedido,
    p_data_prevista: dados.dataPrevista,
    p_momento_declarado: await agoraDeclarado(),
    p_classe_exposicao: dados.classeExposicao,
    p_dmax_agregado_mm: dados.dmaxAgregadoMm,
    p_classe_consistencia: dados.classeConsistencia,
  })
  if (error) throw error
}
