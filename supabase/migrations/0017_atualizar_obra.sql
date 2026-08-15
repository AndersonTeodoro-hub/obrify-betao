-- =============================================================================
-- 0017_atualizar_obra.sql · Obrify Betão
--
-- betonagens.atualizar_obra — corrigir o cabeçalho do impresso de uma obra.
--
-- ── PORQUÊ ──────────────────────────────────────────────────────────────────
-- O topo de cada PAB imprime dono de obra, adjudicatário e fiscalização. As
-- colunas existem desde a 0002 e o criar_obra sempre as aceitou, mas o cliente
-- nunca as enviou — as obras criadas até agora têm-nas a nulo e o impresso sai
-- com três travessões. Sem uma função de actualização não há maneira nenhuma de
-- as preencher: a obra não se apaga (obra_sem_delete) e recriar a obra
-- perderia os PAB que dependem dela.
--
-- ── O CÓDIGO NÃO SE MUDA ────────────────────────────────────────────────────
-- p_codigo não existe nesta função, e é de propósito. O código é a identidade
-- da obra: é único por organização, é o que o fiscal lê na lista, é o que o
-- impresso imprime como «Obra n.º», e é a referência com que a obra é falada
-- fora da plataforma. Um identificador que muda deixa de identificar. Para
-- mudar um código, cria-se outra obra.
--
-- ── SUBSTITUI, NÃO FUNDE ────────────────────────────────────────────────────
-- Os quatro campos são escritos com o que vier. Passar nulo em dono_obra
-- APAGA o dono de obra; não quer dizer «deixa ficar como está». É a semântica
-- honesta para um formulário que mostra os valores actuais e devolve o que lá
-- ficou — a alternativa, coalesce, tornaria impossível limpar um campo mal
-- preenchido, e num sistema onde nada se apaga isso seria um erro para sempre.
-- Quem chamar esta função tem de enviar o estado completo dos quatro campos.
--
-- ── O QUE FICA REGISTADO ────────────────────────────────────────────────────
-- betonagens.obra tem gatilho obra_ledger em INSERT OR UPDATE, que grava
-- {antes, depois} na cadeia de hash da organização. Uma correcção de cabeçalho
-- não desaparece: fica com autor, momento e valores antigos, como tudo o resto.
--
-- Termina com o revoke da convenção fixada pela 0015.
--
-- Depende de: 0016.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0017_atualizar_obra.sql') then
    raise exception 'A migração 0017_atualizar_obra.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

create function betonagens.atualizar_obra(
  p_obra_id      uuid,
  p_designacao   text,
  p_dono_obra    text default null,
  p_empreiteiro  text default null,
  p_fiscalizacao text default null
)
returns betonagens.obra
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor betonagens.utilizador := betonagens_priv.exigir_actor();
  v_obra  betonagens.obra;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'ADMIN'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  if p_obra_id is null then
    raise exception 'Falta a obra a actualizar.' using errcode = 'PT422';
  end if;

  -- A existência primeiro: sem isto, um id inexistente vinha com a mensagem
  -- «não pertence à organização», que aponta para o lado errado.
  select * into v_obra from betonagens.obra o where o.id = p_obra_id for update;
  if not found then
    raise exception 'A obra % não existe.', p_obra_id using errcode = 'PT422';
  end if;

  perform betonagens_priv.exigir_acesso_obra(v_actor, p_obra_id);

  if p_designacao is null or length(btrim(p_designacao)) < 3 then
    raise exception 'A designação da obra é obrigatória e tem de ter pelo menos 3 caracteres.'
      using errcode = 'PT422';
  end if;

  -- Espaços em branco não são um valor: passam a nulo, para o impresso
  -- distinguir «não indicado» de uma linha com espaços.
  update betonagens.obra
     set designacao   = btrim(p_designacao),
         dono_obra    = nullif(btrim(coalesce(p_dono_obra, '')), ''),
         empreiteiro  = nullif(btrim(coalesce(p_empreiteiro, '')), ''),
         fiscalizacao = nullif(btrim(coalesce(p_fiscalizacao, '')), '')
   where id = p_obra_id
  returning * into v_obra;

  return v_obra;
end
$fn$;

comment on function betonagens.atualizar_obra(uuid, text, text, text, text) is
  'Substitui designação e cabeçalho do impresso. Não toca no código, que é identidade. Nulo apaga o campo — não é "deixar como está".';

reset role;

grant execute on function betonagens.atualizar_obra(uuid, text, text, text, text) to authenticated;

-- ── convenção fixada pela 0015 ──────────────────────────────────────────────
-- Toda a migração que cria funções termina aqui. É seguro repetir: só remove
-- as entradas do PUBLIC; as concessões a papéis nomeados ficam intactas.
set role betonagens_servico;
revoke execute on all routines in schema betonagens, betonagens_priv from public;
reset role;

insert into betonagens.migracao (ficheiro) values ('0017_atualizar_obra.sql');
