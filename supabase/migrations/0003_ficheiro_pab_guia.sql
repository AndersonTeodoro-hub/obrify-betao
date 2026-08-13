-- =============================================================================
-- 0003_ficheiro_pab_guia.sql · Obrify Betão
--
-- Cria: ficheiro, pab, sequencia_dispositivo, guia_remessa.
-- Depende de: 0002.
--
-- É aqui que ficam INV1 (pab_id NOT NULL + FK), INV2 (unicidade da guia por
-- central e ano) e INV3 (unicidade do sha256 do ficheiro de guia).
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0003_ficheiro_pab_guia.sql') then
    raise exception 'A migração 0003_ficheiro_pab_guia.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- ── ficheiro ─────────────────────────────────────────────────────────────────
-- A base de dados guarda a referência; os bytes vivem no Storage. O sha256 é
-- sempre calculado no servidor — o hash que vier do cliente não vale nada.
create table betonagens.ficheiro (
  id              uuid primary key,                 -- UUIDv7 gerado no dispositivo
  organizacao_id  uuid not null,
  obra_id         uuid not null,
  tipo            betonagens.ficheiro_tipo not null,
  origem          betonagens.ficheiro_origem not null,
  caminho_storage text not null unique,
  sha256          bytea not null check (octet_length(sha256) = 32),
  bytes           bigint not null check (bytes > 0),
  mime            text not null,
  carregado_por   uuid not null references betonagens.utilizador(id),
  carregado_em    timestamptz not null default now(),
  constraint ficheiro_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id),
  constraint ficheiro_id_obra unique (id, obra_id)
);
-- INV3 · B6 · a mesma fotografia não entra duas vezes
create unique index ficheiro_guia_sha256_unico
  on betonagens.ficheiro (organizacao_id, sha256) where tipo = 'GUIA';
create index ficheiro_por_obra on betonagens.ficheiro (obra_id, tipo);
create index ficheiro_por_carregador on betonagens.ficheiro (carregado_por);

comment on column betonagens.ficheiro.origem is
  'C1 · CAMARA é o caminho normal (getUserMedia). GALERIA só por exceção nominal e justificada.';

-- ── PAB ──────────────────────────────────────────────────────────────────────
create table betonagens.pab (
  id                                  uuid primary key default gen_random_uuid(),
  organizacao_id                      uuid not null,
  obra_id                             uuid not null,
  frente_id                           uuid not null,
  numero                              integer not null check (numero > 0),
  elemento                            text not null check (length(btrim(elemento)) >= 3),
  volume_previsto_m3                  numeric(10,2) not null check (volume_previsto_m3 > 0),
  classe_betao                        text not null check (length(btrim(classe_betao)) >= 3),
  classe_exposicao                    text,
  dmax_agregado_mm                    integer check (dmax_agregado_mm > 0),
  classe_consistencia                 text,
  data_pedido                         date not null,
  data_prevista                       date not null,
  estado                              betonagens.pab_estado not null,
  ficheiro_impresso_id                uuid,
  observacoes                         text,
  submetido_por                       uuid not null references betonagens.utilizador(id),
  submetido_em                        timestamptz not null,
  submetido_momento_declarado         timestamptz not null,
  aprovado_por                        uuid references betonagens.utilizador(id),
  aprovado_em                         timestamptz,
  aprovado_momento_declarado          timestamptz,
  rejeitado_por                       uuid references betonagens.utilizador(id),
  rejeitado_em                        timestamptz,
  motivo_rejeicao                     text,
  anulado_por                         uuid references betonagens.utilizador(id),
  anulado_em                          timestamptz,
  motivo_anulacao                     text,
  betonagem_fechada_por               uuid references betonagens.utilizador(id),
  betonagem_fechada_em                timestamptz,
  betonagem_fechada_momento_declarado timestamptz,
  constraint pab_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id),
  constraint pab_frente_fk foreign key (frente_id, obra_id)
    references betonagens.frente (id, obra_id),
  constraint pab_ficheiro_fk foreign key (ficheiro_impresso_id, obra_id)
    references betonagens.ficheiro (id, obra_id),
  constraint pab_numero_unico unique (obra_id, numero),
  constraint pab_id_obra unique (id, obra_id),
  constraint pab_datas_coerentes check (data_prevista >= data_pedido),
  -- B2 · não existe PAB genérico: elemento, volume e classe são obrigatórios e
  -- as constraints acima impedem "diversos" e volume zero.
  constraint pab_aprovacao_nominal check ((aprovado_em is null) = (aprovado_por is null)),
  constraint pab_aprovacao_declarada check ((aprovado_em is null) = (aprovado_momento_declarado is null)),
  constraint pab_rejeicao_nominal check ((rejeitado_em is null) = (rejeitado_por is null)),
  constraint pab_anulacao_nominal check ((anulado_em is null) = (anulado_por is null)),
  constraint pab_fecho_nominal check ((betonagem_fechada_em is null) = (betonagem_fechada_por is null)),
  constraint pab_fecho_declarado
    check ((betonagem_fechada_em is null) = (betonagem_fechada_momento_declarado is null)),
  -- C6 · uma recusa sem motivo escrito não é uma recusa
  constraint pab_motivo_rejeicao
    check (estado <> 'REJEITADO' or length(btrim(coalesce(motivo_rejeicao, ''))) >= 20),
  constraint pab_motivo_anulacao
    check (estado <> 'ANULADO' or length(btrim(coalesce(motivo_anulacao, ''))) >= 20),
  constraint pab_estado_exige_aprovacao
    check (estado not in ('APROVADO','EM_BETONAGEM','BETONADO','FCQ_FECHADA')
           or aprovado_em is not null),
  constraint pab_estado_exige_fecho
    check (estado not in ('BETONADO','FCQ_FECHADA') or betonagem_fechada_em is not null),
  -- cronologia sobre os momentos declarados (§1.9): offline não pode inverter
  -- uma sequência legítima só porque a sincronização chegou mais tarde
  constraint pab_cronologia_aprovacao
    check (aprovado_momento_declarado is null
           or aprovado_momento_declarado >= submetido_momento_declarado),
  constraint pab_cronologia_fecho
    check (betonagem_fechada_momento_declarado is null
           or betonagem_fechada_momento_declarado >= aprovado_momento_declarado)
);
create index pab_painel on betonagens.pab (obra_id, estado, data_prevista);
create index pab_por_frente on betonagens.pab (frente_id, estado);
create index pab_por_submissor on betonagens.pab (submetido_por);
create index pab_por_aprovador on betonagens.pab (aprovado_por);
create index pab_por_ficheiro on betonagens.pab (ficheiro_impresso_id);

