// Cliente único do Supabase.
//
// O schema do domínio é `betonagens`, não `public`. Toda a leitura e toda a
// chamada de função têm de o dizer, através dos cabeçalhos Accept-Profile e
// Content-Profile — que é o que o .schema() faz. Se alguém esquecer, o pedido
// bate em `public`, onde não existe nada, e o erro é confuso.
//
// Por isso o nome do schema aparece UMA vez em todo o frontend: aqui. Nenhum
// ecrã importa `cliente` para ler ou escrever domínio; importa `betonagens()`.

import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const chaveAnonima = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!url || !chaveAnonima) {
  throw new Error(
    'Faltam VITE_SUPABASE_URL ou VITE_SUPABASE_ANON_KEY. ' +
      'Copia app/.env.example para app/.env.local e preenche os dois valores.',
  )
}

/** Sessão, autenticação, e mais nada. Não serve para ler nem escrever domínio. */
export const cliente = createClient(url, chaveAnonima, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
})

/** A única porta para o schema betonagens. */
export const betonagens = () => cliente.schema('betonagens')
