// Criação de contas pelo ADMIN.
//
// ── PORQUE É QUE ISTO NÃO É signUp NO BROWSER ───────────────────────────────
// signUp autentica quem acabou de ser criado: o ADMIN carregava em «criar
// empreiteiro» e a sessão dele passava a ser a do empreiteiro. Criar a conta de
// outra pessoa exige a Admin API do Auth, que só responde à chave de serviço —
// e essa nunca pode estar no browser.
//
// ── TRÊS CAMADAS, NÃO UMA ──────────────────────────────────────────────────
// 1. Aqui: confirma-se, com o JWT de quem chamou, que ele é ADMIN activo.
// 2. Auth: a conta é criada com a chave de serviço, que não sai daqui.
// 3. Base: registar_utilizador e atribuir_obra são chamadas COM O JWT DE QUEM
//    CHAMOU, e exigem ADMIN outra vez. Se a camada 1 falhasse, a 3 recusava.
//
// A camada 1 não é a que protege — é a que dá boa mensagem antes de se criar
// uma conta do Auth que depois ficasse órfã. Quem protege é a 3.

export type Ambiente = {
  url: string
  chaveServico: string
  chaveAnon: string
  buscar: typeof fetch
}

export class ErroDeCriacao extends Error {
  constructor(
    readonly estado: number,
    mensagem: string,
  ) {
    super(mensagem)
    this.name = 'ErroDeCriacao'
  }
}

export type Pedido = {
  email: string
  palavraPasse: string
  nome: string
  perfil: 'EMPREITEIRO' | 'FISCALIZACAO' | 'DIRETOR_QUALIDADE'
  obraId: string | null
}

const PERFIS = ['EMPREITEIRO', 'FISCALIZACAO', 'DIRETOR_QUALIDADE']
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function lerPedido(bruto: unknown): Pedido {
  const c = (bruto ?? {}) as Record<string, unknown>
  const email = String(c.email ?? '').trim()
  const palavraPasse = String(c.palavra_passe ?? '')
  const nome = String(c.nome ?? '').trim()
  const perfil = String(c.perfil ?? '')
  const obraId = c.obra_id === null || c.obra_id === undefined ? null : String(c.obra_id)

  if (!email.includes('@')) throw new ErroDeCriacao(400, `Email inválido: "${email}".`)
  // O mínimo do Supabase Auth é 6. Aqui exige-se mais: esta palavra-passe vai
  // por mensagem para outra pessoa e é a primeira que ela usa.
  if (palavraPasse.length < 10) {
    throw new ErroDeCriacao(400, 'A palavra-passe inicial tem de ter pelo menos 10 caracteres.')
  }
  if (nome.length < 3) throw new ErroDeCriacao(400, 'Indique o nome completo de quem vai usar a conta.')
  if (!PERFIS.includes(perfil)) {
    throw new ErroDeCriacao(400, `Perfil não aceite: "${perfil}". Aceita-se ${PERFIS.join(', ')}.`)
  }
  // ADMIN não se cria por aqui de propósito: quem administra a organização
  // nasce com ela, no criar_organizacao, e multiplicar administradores por um
  // formulário é como se perde a conta de quem manda.
  if (obraId !== null && !UUID.test(obraId)) {
    throw new ErroDeCriacao(400, `obra_id não é um UUID: "${obraId}".`)
  }

  return { email, palavraPasse, nome, perfil: perfil as Pedido['perfil'], obraId }
}

/** Chama uma função de serviço com o JWT de quem pediu. O erro do PostgREST
 *  sobe tal e qual — código e corpo. */
