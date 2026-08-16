-- =============================================================================
-- 0020_acessos.sql · Obrify Betão
--
-- Como é que um fiscal novo passa a existir, e o que é que ele vê.
--
-- ── O PROBLEMA ──────────────────────────────────────────────────────────────
-- Até aqui, criar um utilizador exigia um ADMIN a chamar registar_utilizador
-- com o auth_user_id já existente — ou seja, alguém tinha de criar a conta no
-- painel do Supabase e depois copiar o UUID para o SQL Editor. Para dezenas de
-- fiscais da DDN isso não escala e faz o ADMIN manusear identidades à mão.
--
-- ── A SOLUÇÃO, E O QUE ELA NÃO É ────────────────────────────────────────────
-- Um código de registo por organização. O fiscal cria a conta com o email e uma
-- palavra-passe dele, e apresenta o código. Nasce nominal, com perfil
-- FISCALIZACAO na organização do código.
--
-- O código NÃO é uma credencial de acesso. É uma carta de apresentação: sem
-- ele, uma conta do Auth não tem utilizador de domínio nenhum, e sem utilizador
-- de domínio todas as funções de serviço recusam com PT403 e a RLS não devolve
-- linha nenhuma. Uma conta assim não vê nem faz nada. O código só decide QUEM
-- entra, não O QUE pode fazer.
--
-- ── O QUE NÃO ESTÁ AQUI, E TEM DE SER DITO ──────────────────────────────────
-- Não há limite de tentativas. Quem tiver o código pode registar quantas contas
-- quiser até ele ser revogado ou expirar. Contra isso ficam três coisas: o
-- código expira, o ADMIN revoga-o num clique, e cada registo deixa nome, email
-- e momento no ledger — portanto uma conta a mais é visível, não silenciosa.
-- Um travão por tentativas exige contagem por IP, que não existe ao nível da
-- base. Fica registado como o que falta, não escondido.
--
-- ── EMPREITEIROS NÃO SE AUTO-REGISTAM ───────────────────────────────────────
-- Uma conta por empresa, criada pelo ADMIN. É deliberado: o empreiteiro submete
-- pedidos que comprometem a obra, e quem entra tem de ser decidido, não
-- convidado. Não há código para EMPREITEIRO e a função abaixo recusa-o.
--
-- ── A FISCALIZAÇÃO PASSA A VER A ORGANIZAÇÃO INTEIRA ────────────────────────
-- Decisão de hoje: um fiscal da DDN vê todas as obras da DDN, não só as que
-- alguém se lembrou de lhe atribuir. É como a casa funciona — a fiscalização é
-- da empresa, não do contrato. O empreiteiro continua preso às obras
-- atribuídas, que é o que impede a empresa A de ver a obra da empresa B.
--
-- Muda-se nos dois sítios que respondem à mesma pergunta, e só nesses:
-- obras_visiveis() para a RLS, exigir_acesso_obra() para as funções de serviço.
-- Deixar um deles para trás daria uma aplicação que mostra o que depois recusa.
--
-- Termina com o revoke da convenção fixada pela 0015.
--
-- Depende de: 0019.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0020_acessos.sql') then
    raise exception 'A migração 0020_acessos.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- ── o código ────────────────────────────────────────────────────────────────

create table betonagens.codigo_registo (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid not null references betonagens.organizacao(id),
  codigo         text not null,
  perfil         betonagens.perfil_utilizador not null,
  criado_por     uuid not null references betonagens.utilizador(id),
  criado_em      timestamptz not null default now(),
  expira_em      timestamptz not null,
  revogado_em    timestamptz,
  revogado_por   uuid references betonagens.utilizador(id),
  constraint codigo_registo_unico unique (codigo),
  constraint codigo_registo_revogacao_nominal
    check ((revogado_em is null) = (revogado_por is null)),
  constraint codigo_registo_validade check (expira_em > criado_em),
  -- Só a fiscalização se auto-regista. O empreiteiro é criado pelo ADMIN, e
  -- esta constraint é o que impede alguém de gerar um código que promova.
  constraint codigo_registo_so_fiscalizacao check (perfil = 'FISCALIZACAO')
);

-- Um código activo por organização de cada vez. Gerar um novo revoga o
-- anterior — é o que faz «renovar» ser uma operação e não uma acumulação de
-- códigos válidos espalhados por conversas antigas.
create unique index codigo_registo_ativo
  on betonagens.codigo_registo (organizacao_id) where revogado_em is null;
