// Sessão e identidade.
//
// Há duas identidades e não são a mesma: o utilizador do Supabase Auth, que é
// quem tem o JWT, e o utilizador de domínio em betonagens.utilizador, que é
// quem tem perfil, organização e acessos a obras. A ligação entre os dois é a
// coluna auth_user_id — a mesma que a função betonagens_priv.identidade_externa()
// lê do lado do servidor.
//
// Uma sessão válida sem utilizador de domínio correspondente é um estado
// possível e tem de ser dito em voz alta: as funções de serviço recusam-na com
// PT403 e a aplicação não deve fingir que está tudo bem.

import { betonagens, cliente } from './supabase'

export type Perfil = 'EMPREITEIRO' | 'FISCALIZACAO' | 'DIRETOR_QUALIDADE' | 'ADMIN'

export type UtilizadorDeDominio = {
  id: string
  organizacao_id: string
  nome: string
  email: string
  perfil: Perfil
  ativo: boolean
}

export async function entrar(email: string, palavraPasse: string): Promise<void> {
  const { error } = await cliente.auth.signInWithPassword({
    email,
    password: palavraPasse,
  })
  if (error) throw error
}

/**
 * Cria a conta de quem se está a registar — só a do Auth.
 *
 * Não cria utilizador de domínio nenhum: isso é o registar_com_codigo, a
 * seguir. Uma conta do Auth sem utilizador de domínio não vê nem faz nada —
 * todas as funções de serviço recusam com PT403 e a RLS não devolve linha
 * nenhuma. É por isso que este passo pode ser aberto.
 *
 * Devolve se a sessão ficou logo iniciada. Com a confirmação de email ligada no
 * painel do Supabase, não fica: é preciso confirmar a caixa de correio antes de
 * poder apresentar o código.
 */
export async function criarConta(email: string, palavraPasse: string): Promise<boolean> {
  const { data, error } = await cliente.auth.signUp({ email, password: palavraPasse })
  if (error) throw error
  return data.session !== null
}

export async function sair(): Promise<void> {
  const { error } = await cliente.auth.signOut()
  if (error) throw error
}

/** Id do utilizador do Auth, ou null se não houver sessão. */
export async function identidadeExterna(): Promise<string | null> {
  const { data, error } = await cliente.auth.getSession()
  if (error) throw error
  return data.session?.user.id ?? null
}

/** Sem sessão, com sessão por ligar a um utilizador, ou ligada. */
export type EstadoDaSessao =
  | { estado: 'anonima' }
  | { estado: 'por-registar'; authUserId: string }
  | { estado: 'pronta'; utilizador: UtilizadorDeDominio }

/**
 * O estado da sessão actual.
 *
 * Uma sessão autenticada sem utilizador de domínio deixou de ser um erro para
 * passar a ser um ESTADO: é exactamente quem acabou de criar a conta e ainda
 * não apresentou o código de registo. Continua a não ver nem fazer nada — o que
 * mudou foi haver um sítio para onde o mandar.
 */
export async function estadoDaSessao(): Promise<EstadoDaSessao> {
  const authUserId = await identidadeExterna()
  if (authUserId === null) return { estado: 'anonima' }

  const { data, error } = await betonagens()
    .from('utilizador')
    .select('id, organizacao_id, nome, email, perfil, ativo')
    .eq('auth_user_id', authUserId)
    .maybeSingle()

  if (error) throw error
  if (data === null) return { estado: 'por-registar', authUserId }

  return { estado: 'pronta', utilizador: data as UtilizadorDeDominio }
}

/**
 * Liga a conta autenticada a um utilizador de domínio, apresentando o código.
 *
 * O email não vai daqui: a função de serviço lê-o do JWT. Aceitá-lo como
 * parâmetro deixaria alguém registar-se com o email de outra pessoa.
 */
export async function registarComCodigo(codigo: string, nome: string): Promise<void> {
  const { error } = await betonagens().rpc('registar_com_codigo', {
    p_codigo: codigo,
    p_nome: nome,
  })
  if (error) throw error
}
