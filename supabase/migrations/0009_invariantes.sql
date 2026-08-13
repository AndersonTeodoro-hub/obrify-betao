-- =============================================================================
-- 0009_invariantes.sql · Obrify Betão
--
-- Cria: betonagens_priv.verificar_invariantes() — as verificações contínuas do
--       documento de brechas, secção F.
-- Depende de: 0008.
--
-- INV1, INV2 e INV3 são estruturais: não podem ser falsas enquanto as
-- constraints existirem. Por isso o que a função verifica nesses três casos é
-- que A CONSTRAINT CONTINUA LÁ — é esse o teste real de B1. Uma migração futura
-- que torne pab_id anulável faz esta verificação falhar.
--
-- Sem pg_cron nesta fase: a função existe, o agendamento é decisão de operação.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0009_invariantes.sql') then
    raise exception 'A migração 0009_invariantes.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

create function betonagens_priv.verificar_invariantes()
returns table (
  invariante text,
  ok         boolean,     -- null = não avaliada, e diz porquê em detalhe
  falhas     bigint,
  detalhe    text
)
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_n bigint;
begin
  -- INV1 · não existe guia_remessa com pab_id nulo
  invariante := 'INV1 · guia sem PAB';
  ok := exists (
    select 1 from pg_attribute a
     where a.attrelid = 'betonagens.guia_remessa'::regclass
       and a.attname = 'pab_id' and a.attnotnull
  ) and exists (
    select 1 from pg_constraint c
     where c.conrelid = 'betonagens.guia_remessa'::regclass
       and c.contype = 'f'
       and c.conname = 'guia_pab_fk'
  );
  select count(*) into falhas from betonagens.guia_remessa g where g.pab_id is null;
  detalhe := case when ok then 'pab_id NOT NULL e chave estrangeira presentes.'
                  else 'A COLUNA pab_id DEIXOU DE SER NOT NULL OU A FK DESAPARECEU. Incidente.' end;
  return next;

  -- INV2 · não existem duas guias em vigor com o mesmo (central, número, ano)
  invariante := 'INV2 · guia duplicada por central';
  ok := exists (
    select 1 from pg_class i
     where i.relname = 'guia_unica_por_central' and i.relkind = 'i'
  );
  select count(*) into falhas
    from (
      select 1 from betonagens.guia_remessa g
       where g.substituida_por_id is null
       group by g.organizacao_id, g.central_id, g.numero_guia, g.ano_civil
      having count(*) > 1
    ) d;
  detalhe := case when ok then 'Índice único parcial presente.'
                  else 'O ÍNDICE guia_unica_por_central DESAPARECEU. Incidente.' end;
  return next;

  -- INV3 · não existem dois ficheiros de guia com o mesmo sha256
  invariante := 'INV3 · fotografia de guia reutilizada';
  ok := exists (
    select 1 from pg_class i
     where i.relname = 'ficheiro_guia_sha256_unico' and i.relkind = 'i'
  );
  select count(*) into falhas
    from (
      select 1 from betonagens.ficheiro f
       where f.tipo = 'GUIA'
       group by f.organizacao_id, f.sha256
      having count(*) > 1
    ) d;
  detalhe := case when ok then 'Índice único parcial presente.'
                  else 'O ÍNDICE ficheiro_guia_sha256_unico DESAPARECEU. Incidente.' end;
  return next;

  -- INV4 · cronologia de toda a FCQ emitida
  invariante := 'INV4 · cronologia da FCQ emitida';
  select count(*) into v_n
    from betonagens.fcq f
    join betonagens.pab p on p.id = f.pab_id
   where f.estado = 'EMITIDA'
     and (
       -- assinatura pré-betonagem depois da aprovação
       exists (
         select 1 from betonagens.fcq_seccao_assinatura a
          where a.fcq_id = f.id and a.coluna = 'insp'
            and a.seccao in ('implantacao','cofragem','armaduras')
            and a.momento_declarado > p.aprovado_momento_declarado
       )
       -- guia antes da aprovação
       or exists (
         select 1 from betonagens.guia_remessa g
          where g.pab_id = p.id and g.substituida_por_id is null
            and g.data_hora_betonagem < p.aprovado_momento_declarado
       )
       -- fecho antes da última guia
       or p.betonagem_fechada_momento_declarado < (
            select max(g.data_hora_betonagem) from betonagens.guia_remessa g
             where g.pab_id = p.id and g.substituida_por_id is null)
       -- item pós-betonagem antes do fecho
       or exists (
         select 1 from betonagens.fcq_item i
          where i.fcq_id = f.id and i.seccao = 'pos_betonagem'
            and i.substituido_por_id is null
            and i.momento_declarado < p.betonagem_fechada_momento_declarado
       )
       -- emissão antes do fecho
       or exists (
         select 1 from betonagens.fcq_versao v
          where v.fcq_id = f.id
            and v.emitida_em < p.betonagem_fechada_em
       )
     );
  falhas := v_n;
  ok := (v_n = 0);
  detalhe := 'Assinatura pré-betonagem < aprovação < 1.ª guia < fecho < pós-betonagem < emissão.';
  return next;

  -- INV5 · a versão emitida usa o modelo com que a ficha foi criada
  invariante := 'INV5 · modelo do impresso na versão emitida';
  select count(*) into v_n
    from betonagens.fcq_versao v
    join betonagens.fcq f on f.id = v.fcq_id
   where v.modelo_impresso_id <> f.modelo_impresso_id
      or not exists (select 1 from betonagens.modelo_impresso m where m.id = v.modelo_impresso_id);
  falhas := v_n;
  ok := (v_n = 0);
  detalhe := 'Uma FCQ regenera-se sempre na revisão com que foi criada.';
  return next;

  -- INV6 · cadeia de hash do ledger
  invariante := 'INV6 · cadeia do ledger';
  select count(*) into v_n
    from (
      select l.id,
             l.hash,
             l.hash_anterior,
             lag(l.hash) over (partition by l.organizacao_id order by l.seq) as hash_esperado,
             -- tem de ser exactamente a expressão de betonagens_priv.registar_no_ledger()
             sha256(convert_to(
               coalesce(encode(l.hash_anterior, 'hex'), '') || '|' ||
               l.seq::text || '|' || l.entidade || '|' || l.entidade_id || '|' ||
               l.acao || '|' || l.dados::text || '|' || extract(epoch from l.momento)::text,
               'UTF8')) as hash_recalculado
        from betonagens.ledger l
    ) c
   where c.hash <> c.hash_recalculado
      or c.hash_anterior is distinct from c.hash_esperado;
  falhas := v_n;
  ok := (v_n = 0);
  detalhe := 'Cada elo recalculado tem de bater certo com o guardado e com o antecessor.';
  return next;

  -- INV7 · a contagem nunca decresce entre instantâneos diários
  invariante := 'INV7 · contagens não decrescem';
  ok := null;
  falhas := null;
  detalhe := 'Não avaliada: exige tabela de instantâneos diários, que está fora do âmbito de F1-F3. '
          || 'DELETE está revogado em todas as tabelas, o que torna o decréscimo impossível por via normal.';
  return next;

  -- INV8 · nenhuma FCQ emitida com alerta crítico por resolver
  invariante := 'INV8 · alerta crítico aberto em FCQ emitida';
  select count(*) into v_n
    from betonagens.fcq f
    join betonagens.alerta a
      on (a.fcq_id = f.id or a.pab_id = f.pab_id)
   where f.estado = 'EMITIDA'
     and a.severidade = 'CRITICO'
     and a.resolvido_em is null;
  falhas := v_n;
  ok := (v_n = 0);
  detalhe := 'Um alerta crítico aberto impede o fecho da FCQ.';
  return next;

  -- INV9 · toda a exceção é nominal e justificada
  invariante := 'INV9 · exceção nominal e justificada';
  ok := exists (
    select 1 from pg_constraint c
     where c.conrelid = 'betonagens.excecao'::regclass
       and c.contype = 'c'
       and pg_get_constraintdef(c.oid) like '%justificacao%20%'
  );
  select count(*) into falhas
    from betonagens.excecao e
   where e.utilizador_id is null or length(btrim(e.justificacao)) < 20;
  detalhe := case when ok then 'Constraint de comprimento mínimo presente.'
                  else 'A CONSTRAINT DE JUSTIFICAÇÃO DESAPARECEU. Incidente.' end;
  return next;

  return;
end
$fn$;

comment on function betonagens_priv.verificar_invariantes() is
  'Secção F do documento de brechas. Qualquer linha com ok=false é incidente, não bug.';

reset role;

insert into betonagens.migracao (ficheiro) values ('0009_invariantes.sql');