create index codigo_registo_por_criador on betonagens.codigo_registo (criado_por);
create index codigo_registo_por_revogador on betonagens.codigo_registo (revogado_por);

comment on table betonagens.codigo_registo is
  'Carta de apresentação, não credencial de acesso: decide quem entra, nunca o que pode fazer.';

alter table betonagens.codigo_registo enable row level security;

-- Só quem administra a organização vê o código. Um fiscal já registado não
-- tem de o poder ler — e não o pode.
create policy codigo_registo_leitura on betonagens.codigo_registo
  for select
  to authenticated
  using (
    exists (
      select 1 from betonagens.utilizador u
       where u.auth_user_id = (select betonagens_priv.identidade_externa())
         and u.ativo
         and u.perfil in ('ADMIN','DIRETOR_QUALIDADE')
         and u.organizacao_id = codigo_registo.organizacao_id
    )
  );

create trigger codigo_registo_sem_delete
  before delete on betonagens.codigo_registo
  for each row execute function betonagens_priv.impedir_remocao();

create trigger codigo_registo_ledger
  after insert or update on betonagens.codigo_registo
  for each row execute function betonagens_priv.registar_no_ledger();

-- ── o email de quem está autenticado ────────────────────────────────────────
-- Irmã de identidade_externa(), pela mesma razão: o schema auth não é
-- alcançável a partir daqui, e o email vem do JWT. Ler do JWT em vez de o
-- aceitar como parâmetro é o que impede alguém de se registar com o email de
-- outra pessoa.
create function betonagens_priv.email_externo()
returns text language sql stable set search_path = ''
as $fn$
  select nullif(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email',
  '')
$fn$;

-- ── gerar, revogar ──────────────────────────────────────────────────────────

create function betonagens.gerar_codigo_registo(p_validade_dias integer default 30)
returns betonagens.codigo_registo
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor  betonagens.utilizador := betonagens_priv.exigir_actor();
  v_codigo betonagens.codigo_registo;
  v_texto  text;
begin
  perform betonagens_priv.exigir_perfil(v_actor, 'ADMIN'::betonagens.perfil_utilizador);

  if p_validade_dias is null or p_validade_dias < 1 or p_validade_dias > 365 then
    raise exception 'A validade do código tem de estar entre 1 e 365 dias.'
      using errcode = 'PT422';
  end if;

  -- Renovar revoga o anterior. Sem isto ficariam vários códigos válidos, e
  -- revogar um deixaria de significar alguma coisa.
  update betonagens.codigo_registo
     set revogado_em = now(), revogado_por = v_actor.id
   where organizacao_id = v_actor.organizacao_id and revogado_em is null;

  -- Doze dígitos hexadecimais do gen_random_uuid, que é do núcleo: 48 bits.
  -- Não se usa gen_random_bytes de propósito — é do pgcrypto, e este projecto
  -- não instala extensões.
  v_texto := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
  v_texto := substr(v_texto,1,4) || '-' || substr(v_texto,5,4) || '-' || substr(v_texto,9,4);

  insert into betonagens.codigo_registo
    (organizacao_id, codigo, perfil, criado_por, expira_em)
  values
    (v_actor.organizacao_id, v_texto, 'FISCALIZACAO', v_actor.id,
     now() + make_interval(days => p_validade_dias))
  returning * into v_codigo;

  return v_codigo;
end
$fn$;

create function betonagens.revogar_codigo_registo(p_id uuid)
returns betonagens.codigo_registo
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor  betonagens.utilizador := betonagens_priv.exigir_actor();
  v_codigo betonagens.codigo_registo;
begin
  perform betonagens_priv.exigir_perfil(v_actor, 'ADMIN'::betonagens.perfil_utilizador);

  update betonagens.codigo_registo
     set revogado_em = now(), revogado_por = v_actor.id
   where id = p_id
     and organizacao_id = v_actor.organizacao_id
     and revogado_em is null
  returning * into v_codigo;

  if not found then
    raise exception 'Não há código activo com o id % nesta organização.', p_id
      using errcode = 'PT422';
  end if;

  return v_codigo;
end
$fn$;

-- ── registar-se com o código ────────────────────────────────────────────────

create function betonagens.registar_com_codigo(p_codigo text, p_nome text)
returns betonagens.utilizador
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_auth   uuid := betonagens_priv.identidade_externa();
  v_email  text := betonagens_priv.email_externo();
  v_codigo betonagens.codigo_registo;
  v_novo   betonagens.utilizador;
