// Todas as leituras e todas as chamadas de função de serviço deste fluxo, num
// sítio só. Os ecrãs desenham; este ficheiro fala com a base de dados.
//
// Nenhuma destas funções escreve numa tabela: as escritas passam todas por
// betonagens.<função>, que é a camada de serviço. O papel `authenticated` não
// tem INSERT, UPDATE nem DELETE em tabela nenhuma do domínio — se um dia uma
// escrita daqui funcionar sem rpc, é incidente.

import { proximoRegisto } from './dispositivo'
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

// ── ficha I.CR.033 ──────────────────────────────────────────────────────────

export type SeccaoFcq =
  | 'implantacao'
  | 'cofragem'
  | 'armaduras'
  | 'juntas'
  | 'betonagem'
  | 'pos_betonagem'

export type ValorFcq = 'C' | 'NC' | 'NA'

/** As três que o gate de aprovação do PAB exige assinadas. Juntas fica de fora
 *  por decisão de campo: uma junta de betonagem nasce durante o processo e o
 *  corte e a selagem são posteriores. */
export const SECCOES_PRE_BETONAGEM: SeccaoFcq[] = ['implantacao', 'cofragem', 'armaduras']

export const NOME_DA_SECCAO: Record<SeccaoFcq, string> = {
  implantacao: 'Implantação',
  cofragem: 'Cofragem',
  armaduras: 'Armaduras',
  juntas: 'Juntas',
  betonagem: 'Betonagem',
  pos_betonagem: 'Pós-betonagem',
}

export type Ficha = {
  id: string
  numero: string
  estado: 'RASCUNHO' | 'EMITIDA'
  modelo_impresso_id: string
}

export type LinhaFicha = {
  codigo: string
  seccao: SeccaoFcq
  criterio: string
  ordem: number
}

export type ItemFicha = {
  linha_codigo: string
  valor: ValorFcq
  anotacao: string | null
}

