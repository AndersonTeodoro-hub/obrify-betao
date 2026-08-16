// Leitura de campos de formulário sem coerção silenciosa.
//
// Vive num módulo próprio desde que passou a ser precisa em dois ecrãs — a
// submissão do PAB e o registo da guia. Duplicá-la era garantir que um dos
// lados corrigia um defeito e o outro não.

/** Um campo vazio não é zero. Foi um zero silencioso que fez o servidor
 *  recusar a primeira submissão de PAB com «o volume tem de ser maior do que
 *  zero» quando o campo estava, na verdade, por preencher. */
export type Numero =
  | { estado: 'vazio' }
  | { estado: 'invalido' }
  | { estado: 'ok'; valor: number }

/**
 * Aceita vírgula ou ponto como separador decimal. Em Portugal escreve-se 40,00,
 * e um <input type="number"> devolve string vazia quando não consegue
 * interpretar o que lá está — o que transformava «40,00» em zero. Por isso os
 * campos são type="text" com inputmode="decimal": o teclado do telemóvel
 * continua a ser o numérico, e a interpretação é nossa e explícita.
 *
 * Uma segunda vírgula ou ponto torna o número ambíguo — 1,000,50 pode ser mil e
 * meio ou um vírgula zero — e nesse caso recusa-se em vez de adivinhar.
 */
export function lerNumero(texto: string): Numero {
  const limpo = texto.trim().replace(',', '.')
  if (limpo === '') return { estado: 'vazio' }
  const valor = Number(limpo)
  return Number.isFinite(valor) ? { estado: 'ok', valor } : { estado: 'invalido' }
}

/** Texto em branco é ausência, não uma linha com espaços. */
export function textoOuNulo(valor: string): string | null {
  const limpo = valor.trim()
  return limpo === '' ? null : limpo
}
