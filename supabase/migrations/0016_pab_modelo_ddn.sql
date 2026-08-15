-- =============================================================================
-- 0016_pab_modelo_ddn.sql · Obrify Betão
--
-- O modelo DDN de PAB: os campos que o QAS.150.04 pede ao empreiteiro e que a
-- tabela pab ainda não tinha.
--
-- ── PORQUÊ ──────────────────────────────────────────────────────────────────
-- A plataforma passa a ter UM modelo único de PAB para todas as obras. O
-- QAS.150.04 da Ferreira Construção é a referência de completude: nada do que
-- lá existe pode faltar aqui, porque as obras variam no tipo de betão e na
-- ocasião. Do levantamento campo a campo sobraram sete campos que são do
-- PEDIDO do empreiteiro e não estavam em lado nenhum:
--
--   Ref.ª do Desenho · Processo de Betonagem · Processo de Cura ·
--   Hora prevista de Início e de Fim · Data prevista de Descofragem ·
--   Data prevista de Retirada do Escoramento
--
-- O que o impresso pede e NÃO entra aqui, por ser de fase posterior e já estar
-- modelado noutro sítio: as verificações (FCQ), a receção do betão (guias) e a
-- garantia de qualidade (fecho do FCQ). Transporte, estado do tempo e
-- observações da receção ficam registados como pendências das guias.
--
-- ── AS TRÊS DATAS E O "N/A" ─────────────────────────────────────────────────
-- O impresso distingue explicitamente três estados na descofragem e no
-- escoramento: uma data, "N/A", e vazio. Em estacas moldadas a descofragem não
-- se aplica — não é "ainda não sei". Uma data anulável só exprime dois desses
-- estados, por isso cada data leva a sua coluna de aplicabilidade.
--
-- O estado incoerente — não aplicável COM data — é recusado em dois sítios, de
-- propósito: na função, com PT422 e uma frase que diz o que fazer, que é o que
-- alguém lê; e no check da tabela, que é a rede para quando um dia se escrever
-- por outro caminho. O check sozinho daria um 23514 com o nome de uma
-- constraint, que não é uma explicação.
--
-- ── PORQUE É QUE NENHUMA COLUNA NASCE NOT NULL ──────────────────────────────
-- Há PAB gravados. Pôr not null obrigaria a inventar valores para pedidos que
-- foram feitos sem estes campos, e um valor inventado num registo que não se
-- pode editar é pior do que um vazio honesto. A obrigatoriedade do processo de
-- betonagem vive onde pode viver de verdade: na função de serviço, que é o
-- único caminho de escrita — authenticated não tem INSERT nesta tabela.
--
-- ── A FUNÇÃO É RECRIADA, NÃO SUBSTITUÍDA ────────────────────────────────────
-- create or replace não muda listas de argumentos. Os nove parâmetros novos
-- entram TODOS NO FIM e todos com default, para que as chamadas posicionais
-- existentes continuem a compilar com o mesmo significado.
--
-- Nada é apagado nem reescrito: as colunas novas são aditivas, o ledger grava
-- to_jsonb(NEW) sem enumerar colunas, e os elos já escritos guardam os dados
-- que guardaram — a cadeia de hash não é afectada.
--
-- Termina com o revoke da convenção fixada pela 0015. Sem asserção própria: a
-- rede é a verificação "nenhuma função é executável por anon" do
-- verificar_esquema.sql, que varre os dois schemas inteiros.
--
-- Depende de: 0015.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0016_pab_modelo_ddn.sql') then
    raise exception 'A migração 0016_pab_modelo_ddn.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- ── as nove colunas ─────────────────────────────────────────────────────────

alter table betonagens.pab
  add column referencia_desenho            text,
  add column processo_betonagem            text,
  add column processo_cura                 text,
  add column hora_prevista_inicio          time,
  add column hora_prevista_fim             time,
  add column descofragem_prevista          date,
  add column descofragem_aplicavel         boolean not null default true,
  add column escoramento_retirada_prevista date,
  add column escoramento_aplicavel         boolean not null default true;