export type EstadoSeccao = {
  seccao: SeccaoFcq
  linhas_da_seccao: number
  itens_preenchidos: number
  itens_nao_conformes: number
  assinada: boolean
  nome_impresso: string | null
  /** Relógio do servidor, não o declarado pelo dispositivo. */
  assinado_em: string | null
  /**
   * A assinatura ainda cobre os itens que existem agora.
   *
   * Não é uma bandeira que alguém escreve: a vista compara o hash dos itens
   * guardado na assinatura com o hash recalculado no momento da leitura. Se um
   * item for corrigido depois de assinado, isto passa a falso sozinho — e o
   * gate de aprovação recusa com a mesma verificação.
   */
  em_vigor: boolean
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

/** Uma medição do desvio do relógio, acompanhada do que ela própria diz valer. */
type Medida = {
  /** Desvio em ms. Positivo = máquina atrasada; negativo = adiantada. */
  deriva: number
  /** Limite superior do erro desta medição, em ms: metade da viagem mais curta. */
  incerteza: number
  /** Date.now() local em que foi feita — é por aqui que se sabe quando caduca. */
  feitaEm: number
}

/** Viagens por medição. Fica a mais curta, porque é a que menos assimetria
 *  entre ida e volta pode esconder, e é a assimetria que produz o erro. */
const VIAGENS_POR_MEDICAO = 3

/** Ao fim de quanto tempo uma medição deixa de valer. É o único número deste
 *  bloco que é escolhido em vez de medido: um relógio não está apenas
 *  desacertado, anda a ritmo diferente, e essa diferença acumula enquanto a
 *  sessão dura. */
const VALIDADE_DA_MEDICAO_MS = 5 * 60 * 1000

let medida: Medida | null = null
let medicao: Promise<Medida> | null = null

/**
 * Uma viagem a betonagens.agora(), que devolve o now() do servidor — o mesmo
 * instante com que as funções de serviço comparam o momento declarado. O
 * cabeçalho Date do HTTP não serve: não é da lista segura do CORS e o Supabase
 * não o expõe, portanto do browser vem sempre null.
 *
 * A deriva é estimada pelo ponto médio da viagem, o que assume que a ida e a
 * volta demoram o mesmo. Quando não demoram, o erro é metade da diferença —
 * limitado, portanto, por metade da viagem, que é devolvida com ela.
 */
async function umaViagem(): Promise<{ deriva: number; viagem: number }> {
  const antes = Date.now()
  const { data, error } = await betonagens().rpc('agora')
  const depois = Date.now()
  if (error) throw error

  const servidor = new Date(String(data)).getTime()
  if (!Number.isFinite(servidor)) {
    throw new Error(`betonagens.agora() devolveu uma hora ilegível: ${String(data)}`)
  }
  return { deriva: servidor - (antes + depois) / 2, viagem: depois - antes }
}

/**
 * O desvio do relógio desta máquina, medido em várias viagens seguidas.
 *
 * Seguidas e não em paralelo de propósito: pedidos simultâneos disputam a
 * mesma ligação e inflacionam-se uns aos outros, e o que aqui interessa é
 * apanhar uma viagem genuinamente curta.
 *
 * Qualquer viagem que falhe faz falhar a medição inteira. É deliberado: uma
 * medição feita com as sobras de uma rede que está a falhar não vale mais do
 * que nenhuma, e quem chamou tem de o saber.
 */
async function medirDeriva(): Promise<Medida> {
  let melhor = await umaViagem()
  for (let i = 1; i < VIAGENS_POR_MEDICAO; i++) {
    const outra = await umaViagem()
    if (outra.viagem < melhor.viagem) melhor = outra
  }
  return { deriva: melhor.deriva, incerteza: melhor.viagem / 2, feitaEm: Date.now() }
}

/**
 * O instante que o dispositivo declara, corrigido da deriva medida e recuado
 * da incerteza dessa medição.
 *
 * Continua a ser metadado — o servidor grava o seu próprio relógio em separado
 * e a divergência entre os dois é, por si só, um sinal de risco. O que a
 * correcção evita é a recusa de registos legítimos: as funções de serviço
 * rejeitam com PT422 qualquer momento à frente do relógio do servidor, sem
 * margem nenhuma.
 *
 * Apontar ao relógio do servidor não chega, e foi isso que produziu o PT422 a
 * meio do preenchimento de uma ficha: a folga que sobrava era só a latência de
 * ida de cada chamada, e bastava o erro da medição ser maior do que ela para a
 * folga ficar negativa. Daí a subtracção da incerteza — que não é uma margem
 * inventada, é o limite superior do erro da própria medição, medido com ela.
 *
 * Se a medição falhar, esta função ATIRA em vez de assumir zero. Assumir zero
 * seria devolver ao utilizador o mesmo PT422 incompreensível que nos trouxe
 * aqui; assim, quem não conseguir acertar o relógio sabe-o e sabe porquê.
 */
export async function agoraDeclarado(): Promise<string> {
  let actual = medida
  if (actual === null || Date.now() - actual.feitaEm > VALIDADE_DA_MEDICAO_MS) {
    medicao ??= medirDeriva()
    try {
      actual = await medicao
    } catch (causa) {
      medicao = null // a próxima tentativa volta a medir
      throw new Error(
        'Não foi possível acertar o relógio com o servidor, e sem isso o registo ' +
          `seria recusado. ${mensagemDeErro(causa)}`,
      )
    }
    medicao = null
    medida = actual
  }
  return new Date(Date.now() + actual.deriva - actual.incerteza).toISOString()
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

// ── ficha I.CR.033 ──────────────────────────────────────────────────────────

/** A ficha nasce com o PAB, 1:1, na submissão. Não existir é impossível. */
export async function lerFicha(pabId: string): Promise<Ficha> {
  const { data, error } = await betonagens()
    .from('fcq')
    .select('id, numero, estado, modelo_impresso_id')
    .eq('pab_id', pabId)
    .maybeSingle()
  if (error) throw error
  if (data === null) {
    throw new Error(
      `O PAB ${pabId} não tem ficha associada. A ficha é criada pelo submeter_pab, ` +
        'na mesma transação — isto não devia poder acontecer.',
    )
  }
  return data as Ficha
}

/**
 * Os 20 critérios pré-betonagem, na ordem do impresso.
 *
 * Vêm de betonagens.fcq_linha, que a 0010 derivou do mapa_campos.json do
 * I.CR.033 — não estão escritos nesta aplicação. Se a DDN revir o impresso, é
 * uma revisão nova do modelo e as fichas antigas continuam a ler a sua.
 */
export async function lerLinhasPreBetonagem(modeloImpressoId: string): Promise<LinhaFicha[]> {
  const { data, error } = await betonagens()
    .from('fcq_linha')
    .select('codigo, seccao, criterio, ordem')
    .eq('modelo_impresso_id', modeloImpressoId)
    .in('seccao', SECCOES_PRE_BETONAGEM)
    .order('ordem')
  if (error) throw error
  return (data ?? []) as LinhaFicha[]
}

/** O que está marcado na coluna de inspeção, e só o que está em vigor. */
export async function lerItensInspecao(fcqId: string): Promise<ItemFicha[]> {
  const { data, error } = await betonagens()
    .from('fcq_item')
    .select('linha_codigo, valor, anotacao')
    .eq('fcq_id', fcqId)
    .eq('coluna', 'insp')
    .is('substituido_por_id', null)
  if (error) throw error
  return (data ?? []) as ItemFicha[]
}

/**
 * O progresso por secção, lido da vista betonagens.fcq_seccao_estado.
 *
 * Podia contar-se do lado do cliente a partir dos itens, mas é a vista que o
 * servidor usa para decidir se uma secção está completa e se a assinatura
 * continua em vigor. Ler a mesma fonte evita que o ecrã diga uma coisa e o gate
 * de aprovação decida outra.
 */
export async function lerEstadoSeccoes(fcqId: string): Promise<EstadoSeccao[]> {
  const { data, error } = await betonagens()
    .from('fcq_seccao_estado')
    .select('seccao, linhas_da_seccao, itens_preenchidos, itens_nao_conformes, assinada, nome_impresso, assinado_em, em_vigor')
    .eq('fcq_id', fcqId)
    .eq('coluna', 'insp')
  if (error) throw error
  return (data ?? []) as EstadoSeccao[]
}

/**
 * Marca um critério. Um de cada vez — não existe «marcar tudo conforme», nem
 * aqui nem no servidor, e é dos poucos sítios onde a fricção é o objectivo.
 *
 * Cada item leva o seu momento e a sua posição na sequência do aparelho. É isso
 * que torna detectável uma ficha preenchida de uma assentada, no gabinete, na
 * véspera.
 */
export async function marcarItem(
  fcqId: string,
  linhaCodigo: string,
  valor: ValorFcq,
  anotacao: string | null,
): Promise<void> {
  // O relógio primeiro: se a medição falhar, não se queima um número da
  // sequência à toa.
  const momento = await agoraDeclarado()
  const dispositivo = proximoRegisto()

  const { error } = await betonagens().rpc('marcar_item_fcq', {
    // uuid v4. O v7 que decidimos para os registos nascidos no dispositivo
    // entra com a fila offline, onde serve também de chave de idempotência;
    // aqui não há fila e a fragmentação de índice a esta escala não se mede.
    p_id: crypto.randomUUID(),
    p_fcq_id: fcqId,
    p_linha_codigo: linhaCodigo,
    p_coluna: 'insp',
    p_valor: valor,
    p_momento_declarado: momento,
    p_dispositivo_id: dispositivo.id,
    p_sequencia: dispositivo.sequencia,
    p_anotacao: anotacao,
  })
  if (error) throw error
}

/**
 * Assina uma secção na coluna de inspeção.
 *
 * A assinatura guarda o hash dos itens que cobre. É por isso que não é um
 * carimbo: se um item for corrigido depois, o hash deixa de bater e a
 * assinatura cai — sem ninguém lhe tocar, e sem ninguém a poder apagar.
 *
 * Não se passa motivo de reassinatura: reassinar está fora deste âmbito, e uma
 * segunda tentativa há-de ser recusada pelo servidor com a razão escrita.
 */
export async function assinarSeccao(fcqId: string, seccao: SeccaoFcq): Promise<void> {
  const momento = await agoraDeclarado()
  const dispositivo = proximoRegisto()

  const { error } = await betonagens().rpc('assinar_seccao_fcq', {
    p_fcq_id: fcqId,
    p_seccao: seccao,
    p_coluna: 'insp',
    p_momento_declarado: momento,
    p_dispositivo_id: dispositivo.id,
    p_sequencia: dispositivo.sequencia,
  })
  if (error) throw error
}

/**
 * Aprova o PAB, e devolve o estado que o servidor confirmou.
 *
 * O gate vive todo do lado do servidor — secções assinadas, assinaturas em
 * vigor, cronologia, não conformidades por reinspecionar, R6 na frente — e não
 * se repete aqui. Duplicá-lo no cliente daria duas versões da regra, e a
 * primeira a divergir seria a que o utilizador vê. Quando o gate recusa, o que
 * aparece no ecrã é a frase do servidor.
 *
 * Não se passa justificação de R6: levantar a R6 está fora deste âmbito, e sem
 * ela o servidor recusa e diz porquê.
 */
export async function aprovarPab(pabId: string): Promise<EstadoPab> {
  const momento = await agoraDeclarado()
  const dispositivo = proximoRegisto()

  const { data, error } = await betonagens().rpc('aprovar_pab', {
    p_pab_id: pabId,
    p_momento_declarado: momento,
    p_dispositivo_id: dispositivo.id,
    p_sequencia: dispositivo.sequencia,
  })
  if (error) throw error

  const estado = (data as Pab | null)?.estado
  if (estado === undefined) {
    throw new Error(
      'A aprovação não devolveu o PAB, e sem isso não há como confirmar em que estado ficou. ' +
        'Recarregue antes de repetir.',
    )
  }
  return estado
}
