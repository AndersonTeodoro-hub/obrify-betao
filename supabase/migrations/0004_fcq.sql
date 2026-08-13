-- =============================================================================
-- 0004_fcq.sql · Obrify Betão
--
-- Cria: modelo_impresso, fcq_linha, fcq, fcq_item, fcq_seccao_assinatura,
--       fcq_versao, e a vista do estado das secções.
-- Depende de: 0003.
--
-- A FCQ nasce com o PAB, em RASCUNHO (C1). A emissão é o último ato e vive em
-- fcq_versao, que fixa a revisão do impresso com que foi criada: uma FCQ de
-- 2026 regenera-se sempre na Rev. 9, mesmo que exista Rev. 12 em 2029.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0004_fcq.sql') then
    raise exception 'A migração 0004_fcq.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- ── registo de modelos de impresso ───────────────────────────────────────────
-- Sem organizacao_id: o impresso é da DDN e é partilhado. Se um dia houver
-- impressos por organização, é uma coluna nova, não uma migração de dados.
create table betonagens.modelo_impresso (
  id              uuid primary key default gen_random_uuid(),
  codigo          text not null,
  revisao         integer not null check (revisao > 0),
  data_revisao    date not null,
  caminho_storage text not null,
  sha256          bytea not null check (octet_length(sha256) = 32),
  mapa_campos     jsonb not null,
  ativo_desde     date not null,
  criado_em       timestamptz not null default now(),
  constraint modelo_impresso_revisao_unica unique (codigo, revisao)
);

comment on table betonagens.modelo_impresso is
  'O impresso nunca é recriado. Carrega-se pelo caminho e verifica-se o sha256 no arranque do motor; se divergir, aborta.';

-- ── as 34 linhas da ficha, derivadas do mapa de campos ──────────────────────
create table betonagens.fcq_linha (
  modelo_impresso_id uuid not null references betonagens.modelo_impresso(id),
  codigo             text not null check (codigo ~ '^L[0-9]{2}$'),
  seccao             betonagens.fcq_seccao not null,
  criterio           text not null,
  ordem              integer not null check (ordem > 0),
  primary key (modelo_impresso_id, codigo),
  -- permite a chave estrangeira composta que impede um item de mentir sobre a
  -- secção a que pertence
  constraint fcq_linha_codigo_seccao unique (modelo_impresso_id, codigo, seccao),
  constraint fcq_linha_ordem_unica unique (modelo_impresso_id, ordem)
);

-- ── FCQ · 1:1 estrito com o PAB ─────────────────────────────────────────────
create table betonagens.fcq (
  id                 uuid primary key default gen_random_uuid(),
  organizacao_id     uuid not null,
  obra_id            uuid not null,
  pab_id             uuid not null,
  modelo_impresso_id uuid not null references betonagens.modelo_impresso(id),
  numero             text not null,
  estado             betonagens.fcq_estado not null default 'RASCUNHO',
  criada_em          timestamptz not null default now(),
  constraint fcq_pab_fk foreign key (pab_id, obra_id)
    references betonagens.pab (id, obra_id),
  constraint fcq_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id),
  constraint fcq_pab_unico unique (pab_id),
  constraint fcq_numero_unico unique (obra_id, numero),
  constraint fcq_id_obra unique (id, obra_id),
  constraint fcq_id_modelo unique (id, modelo_impresso_id)
);
create index fcq_por_obra on betonagens.fcq (obra_id, estado);

comment on column betonagens.fcq.numero is
  'Q1 · acompanha o número do PAB, série por obra. Sai no impresso como "033 / <numero>". A reemissão gera versão, não número novo.';

