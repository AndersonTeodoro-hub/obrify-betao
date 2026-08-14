-- =============================================================================
-- 0015_omissoes_execute.sql · Obrify Betão
--
-- Fecha o EXECUTE a PUBLIC nas funções dos dois schemas, e estabelece a regra
-- para as futuras.
--
-- ── O QUE ACONTECEU ─────────────────────────────────────────────────────────
-- A 0013 tentou impedir o problema na origem, com omissões:
--     alter default privileges in schema betonagens, betonagens_priv
--       revoke execute on functions from public;
-- Deu Success e NÃO GRAVOU NADA. A primeira função criada depois dela —
-- betonagens.agora, na 0014 — nasceu com o defeito de fábrica do PostgreSQL,
-- que é EXECUTE para PUBLIC, e foi a verificação "nenhuma função é executável
-- por anon" que o apanhou.
--
-- ── COMPORTAMENTO POR EXPLICAR, REGISTADO AQUI DE PROPÓSITO ─────────────────
-- A primeira versão desta migração voltou a tentar, com FOR ROLE explícito e
-- uma instrução por schema. Também não gravou, e também sem erro. Três
-- variantes, zero linhas em pg_default_acl.
--
-- O que a investigação apurou, e que torna isto estranho:
--   · acldefault('f', betonagens_servico) devolve
--     {=X/betonagens_servico,betonagens_servico=X/betonagens_servico} — o
--     PUBLIC ESTÁ no defeito de fábrica, portanto revogá-lo era uma operação
--     com efeito e devia ter sido gravada;
--   · o dono não é a causa: as 45 funções pertencem a betonagens_servico;
--   · a permissão não é a causa: postgres é membro do papel;
--   · nenhum dos seis gatilhos de evento do Supabase toca em funções nossas;
--   · a 0013 fez commit e o registo não persistiu — não foi visibilidade
--     dentro da transação.
--
-- Não se percebeu porquê. Desistiu-se de perceber, deliberadamente: o
-- mecanismo não é verificável nesta base e há uma alternativa que é. Fica
-- escrito para quem voltar a este ficheiro não repetir as três tentativas.
--
-- ── REGRA PARA AS MIGRAÇÕES FUTURAS ─────────────────────────────────────────
-- Sem omissões e sem gatilho de evento — CREATE EVENT TRIGGER exige superuser,
-- e o postgres desta base não o é — a garantia passa a ser convenção mais
-- vigilância:
--
--     TODA A MIGRAÇÃO QUE CRIAR FUNÇÕES TERMINA COM:
--     revoke execute on all routines in schema betonagens, betonagens_priv
--       from public;
--
-- É seguro repetir: só remove as entradas do PUBLIC. As concessões explícitas
-- a authenticated e a service_role são a papéis nomeados e ficam intactas, sem
-- nada para repor.
--
-- A rede por baixo é a verificação "nenhuma função é executável por anon", no
-- verificar_esquema.sql, que varre os dois schemas inteiros. Se alguém
-- esquecer a linha, ela diz o nome da função.
--
-- Depende de: 0014.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0015_omissoes_execute.sql') then
    raise exception 'A migração 0015_omissoes_execute.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- ROUTINES e não FUNCTIONS: cobre também procedimentos. Não temos nenhum hoje,
-- e é uma palavra que fecha a lacuna antes de ela existir.
revoke execute on all routines in schema betonagens, betonagens_priv from public;

reset role;

-- ── a prova de que ficou fechado ────────────────────────────────────────────
-- Verifica o RESULTADO, não o mecanismo. O coalesce é o que torna isto
-- correcto: uma função sem ACL explícita não está sem privilégios — tem o
-- defeito de fábrica, e é esse que é preciso avaliar.
do $$
declare
  v_abertas integer;
  v_nomes   text;
begin
  select count(*),
         string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname, p.proname)
    into v_abertas, v_nomes
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where n.nspname in ('betonagens', 'betonagens_priv')
     and p.prokind in ('f', 'p')
     and a.grantee = 0                    -- 0 é o PUBLIC
     and a.privilege_type = 'EXECUTE';

  if v_abertas <> 0 then
    raise exception
      'Continuam % funções executáveis por PUBLIC depois do revoke: %. O revoke não fez o que devia — não registar esta migração.',
      v_abertas, v_nomes;
  end if;
end $$;

insert into betonagens.migracao (ficheiro) values ('0015_omissoes_execute.sql');