-- "não aplicável" e "tem data" são estados que se excluem. Sem isto, um
-- registo podia dizer as duas coisas ao mesmo tempo e o impresso teria de
-- escolher qual delas mentir.
alter table betonagens.pab
  add constraint pab_descofragem_aplicavel
    check (descofragem_aplicavel or descofragem_prevista is null),
  add constraint pab_escoramento_aplicavel
    check (escoramento_aplicavel or escoramento_retirada_prevista is null);

comment on column betonagens.pab.descofragem_aplicavel is
  'Falso é o "N/A" do impresso: a descofragem não se aplica a esta peça. Distinto de data nula, que é "não indicada".';
comment on column betonagens.pab.escoramento_aplicavel is
  'Falso é o "N/A" do impresso: não há escoramento a retirar. Distinto de data nula, que é "não indicada".';
comment on column betonagens.pab.processo_betonagem is
  'Obrigatório na submissão, validado em betonagens.submeter_pab. Nulo apenas nos PAB anteriores à 0016.';

-- ── submeter_pab, recriada com os nove parâmetros no fim ────────────────────

drop function betonagens.submeter_pab(
  uuid, uuid, text, numeric, text, date, date, timestamptz,
  text, integer, text, uuid, text);

create function betonagens.submeter_pab(
  p_obra_id             uuid,
  p_frente_id           uuid,
  p_elemento            text,
  p_volume_previsto_m3  numeric,
  p_classe_betao        text,
  p_data_pedido         date,
  p_data_prevista       date,
  p_momento_declarado   timestamptz,
  p_classe_exposicao    text default null,
  p_dmax_agregado_mm    integer default null,
  p_classe_consistencia text default null,
  p_ficheiro_impresso_id uuid default null,
  p_observacoes         text default null,
  p_referencia_desenho  text default null,
  p_processo_betonagem  text default null,
  p_processo_cura       text default null,
  p_hora_prevista_inicio time default null,
  p_hora_prevista_fim    time default null,
  p_descofragem_prevista date default null,
  p_descofragem_aplicavel boolean default true,
  p_escoramento_retirada_prevista date default null,
  p_escoramento_aplicavel boolean default true
)
returns betonagens.pab
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor  betonagens.utilizador := betonagens_priv.exigir_actor();
  v_numero integer;
  v_modelo uuid;
  v_pab    betonagens.pab;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'EMPREITEIRO'::betonagens.perfil_utilizador,
    'FISCALIZACAO'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);
  perform betonagens_priv.exigir_acesso_obra(v_actor, p_obra_id);

  -- B2 · não existe PAB genérico
  if p_elemento is null or length(btrim(p_elemento)) < 3 then
    raise exception 'O PAB tem de identificar as peças a betonar. "Diversos" não é um elemento.'
      using errcode = 'PT422';
  end if;
  if p_volume_previsto_m3 is null or p_volume_previsto_m3 <= 0 then
    raise exception 'O volume previsto tem de ser maior do que zero.'
      using errcode = 'PT422';
  end if;
  if p_classe_betao is null or length(btrim(p_classe_betao)) < 3 then
    raise exception 'A classe de betão é obrigatória.'
      using errcode = 'PT422';
  end if;
  -- Modelo DDN · o processo de betonagem é do pedido e determina os meios que
  -- vão aparecer em obra. Sem ele o fiscal não sabe o que se prepara para ver.
  if p_processo_betonagem is null or length(btrim(p_processo_betonagem)) < 3 then
    raise exception 'O processo de betonagem é obrigatório: diga como vai ser betonado (bomba, balde, descarga directa).'
      using errcode = 'PT422';
  end if;
  -- Modelo DDN · "não aplicável" e "tem data" excluem-se. Os checks da tabela
  -- recusam a combinação de qualquer forma, mas em SQLSTATE 23514 e com o nome
  -- de uma constraint à frente de quem submeteu. Aqui recusa-se antes, com uma
  -- frase que diz o que fazer. O check fica como rede, para o caso de um dia
  -- alguém escrever na tabela por outro caminho.
  -- coalesce e não comparação directa: é exactamente o valor que vai ser
  -- gravado que tem de ser avaliado, e nulo grava true.
  if not coalesce(p_descofragem_aplicavel, true) and p_descofragem_prevista is not null then
    raise exception 'A descofragem está marcada como não aplicável e ao mesmo tempo tem data prevista. Indique a data ou marque como não aplicável, não as duas.'
      using errcode = 'PT422';
  end if;
  if not coalesce(p_escoramento_aplicavel, true) and p_escoramento_retirada_prevista is not null then
    raise exception 'A retirada do escoramento está marcada como não aplicável e ao mesmo tempo tem data prevista. Indique a data ou marque como não aplicável, não as duas.'
      using errcode = 'PT422';
  end if;

  if p_frente_id is null or p_data_pedido is null or p_data_prevista is null
     or p_momento_declarado is null then
    raise exception 'Faltam campos obrigatórios na submissão do PAB.'
      using errcode = 'PT422';
  end if;
  if p_momento_declarado > now() then
    raise exception 'O momento declarado está no futuro do relógio do servidor.'
      using errcode = 'PT422';
  end if;

  -- número sequencial por obra, sob bloqueio da linha da obra
  -- ponytail: bloqueio de linha em vez de sequência por obra; a 210 PAB/dia
  -- não há contenção. Se um dia houver, passa a sequência dedicada.
  perform 1 from betonagens.obra o where o.id = p_obra_id for update;

  select coalesce(max(p.numero), 0) + 1 into v_numero
    from betonagens.pab p where p.obra_id = p_obra_id;

  select m.id into v_modelo
    from betonagens.modelo_impresso m
   where m.codigo = 'I.CR.033' and m.ativo_desde <= current_date
   order by m.ativo_desde desc, m.revisao desc
   limit 1;

  if v_modelo is null then
    raise exception 'Não há modelo I.CR.033 activo. Carregue o impresso antes de submeter PAB.'
      using errcode = 'PT422';
  end if;

  insert into betonagens.pab
    (organizacao_id, obra_id, frente_id, numero, elemento, volume_previsto_m3,
     classe_betao, classe_exposicao, dmax_agregado_mm, classe_consistencia,
     data_pedido, data_prevista, estado, ficheiro_impresso_id, observacoes,
     referencia_desenho, processo_betonagem, processo_cura,
     hora_prevista_inicio, hora_prevista_fim,
     descofragem_prevista, descofragem_aplicavel,
     escoramento_retirada_prevista, escoramento_aplicavel,
     submetido_por, submetido_em, submetido_momento_declarado)
  values
    (v_actor.organizacao_id, p_obra_id, p_frente_id, v_numero, btrim(p_elemento),
     p_volume_previsto_m3, btrim(p_classe_betao), p_classe_exposicao,
     p_dmax_agregado_mm, p_classe_consistencia, p_data_pedido, p_data_prevista,
     'SUBMETIDO', p_ficheiro_impresso_id, p_observacoes,
     p_referencia_desenho, btrim(p_processo_betonagem), p_processo_cura,
     p_hora_prevista_inicio, p_hora_prevista_fim,
     p_descofragem_prevista, coalesce(p_descofragem_aplicavel, true),
     p_escoramento_retirada_prevista, coalesce(p_escoramento_aplicavel, true),
     v_actor.id, now(), p_momento_declarado)
  returning * into v_pab;

  -- C1 · a ficha nasce com o PAB, em rascunho. É o que torna possível exigir as
  -- secções pré-betonagem assinadas ANTES da aprovação.
  insert into betonagens.fcq
    (organizacao_id, obra_id, pab_id, modelo_impresso_id, numero, estado)
  values
    (v_actor.organizacao_id, p_obra_id, v_pab.id, v_modelo,
     lpad(v_numero::text, 3, '0'), 'RASCUNHO');

  return v_pab;
end
$fn$;

reset role;

grant execute on function betonagens.submeter_pab(
  uuid, uuid, text, numeric, text, date, date, timestamptz,
  text, integer, text, uuid, text,
  text, text, text, time, time, date, boolean, date, boolean) to authenticated;

-- ── convenção fixada pela 0015 ──────────────────────────────────────────────
-- Toda a migração que cria funções termina aqui. É seguro repetir: só remove
-- as entradas do PUBLIC; as concessões a papéis nomeados ficam intactas.
set role betonagens_servico;
revoke execute on all routines in schema betonagens, betonagens_priv from public;
reset role;

insert into betonagens.migracao (ficheiro) values ('0016_pab_modelo_ddn.sql');