-- ── itens da checklist · append-only ────────────────────────────────────────
create table betonagens.fcq_item (
  id                    uuid primary key,          -- UUIDv7 do dispositivo
  organizacao_id        uuid not null,
  obra_id               uuid not null,
  fcq_id                uuid not null,
  modelo_impresso_id    uuid not null,
  linha_codigo          text not null,
  seccao                betonagens.fcq_seccao not null,
  coluna                betonagens.fcq_coluna not null,
  valor                 betonagens.fcq_valor not null,
  anotacao              text,
  registado_por         uuid not null references betonagens.utilizador(id),
  momento_declarado     timestamptz not null,
  recebido_em           timestamptz not null default now(),
  dispositivo_id        text not null,
  sequencia_dispositivo bigint not null,
  latitude              numeric(9,6) check (latitude between -90 and 90),
  longitude             numeric(9,6) check (longitude between -180 and 180),
  precisao_gps_m        numeric(6,1) check (precisao_gps_m >= 0),
  substitui_id          uuid references betonagens.fcq_item(id),
  motivo_substituicao   text,
  -- DEFERRABLE pela mesma razão que em guia_remessa: a ligação para a frente
  -- é escrita antes da inserção do registo novo, senão o índice único parcial
  -- fcq_item_atual recusa a correção.
  substituido_por_id    uuid references betonagens.fcq_item(id)
                             deferrable initially deferred,
  constraint fcq_item_fcq_fk foreign key (fcq_id, obra_id)
    references betonagens.fcq (id, obra_id),
  constraint fcq_item_fcq_modelo_fk foreign key (fcq_id, modelo_impresso_id)
    references betonagens.fcq (id, modelo_impresso_id),
  -- a secção vem da linha, não do cliente
  constraint fcq_item_linha_fk foreign key (modelo_impresso_id, linha_codigo, seccao)
    references betonagens.fcq_linha (modelo_impresso_id, codigo, seccao),
  constraint fcq_item_sequencia_fk foreign key (organizacao_id, dispositivo_id, sequencia_dispositivo)
    references betonagens.sequencia_dispositivo (organizacao_id, dispositivo_id, sequencia),
  constraint fcq_item_coordenadas_coerentes check ((latitude is null) = (longitude is null)),
  constraint fcq_item_momento_declarado_passado check (momento_declarado <= recebido_em),
  -- um NC sem uma palavra a dizer o que está mal não serve para nada; o texto
  -- completo vai sempre ao anexo, o impresso leva o que couber em ~32 caracteres
  constraint fcq_item_nc_anotado
    check (valor <> 'NC' or length(btrim(coalesce(anotacao, ''))) >= 5),
  constraint fcq_item_substituicao_coerente
    check ((substitui_id is null) = (motivo_substituicao is null)),
  constraint fcq_item_substituicao_justificada
    check (substitui_id is null or length(btrim(motivo_substituicao)) >= 20)
);
-- um valor em vigor por linha e coluna
create unique index fcq_item_atual on betonagens.fcq_item
  (fcq_id, linha_codigo, coluna) where substituido_por_id is null;
create unique index fcq_item_substituicao_unica on betonagens.fcq_item
  (substituido_por_id) where substituido_por_id is not null;
create index fcq_item_por_seccao on betonagens.fcq_item (fcq_id, seccao, coluna);
create index fcq_item_por_registador on betonagens.fcq_item (registado_por);
create index fcq_item_por_substitui on betonagens.fcq_item (substitui_id);
create index fcq_item_por_obra on betonagens.fcq_item (obra_id);

comment on column betonagens.fcq_item.recebido_em is
  'C4 · a data de inspeção não é editável: é o momento do registo.';

-- ── hash do conteúdo assinado ───────────────────────────────────────────────
-- A assinatura não é da secção: é de um conjunto concreto de versões de itens.
-- Como qualquer correção gera um id novo, o hash muda mesmo que só a anotação
-- mude — e a anotação sai impressa, portanto faz parte do que foi assinado.
create function betonagens_priv.itens_hash(
  p_fcq_id uuid,
  p_seccao betonagens.fcq_seccao,
  p_coluna betonagens.fcq_coluna
)
returns bytea
language sql
stable
security definer
set search_path = ''
as $fn$
  select sha256(convert_to(
           coalesce(
             string_agg(i.linha_codigo || ':' || i.valor::text || ':' || i.id::text,
                        '|' order by i.linha_codigo),
             ''),
           'UTF8'))
    from betonagens.fcq_item i
   where i.fcq_id = p_fcq_id
     and i.seccao = p_seccao
     and i.coluna = p_coluna
     and i.substituido_por_id is null