begin
  -- Não usa exigir_actor: quem chama esta função é precisamente quem ainda não
  -- tem utilizador de domínio. O que se exige é sessão autenticada.
  if v_auth is null then
    raise exception 'É preciso ter sessão iniciada para se registar.' using errcode = 'PT403';
  end if;
  if v_email is null then
    raise exception 'A sessão não traz email. Confirme a conta antes de se registar.'
      using errcode = 'PT422';
  end if;

  if p_nome is null or length(btrim(p_nome)) < 3 then
    raise exception 'Indique o seu nome completo — é o que fica nas assinaturas das fichas.'
      using errcode = 'PT422';
  end if;

  if exists (select 1 from betonagens.utilizador u where u.auth_user_id = v_auth) then
    raise exception 'Esta conta já está associada a um utilizador. Não é preciso registar-se outra vez.'
      using errcode = 'PT409';
  end if;

  -- Uma mensagem só para os três casos — código errado, revogado ou expirado.
  -- Distingui-los diria a quem tenta se acertou no código e falhou na validade,
  -- que é informação que não se dá a quem ainda não é ninguém.
  select * into v_codigo
    from betonagens.codigo_registo c
   where c.codigo = upper(btrim(coalesce(p_codigo, '')))
     and c.revogado_em is null
     and c.expira_em > now();

  if not found then
    raise exception 'Código de registo inválido, revogado ou expirado. Peça um novo à DDN.'
      using errcode = 'PT403';
  end if;

  insert into betonagens.utilizador (organizacao_id, auth_user_id, nome, email, perfil)
  values (v_codigo.organizacao_id, v_auth, btrim(p_nome), v_email, v_codigo.perfil)
  returning * into v_novo;

  return v_novo;
end
$fn$;

-- ── a fiscalização vê a organização inteira ─────────────────────────────────

create or replace function betonagens_priv.obras_visiveis()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $fn$
  -- Empreiteiro: só as obras atribuídas. É isto que impede a empresa A de ver
  -- a obra da empresa B, e não muda.
  select uo.obra_id
    from betonagens.utilizador u
    join betonagens.utilizador_obra uo on uo.utilizador_id = u.id
   where u.auth_user_id = (select betonagens_priv.identidade_externa())
     and u.ativo
     and u.perfil = 'EMPREITEIRO'
     and uo.revogado_em is null
  union
  -- Fiscalização, direção de qualidade e administração: a organização inteira.
  -- A fiscalização é da empresa, não do contrato.
  select o.id
    from betonagens.utilizador u
    join betonagens.obra o on o.organizacao_id = u.organizacao_id
   where u.auth_user_id = (select betonagens_priv.identidade_externa())
     and u.ativo
     and u.perfil in ('FISCALIZACAO','DIRETOR_QUALIDADE','ADMIN')
$fn$;

create or replace function betonagens_priv.exigir_acesso_obra(
  p_actor   betonagens.utilizador,
  p_obra_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  -- A mesma resposta que obras_visiveis() dá à RLS. Se estas duas divergirem, a
  -- aplicação mostra o que depois recusa.
  if p_actor.perfil in ('FISCALIZACAO','DIRETOR_QUALIDADE','ADMIN') then
    if not exists (
      select 1 from betonagens.obra o
       where o.id = p_obra_id and o.organizacao_id = p_actor.organizacao_id
    ) then
      raise exception 'A obra % não pertence à organização do utilizador.', p_obra_id
        using errcode = 'PT403';
    end if;
    return;
  end if;

  if not exists (
    select 1 from betonagens.utilizador_obra uo
     where uo.utilizador_id = p_actor.id
       and uo.obra_id = p_obra_id
       and uo.revogado_em is null
  ) then
    raise exception 'O utilizador % não tem acesso à obra %.', p_actor.nome, p_obra_id
      using errcode = 'PT403';
  end if;
end
$fn$;

reset role;

grant select on betonagens.codigo_registo to authenticated;
grant execute on function betonagens.gerar_codigo_registo(integer) to authenticated;
grant execute on function betonagens.revogar_codigo_registo(uuid) to authenticated;
grant execute on function betonagens.registar_com_codigo(text, text) to authenticated;

-- ── convenção fixada pela 0015 ──────────────────────────────────────────────
set role betonagens_servico;
revoke execute on all routines in schema betonagens, betonagens_priv from public;
reset role;

insert into betonagens.migracao (ficheiro) values ('0020_acessos.sql');
