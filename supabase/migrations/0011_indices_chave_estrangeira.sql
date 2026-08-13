-- =============================================================================
-- 0011_indices_chave_estrangeira.sql · Obrify Betão
--
-- Seis índices em colunas de chave estrangeira com caminho de acesso real. Os
-- outros oito casos ficam sem índice por decisão, declarados com a razão em
-- verificacao/verificar_esquema.sql.
-- Depende de: 0010.
--
-- Contexto que pesa na decisão: DELETE está revogado em todas as tabelas e não
-- há ON DELETE CASCADE nenhum. O índice do lado filho de uma chave estrangeira
-- serve sobretudo as verificações referenciais quando a linha-mãe é apagada ou
-- a sua chave alterada — aqui, nem uma coisa nem outra podem acontecer. Sobra o
-- desempenho de junção, e é só por ele que estes seis se justificam.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao
              where ficheiro = '0011_indices_chave_estrangeira.sql') then
    raise exception 'A migração 0011_indices_chave_estrangeira.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- pab · as três colunas de pessoa que ficaram de fora quando indexei
-- submetido_por e aprovado_por. "O que é que esta pessoa rejeitou, anulou ou
-- deu por betonado" tem de ser respondível: sustenta D7 — desativar sem perder
-- o histórico — e o resumo semanal por obra. ~210 linhas por dia útil, portanto
-- o custo de escrita é irrelevante.
create index pab_por_rejeitador on betonagens.pab (rejeitado_por);
create index pab_por_anulador   on betonagens.pab (anulado_por);
create index pab_por_fechador   on betonagens.pab (betonagem_fechada_por);

-- fcq e fcq_versao · quando sair a Rev. 10 do I.CR.033, é preciso encontrar
-- todas as fichas e todas as versões emitidas com a revisão anterior: a
-- arquitetura §11 exige que continuem a regenerar-se na revisão de origem.
-- Sem estes dois é varrimento sequencial sobre 52.500 linhas por ano.
create index fcq_por_modelo        on betonagens.fcq (modelo_impresso_id);
create index fcq_versao_por_modelo on betonagens.fcq_versao (modelo_impresso_id);

-- alerta · alerta_abertos é parcial e só cobre os alertas por resolver. O
-- resumo semanal e a auditoria precisam de todos os alertas da obra, os
-- resolvidos incluídos.
create index alerta_por_obra on betonagens.alerta (obra_id, criado_em desc);

reset role;

insert into betonagens.migracao (ficheiro)
values ('0011_indices_chave_estrangeira.sql');
