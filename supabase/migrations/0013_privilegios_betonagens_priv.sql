-- =============================================================================
-- 0013_privilegios_betonagens_priv.sql · Obrify Betão
--
-- betonagens_priv.verificar_invariantes() ficou com EXECUTE para PUBLIC, e é a
-- única função da base inteira nessa situação.
--
-- A CAUSA É TEMPORAL, NÃO DE COBERTURA. A 0008 revoga nos dois schemas, nas
-- linhas 1846 e 1847 — betonagens_priv está lá. O que falhou é que
-- "revoke ... on all functions" opera sobre o que existe naquele instante: não
-- é uma regra, é um acto. Esta função foi criada na 0009, depois de a
-- revogação já ter passado, e o PostgreSQL concede EXECUTE a PUBLIC por defeito
-- a toda a função nova. As quatro auxiliares da RLS não têm o problema porque
-- nasceram na 0002 e na 0004, antes da revogação, e receberam depois concessão
-- explícita a authenticated — revogar e conceder de propósito é o padrão certo,
-- e foi o que aqui faltou.
--
-- ALCANCE HOJE: latente, não vivo. O anon não tem USAGE em betonagens_priv (a
-- 0001 revoga-o a public e nunca lho concede) e o service_role também não; o
-- authenticated tem USAGE, mas betonagens_priv não está exposto na API, que é o
-- único caminho por onde ele fala. Ninguém lá chega.
--
-- CORRIGE-SE NA MESMA, por três razões: a contenção não deve depender de uma
-- definição de painel; a função é SECURITY DEFINER e ignora a RLS por
-- construção, portanto devolveria contagens de invariantes de toda a base,
-- atravessando organizações, a quem a chamasse; e o defeito é um padrão à
-- espera de se repetir na próxima função criada depois da 0008.
--
-- Depende de: 0012.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao
              where ficheiro = '0013_privilegios_betonagens_priv.sql') then
    raise exception 'A migração 0013_privilegios_betonagens_priv.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- O caso concreto. Não é chamada por nada no domínio nem na suite: é uma
-- ferramenta de operação, para correr no SQL Editor com um papel que a possa
-- executar por ser dono. Zero concessões a papéis de aplicação.
revoke all on function betonagens_priv.verificar_invariantes()
  from public, anon, authenticated, service_role;

-- A raiz. Sem isto, a próxima função criada numa migração posterior nasce outra
-- vez com EXECUTE para PUBLIC, e nenhum revoke em bloco escrito no passado a
-- alcança. Só funções: tabelas e sequências novas não recebem nada de PUBLIC
-- por defeito.
--
-- Limite honesto: aplica-se ao que betonagens_servico criar. Todas as migrações
-- criam com "set role betonagens_servico", portanto cobre-as; mas uma migração
-- futura que se esquecesse desse set role ficaria de fora. É por isso que a
-- verificação "nenhuma função é executável por anon" entra no
-- verificar_esquema.sql: é o travão que apanha o que esta regra não alcança.
alter default privileges in schema betonagens, betonagens_priv
  revoke execute on functions from public;

reset role;

insert into betonagens.migracao (ficheiro)
values ('0013_privilegios_betonagens_priv.sql');