async function rpc(
  amb: Ambiente,
  autorizacao: string,
  nome: string,
  argumentos: Record<string, unknown>,
): Promise<unknown> {
  const resposta = await amb.buscar(`${amb.url}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: {
      apikey: amb.chaveAnon,
      Authorization: autorizacao,
      'Content-Type': 'application/json',
      'Content-Profile': 'betonagens',
      Accept: 'application/json',
    },
    body: JSON.stringify(argumentos),
  })
  const corpo = await resposta.text()
  if (!resposta.ok) throw new ErroDeCriacao(resposta.status, corpo)
  return corpo === '' ? null : JSON.parse(corpo)
}

/** Confirma que quem chamou é ADMIN activo. Lê com o JWT dele, portanto a RLS
 *  aplica-se — não há aqui privilégio nenhum a ser emprestado. */
export async function exigirAdmin(amb: Ambiente, autorizacao: string): Promise<void> {
  const resposta = await amb.buscar(
    `${amb.url}/rest/v1/utilizador?select=perfil,ativo`,
    {
      headers: {
        apikey: amb.chaveAnon,
        Authorization: autorizacao,
        'Accept-Profile': 'betonagens',
        Accept: 'application/json',
      },
    },
  )
  if (!resposta.ok) {
    throw new ErroDeCriacao(resposta.status, await resposta.text())
  }
  const linhas = (await resposta.json()) as { perfil: string; ativo: boolean }[]
  // A RLS devolve as linhas visíveis; a de quem chama está entre elas. Se
  // nenhuma for ADMIN activa, não é ADMIN.
  if (!linhas.some((l) => l.perfil === 'ADMIN' && l.ativo)) {
    throw new ErroDeCriacao(403, 'Só o ADMIN cria contas.')
  }
}

export async function criarNoAuth(amb: Ambiente, pedido: Pedido): Promise<string> {
  const resposta = await amb.buscar(`${amb.url}/auth/v1/admin/users`, {
    method: 'POST',
    headers: {
      apikey: amb.chaveServico,
      Authorization: `Bearer ${amb.chaveServico}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      email: pedido.email,
      password: pedido.palavraPasse,
      // Confirmado à nascença: quem cria a conta é o ADMIN, e mandar um email
      // de confirmação para uma caixa de empresa que ninguém abre deixaria a
      // conta por activar sem ninguém perceber porquê.
      email_confirm: true,
    }),
  })

  const corpo = await resposta.text()
  if (!resposta.ok) throw new ErroDeCriacao(resposta.status, corpo)

  const utilizador = JSON.parse(corpo) as { id?: string }
  if (typeof utilizador.id !== 'string') {
    throw new ErroDeCriacao(502, `O Auth não devolveu um utilizador com id. Veio: ${corpo}`)
  }
  return utilizador.id
}

export async function tratar(pedidoHttp: Request, amb: Ambiente): Promise<Response> {
  if (pedidoHttp.method !== 'POST') return resposta(405, { erro: 'Só POST.' })

  const autorizacao = pedidoHttp.headers.get('Authorization')
  if (autorizacao === null || !autorizacao.startsWith('Bearer ')) {
    return resposta(401, { erro: 'Falta o cabeçalho Authorization com o token da sessão.' })
  }

  try {
    const pedido = lerPedido(await pedidoHttp.json())
    await exigirAdmin(amb, autorizacao)

    const authUserId = await criarNoAuth(amb, pedido)

    // A partir daqui a conta do Auth existe. Se o registo na base falhar, a
    // conta fica sem utilizador de domínio — o que não é perigoso (não vê nem
    // faz nada) mas tem de ser dito, e é.
    let novo: { id?: string } | null = null
    try {
      novo = (await rpc(amb, autorizacao, 'registar_utilizador', {
        p_auth_user_id: authUserId,
        p_nome: pedido.nome,
        p_email: pedido.email,
        p_perfil: pedido.perfil,
      })) as { id?: string } | null
    } catch (causa) {
      const detalhe = causa instanceof ErroDeCriacao ? causa.message : String(causa)
      throw new ErroDeCriacao(
        causa instanceof ErroDeCriacao ? causa.estado : 500,
        `A conta ${pedido.email} foi criada no Auth (${authUserId}) mas o registo na base falhou: ` +
          `${detalhe} — a conta existe e não tem acesso a nada. Trate-a antes de repetir.`,
      )
    }

    // O registar_utilizador devolve a linha criada: o id vem de lá, não de uma
    // segunda pergunta à base.
    if (typeof novo?.id !== 'string') {
      throw new ErroDeCriacao(
        502,
        `registar_utilizador não devolveu o utilizador criado para ${pedido.email}.`,
      )
    }

    if (pedido.obraId !== null) {
      await rpc(amb, autorizacao, 'atribuir_obra', {
        p_utilizador_id: novo.id,
        p_obra_id: pedido.obraId,
      })
    }

    return resposta(200, { auth_user_id: authUserId, utilizador_id: novo.id })
  } catch (causa) {
    if (causa instanceof ErroDeCriacao) {
      const corpo = tentarJson(causa.message)
      return resposta(causa.estado, corpo ?? { erro: causa.message })
    }
    return resposta(500, { erro: `Falha inesperada na criação da conta: ${String(causa)}` })
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