$fn$;

-- ── assinatura por secção e coluna · totalmente imutável ────────────────────
-- A reassinatura é uma linha nova com versão, não uma alteração da anterior.
-- Aqui não se repete a exceção ao append-only de §1.10: a versão dá o mesmo
-- resultado sem tocar em nenhuma linha existente.
create table betonagens.fcq_seccao_assinatura (
  id                  uuid primary key default gen_random_uuid(),
  organizacao_id      uuid not null,
  obra_id             uuid not null,
  fcq_id              uuid not null,
  seccao              betonagens.fcq_seccao not null,
  coluna              betonagens.fcq_coluna not null,
  versao              integer not null check (versao > 0),
  substitui_id        uuid references betonagens.fcq_seccao_assinatura(id),
  motivo_reassinatura text,
  utilizador_id       uuid not null references betonagens.utilizador(id),
  nome_completo       text not null,       -- instantâneo do nome à data da assinatura
  nome_impresso       text not null,       -- D2 · abreviatura determinística
  assinado_em         timestamptz not null default now(),
  momento_declarado   timestamptz not null,
  dispositivo_id      text not null,
  latitude            numeric(9,6),
  longitude           numeric(9,6),
  itens_hash          bytea not null check (octet_length(itens_hash) = 32),
  hash                bytea not null check (octet_length(hash) = 32),
  constraint fcq_assinatura_fcq_fk foreign key (fcq_id, obra_id)
    references betonagens.fcq (id, obra_id),
  constraint fcq_assinatura_versao_unica unique (fcq_id, seccao, coluna, versao),
  constraint fcq_assinatura_primeira check ((versao = 1) = (substitui_id is null)),
  constraint fcq_assinatura_reassinatura_justificada
    check (versao = 1 or length(btrim(coalesce(motivo_reassinatura, ''))) >= 20),
  constraint fcq_assinatura_momento_declarado_passado
    check (momento_declarado <= assinado_em),
  constraint fcq_assinatura_coordenadas_coerentes check ((latitude is null) = (longitude is null))
);
create index fcq_assinatura_por_fcq on betonagens.fcq_seccao_assinatura (fcq_id, seccao, coluna, versao desc);
create index fcq_assinatura_por_utilizador on betonagens.fcq_seccao_assinatura (utilizador_id);
create index fcq_assinatura_por_substitui on betonagens.fcq_seccao_assinatura (substitui_id);
create index fcq_assinatura_por_obra on betonagens.fcq_seccao_assinatura (obra_id);

comment on column betonagens.fcq_seccao_assinatura.hash is
  'Q3 · nome + timestamp + hash. O hash inclui itens_hash, portanto a assinatura fica presa ao que foi assinado, não apenas ao momento.';