-- ── sequência do dispositivo (C5, travão b) ─────────────────────────────────
-- Uma sequência monótona por dispositivo, partilhada por todas as escritas
-- offline (guias e itens da ficha). Serve para que não se possa enfiar um
-- registo no meio de uma fila já sincronizada. Não elimina a fraude em
-- telemóvel com root — encarece-a e deixa rasto.
create table betonagens.sequencia_dispositivo (
  organizacao_id    uuid not null references betonagens.organizacao(id),
  dispositivo_id    text not null check (length(btrim(dispositivo_id)) >= 8),
  sequencia         bigint not null check (sequencia > 0),
  utilizador_id     uuid not null references betonagens.utilizador(id),
  entidade          text not null,
  entidade_id       uuid not null,
  momento_declarado timestamptz not null,
  recebido_em       timestamptz not null default now(),
  primary key (organizacao_id, dispositivo_id, sequencia)
);
create index sequencia_dispositivo_por_utilizador
  on betonagens.sequencia_dispositivo (utilizador_id);

create function betonagens_priv.reservar_sequencia(
  p_organizacao_id    uuid,
  p_dispositivo_id    text,
  p_sequencia         bigint,
  p_utilizador_id     uuid,
  p_entidade          text,
  p_entidade_id       uuid,
  p_momento_declarado timestamptz
)
returns boolean            -- true = o relógio do dispositivo recuou face ao registo anterior
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_anterior timestamptz;
begin
  select max(s.momento_declarado) into v_anterior
    from betonagens.sequencia_dispositivo s
   where s.organizacao_id = p_organizacao_id
     and s.dispositivo_id = p_dispositivo_id
     and s.sequencia < p_sequencia;

  begin
    insert into betonagens.sequencia_dispositivo
      (organizacao_id, dispositivo_id, sequencia, utilizador_id,
       entidade, entidade_id, momento_declarado)
    values
      (p_organizacao_id, p_dispositivo_id, p_sequencia, p_utilizador_id,
       p_entidade, p_entidade_id, p_momento_declarado);
  exception when unique_violation then
    -- não é um catch silencioso: troca-se um erro genérico por um explícito
    raise exception
      'A sequência % do dispositivo % já foi usada. Registo repetido ou fila adulterada.',
      p_sequencia, p_dispositivo_id
      using errcode = 'PT409';
  end;

  -- Um recuo do relógio do dispositivo é sinal, não recusa: uma sincronização
  -- de NTP a meio do dia produz exactamente isto de forma legítima.
  return v_anterior is not null and p_momento_declarado < v_anterior;
end
$fn$;

