// Identidade do dispositivo e contador de sequência.
//
// Porque é que isto existe: marcar_item_fcq — e todas as funções que aceitam
// registos vindos de obra — exigem um p_dispositivo_id com pelo menos 8
// caracteres e uma p_sequencia única por dispositivo. A sequência é o travão
// (b) da coerência cronológica: uma numeração monótona por aparelho torna
// impossível enfiar um registo no meio de uma fila já sincronizada sem que isso
// se veja. Não elimina a fraude em telemóvel com root — encarece-a e deixa
// rasto.
//
// Guarda-se em localStorage porque tem de sobreviver a recarregar a página. Se
// recomeçasse do 1 a cada arranque, a segunda marcação do dia batia num PT409.

const CHAVE_ID = 'obrify.dispositivo.id'
const CHAVE_SEQUENCIA = 'obrify.dispositivo.sequencia'

export type RegistoDoDispositivo = {
  id: string
  sequencia: number
}

function novoDispositivo(): { id: string; sequencia: number } {
  // 'DISP-' mais um uuid: 41 caracteres, bem acima do mínimo de 8 que a
  // constraint exige.
  const id = `DISP-${crypto.randomUUID()}`
  localStorage.setItem(CHAVE_ID, id)
  localStorage.setItem(CHAVE_SEQUENCIA, '0')
  return { id, sequencia: 0 }
}

/**
 * Lê o dispositivo guardado, ou cria um novo.
 *
 * Qualquer inconsistência — id em falta, id curto de mais, contador ilegível,
 * um dos dois apagado sem o outro — dá um dispositivo NOVO, com id novo. Não é
 * a esconder um problema: um id novo significa um espaço de sequências novo,
 * portanto não há colisão possível com o que já foi enviado, e o registo
 * anterior continua no servidor atribuído ao id antigo. O que se perderia ao
 * tentar remendar era mais do que o que se ganha.
 */
function lerDispositivo(): { id: string; sequencia: number } {
  const id = localStorage.getItem(CHAVE_ID)
  const bruto = localStorage.getItem(CHAVE_SEQUENCIA)
  const sequencia = bruto === null ? Number.NaN : Number(bruto)

  if (id === null || id.length < 8) return novoDispositivo()
  if (!Number.isSafeInteger(sequencia) || sequencia < 0) return novoDispositivo()

  return { id, sequencia }
}

/** O id deste aparelho, estável entre sessões. */
export function idDoDispositivo(): string {
  return lerDispositivo().id
}

/**
 * Consome o número seguinte da sequência e grava-o antes de o devolver.
 *
 * Grava-se antes de a chamada ao servidor acontecer, de propósito: se a chamada
 * falhar, o número fica queimado e o seguinte é outro. Saltos na sequência não
 * têm mal nenhum — o servidor exige unicidade, não continuidade — e queimar é
 * mais seguro do que reaproveitar um número que talvez tenha chegado lá.
 */
export function proximaSequencia(): number {
  const dispositivo = lerDispositivo()
  const proxima = dispositivo.sequencia + 1
  localStorage.setItem(CHAVE_SEQUENCIA, String(proxima))
  return proxima
}

/** O par que as funções de serviço pedem, num só sítio. */
export function proximoRegisto(): RegistoDoDispositivo {
  return { id: idDoDispositivo(), sequencia: proximaSequencia() }
}
