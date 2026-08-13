-- =============================================================================
-- 0012_excecao_momento_monotono.sql · Obrify Betão
--
-- betonagens_priv.registar_excecao decide se uma justificação é igual à última
-- do próprio utilizador ordenando por excecao.criada_em. Com o valor por
-- defeito now(), que é o instante de INÍCIO DA TRANSAÇÃO, duas exceções
-- escritas na mesma transação ficam com o mesmo carimbo e "a última" passa a
-- ser decidida pelo desempate por uuid — isto é, ao acaso. Em produção cada
-- chamada é a sua transação e a ordem sai certa por acidente do padrão de
-- chamada, não por construção. Basta uma operação que registe duas exceções de
-- uma vez para uma justificação repetida entrar.
--
-- clock_timestamp() anda dentro da transação. É o que o ledger já usa em
-- betonagens_priv.registar_no_ledger; esta tabela é que ficou de fora.
--
-- Limite honesto: clock_timestamp() tem resolução de microssegundo. Duas
-- exceções separadas por menos do que isso voltariam a empatar e a cair no
-- uuid. Entre duas chamadas a registar_excecao há uma inserção e uma função
-- pelo meio, portanto não acontece na prática — mas é uma improbabilidade, não
-- uma impossibilidade demonstrada. A ordem provadamente total exigiria uma
-- coluna identity em excecao; foi ponderada e recusada por excesso para hoje.
--
-- Não altera linhas existentes nem índices: excecao_ultima_do_utilizador
-- (utilizador_id, criada_em desc) continua a ser o índice certo.
-- Depende de: 0011.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao
              where ficheiro = '0012_excecao_momento_monotono.sql') then
    raise exception 'A migração 0012_excecao_momento_monotono.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

alter table betonagens.excecao
  alter column criada_em set default clock_timestamp();

reset role;

insert into betonagens.migracao (ficheiro)
values ('0012_excecao_momento_monotono.sql');