-- ── guia de remessa ──────────────────────────────────────────────────────────
create table betonagens.guia_remessa (
  id                         uuid primary key,      -- UUIDv7 do dispositivo; idempotência da fila
  organizacao_id             uuid not null,
  obra_id                    uuid not null,
  pab_id                     uuid not null,         -- INV1 · R1
  central_id                 uuid not null,
  numero_guia                text not null check (length(btrim(numero_guia)) >= 1),
  ano_civil                  integer not null,      -- derivado por gatilho
  data_hora_betonagem        timestamptz not null,  -- descarga real, declarada
  hora_carga                 timestamptz,
  volume_m3                  numeric(10,2) not null check (volume_m3 > 0),
  classe_betao               text not null check (length(btrim(classe_betao)) >= 3),
  slump_mm                   integer check (slump_mm between 0 and 400),
  temperatura_c              numeric(4,1) check (temperatura_c between -20 and 80),
  ficheiro_id                uuid not null,
  conformidade               betonagens.guia_conformidade not null,
  registado_por              uuid not null references betonagens.utilizador(id),
  registado_por_fiscalizacao boolean not null,      -- D2
  momento_declarado          timestamptz not null,  -- relógio do dispositivo
  recebido_em                timestamptz not null default now(),  -- relógio do servidor: a autoridade
  dispositivo_id             text not null,
  sequencia_dispositivo      bigint not null,
  latitude                   numeric(9,6) check (latitude between -90 and 90),
  longitude                  numeric(9,6) check (longitude between -180 and 180),
  precisao_gps_m             numeric(6,1) check (precisao_gps_m >= 0),
  substitui_id               uuid references betonagens.guia_remessa(id),
  motivo_substituicao        text,
  -- DEFERRABLE porque a ligação para a frente tem de ser escrita ANTES da
  -- inserção do registo novo: os índices únicos parciais abaixo são
  -- verificados no INSERT e, sem isto, uma correção que mantenha o mesmo
  -- número de guia seria recusada pelo próprio índice.
  substituida_por_id         uuid references betonagens.guia_remessa(id)
                                  deferrable initially deferred,
  constraint guia_pab_fk foreign key (pab_id, obra_id)
    references betonagens.pab (id, obra_id),
  constraint guia_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id),
  constraint guia_central_fk foreign key (central_id, organizacao_id)
    references betonagens.central_betonagem (id, organizacao_id),
  constraint guia_ficheiro_fk foreign key (ficheiro_id, obra_id)
    references betonagens.ficheiro (id, obra_id),
  constraint guia_sequencia_fk foreign key (organizacao_id, dispositivo_id, sequencia_dispositivo)
    references betonagens.sequencia_dispositivo (organizacao_id, dispositivo_id, sequencia),
  constraint guia_id_obra unique (id, obra_id),
  constraint guia_coordenadas_coerentes check ((latitude is null) = (longitude is null)),
  -- C5 travão (a): o dispositivo não pode declarar um momento no futuro do servidor
  constraint guia_momento_declarado_passado check (momento_declarado <= recebido_em),
  constraint guia_carga_antes_descarga
    check (hora_carga is null or hora_carga <= data_hora_betonagem),
  -- B3 · a correcção traz o seu motivo, e o motivo vive no registo novo
  constraint guia_substituicao_coerente
    check ((substitui_id is null) = (motivo_substituicao is null)),
  constraint guia_substituicao_justificada
    check (substitui_id is null or length(btrim(motivo_substituicao)) >= 20)
);

-- INV2 · B5 · a mesma guia nunca serve dois PAB.
-- O ano civil entra na chave porque não está confirmado se as centrais
-- reciclam a numeração ao ano: assim a chave é segura nos dois cenários.
-- A CONFIRMAR com a prática real das centrais.
create unique index guia_unica_por_central on betonagens.guia_remessa
  (organizacao_id, central_id, numero_guia, ano_civil)
  where substituida_por_id is null;

-- uma guia é substituída no máximo uma vez
create unique index guia_substituicao_unica on betonagens.guia_remessa
  (substituida_por_id) where substituida_por_id is not null;

-- Um ficheiro serve uma guia em vigor. Parcial, e não constraint simples,
-- porque uma correção de transcrição usa a mesma fotografia: quando a guia
-- anterior deixa de estar em vigor, liberta o ficheiro para a que a substitui.
create unique index guia_ficheiro_unico on betonagens.guia_remessa
  (ficheiro_id) where substituida_por_id is null;

create index guia_por_pab on betonagens.guia_remessa (pab_id);
create index guia_por_obra on betonagens.guia_remessa (obra_id, data_hora_betonagem desc);
create index guia_por_registador on betonagens.guia_remessa (registado_por);
create index guia_por_substitui on betonagens.guia_remessa (substitui_id);
-- B8 · deteção de saltos na sequência por central e dia
create index guia_sequencia_central on betonagens.guia_remessa
  (central_id, ano_civil, numero_guia);

comment on column betonagens.guia_remessa.pab_id is
  'R1 · INV1 · a coluna que resolve o problema todo. NOT NULL desde a primeira migração, sem exceções de arranque.';
comment on column betonagens.guia_remessa.recebido_em is
  'B7 · relógio do servidor. É esta a autoridade; momento_declarado é metadado do dispositivo.';

-- ano_civil derivado do momento real da betonagem, em hora de Lisboa.
-- Gatilho e não coluna gerada: extract(... at time zone ...) é STABLE, não
-- IMMUTABLE, e o PostgreSQL recusa-a numa coluna gerada. Como a tabela não
-- aceita UPDATE, o valor não pode divergir depois.
create function betonagens_priv.derivar_ano_civil()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  NEW.ano_civil := extract(year from (NEW.data_hora_betonagem at time zone 'Europe/Lisbon'))::integer;
  return NEW;
end
$fn$;

create trigger guia_remessa_ano_civil
  before insert on betonagens.guia_remessa
  for each row execute function betonagens_priv.derivar_ano_civil();

reset role;

insert into betonagens.migracao (ficheiro) values ('0003_ficheiro_pab_guia.sql');
