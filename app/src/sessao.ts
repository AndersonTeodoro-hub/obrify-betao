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

/**
 * O utilizador de domínio da sessão actual.
 * Devolve null quando não há sessão, e lança quando há sessão mas a identidade
 * não está ligada a nenhum utilizador — que é um erro de configuração, não um
 * estado normal, e não se cala.
 */
export async function utilizadorDeDominio(): Promise<UtilizadorDeDominio | null> {
  const authUserId = await identidadeExterna()
  if (authUserId === null) return null

  const { data, error } = await betonagens()
    .from('utilizador')
    .select('id, organizacao_id, nome, email, perfil, ativo')
    .eq('auth_user_id', authUserId)
    .maybeSingle()

  if (error) throw error

  if (data === null) {
    throw new Error(
      `A sessão está autenticada (${authUserId}) mas não há utilizador de domínio ` +
        'ligado a esta identidade. Falta criar a organização e o administrador — ' +
        'ver betonagens.criar_organizacao no SQL Editor.',
    )
  }

  return data as UtilizadorDeDominio
}