-- ── versões emitidas ────────────────────────────────────────────────────────
create table betonagens.fcq_versao (
  id                 uuid primary key default gen_random_uuid(),
  organizacao_id     uuid not null,
  obra_id            uuid not null,
  fcq_id             uuid not null,
  versao             integer not null check (versao > 0),
  modelo_impresso_id uuid not null references betonagens.modelo_impresso(id),
  conformidade       betonagens.fcq_conformidade not null,
  observacoes        text not null,
  dados              jsonb not null,        -- instantâneo dos números impressos
  ficheiro_pdf_id    uuid not null,
  ficheiro_anexo_id  uuid,
  sha256_pdf         bytea not null check (octet_length(sha256_pdf) = 32),
  emitida_por        uuid not null references betonagens.utilizador(id),
  emitida_em         timestamptz not null default now(),
  motivo_reemissao   text,
  autorizada_por     uuid references betonagens.utilizador(id),
  constraint fcq_versao_fcq_fk foreign key (fcq_id, obra_id)
    references betonagens.fcq (id, obra_id),
  constraint fcq_versao_pdf_fk foreign key (ficheiro_pdf_id, obra_id)
    references betonagens.ficheiro (id, obra_id),
  constraint fcq_versao_anexo_fk foreign key (ficheiro_anexo_id, obra_id)
    references betonagens.ficheiro (id, obra_id),
  constraint fcq_versao_unica unique (fcq_id, versao),
  -- D4 · reabertura nominal, justificada, versionada e contada
  constraint fcq_versao_reemissao_justificada
    check (versao = 1 or length(btrim(coalesce(motivo_reemissao, ''))) >= 20),
  -- a partir da segunda reabertura, escala para o diretor de qualidade
  constraint fcq_versao_reabertura_escalada
    check (versao < 3 or autorizada_por is not null)
);
create index fcq_versao_por_fcq on betonagens.fcq_versao (fcq_id, versao desc);
create index fcq_versao_por_emissor on betonagens.fcq_versao (emitida_por);
create index fcq_versao_por_autorizador on betonagens.fcq_versao (autorizada_por);
create index fcq_versao_por_pdf on betonagens.fcq_versao (ficheiro_pdf_id);
create index fcq_versao_por_anexo on betonagens.fcq_versao (ficheiro_anexo_id);
create index fcq_versao_por_obra on betonagens.fcq_versao (obra_id);

-- ── estado das secções ──────────────────────────────────────────────────────
-- "Assinatura em vigor" é uma derivação, não um campo que alguém marca: não se
-- esquece de marcar, não deriva, e é verificável por qualquer pessoa daqui a
-- dois anos com uma consulta.
-- security_invoker = true é obrigatório: sem isso a vista corre com os direitos
-- do dono e passa por cima da RLS.
create view betonagens.fcq_seccao_estado
with (security_invoker = true) as
select
  f.id                as fcq_id,
  f.organizacao_id,
  f.obra_id,
  s.seccao,
  c.coluna,
  (select count(*) from betonagens.fcq_linha l
    where l.modelo_impresso_id = f.modelo_impresso_id
      and l.seccao = s.seccao)                                  as linhas_da_seccao,
  (select count(*) from betonagens.fcq_item i
    where i.fcq_id = f.id and i.seccao = s.seccao and i.coluna = c.coluna
      and i.substituido_por_id is null)                         as itens_preenchidos,
  (select count(*) from betonagens.fcq_item i
    where i.fcq_id = f.id and i.seccao = s.seccao and i.coluna = c.coluna
      and i.substituido_por_id is null and i.valor = 'NC')      as itens_nao_conformes,
  a.id                as assinatura_id,
  a.versao            as assinatura_versao,
  a.utilizador_id     as assinada_por,
  a.nome_impresso,
  a.assinado_em,
  (a.id is not null)  as assinada,
  coalesce(a.itens_hash = betonagens_priv.itens_hash(f.id, s.seccao, c.coluna), false)
                      as em_vigor
from betonagens.fcq f
cross join (select unnest(enum_range(null::betonagens.fcq_seccao)) as seccao) s
cross join (select unnest(enum_range(null::betonagens.fcq_coluna)) as coluna) c
left join lateral (
  select x.*
    from betonagens.fcq_seccao_assinatura x
   where x.fcq_id = f.id and x.seccao = s.seccao and x.coluna = c.coluna
   order by x.versao desc
   limit 1
) a on true;

reset role;

grant execute on function betonagens_priv.itens_hash(
  uuid, betonagens.fcq_seccao, betonagens.fcq_coluna) to authenticated;

insert into betonagens.migracao (ficheiro) values ('0004_fcq.sql');
