-- =============================================================================
-- 0006_ledger_append_only.sql · Obrify Betão
--
-- Cria: ledger encadeado por hash, gatilhos de imutabilidade, gatilho de
--       derivação da substituição, e a aplicação de tudo isso às tabelas.
-- Depende de: 0005.
--
-- O ledger é escrito por GATILHO, não pelas funções de serviço. Se fosse a
-- função a escrever, uma escrita directa em SQL escapava. Assim, mesmo o que for
-- feito à mão no SQL Editor fica encadeado — que é o que D1 exige.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0006_ledger_append_only.sql') then
    raise exception 'A migração 0006_ledger_append_only.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- ── ledger ──────────────────────────────────────────────────────────────────
-- organizacao_id não tem chave estrangeira de propósito: um registo de
-- auditoria tem de poder sobreviver a qualquer estado da tabela que descreve,
-- e a cadeia global (modelos de impresso) usa o uuid de zeros.
create table betonagens.ledger (
  id             bigint generated always as identity primary key,
  organizacao_id uuid not null,
  seq            bigint not null check (seq > 0),
  entidade       text not null,
  entidade_id    text not null,
  acao           text not null,
  utilizador_id  uuid references betonagens.utilizador(id),
  momento        timestamptz not null,
  dados          jsonb not null,
  hash_anterior  bytea check (octet_length(hash_anterior) = 32),
  hash           bytea not null check (octet_length(hash) = 32),
  constraint ledger_seq_unica unique (organizacao_id, seq),
  constraint ledger_primeiro_elo check ((seq = 1) = (hash_anterior is null))
);
create index ledger_por_entidade on betonagens.ledger (entidade, entidade_id);
create index ledger_por_utilizador on betonagens.ledger (utilizador_id, momento desc);

comment on column betonagens.ledger.utilizador_id is
  'Nulo significa escrita sem pessoa identificada — é um sinal de incidente, não um caso normal.';

create function betonagens_priv.registar_no_ledger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_rec         jsonb;
  v_org         uuid;
  v_entidade_id text;
  v_dados       jsonb;
  v_seq         bigint;
  v_anterior    bytea;
  v_momento     timestamptz := clock_timestamp();
  v_chaves      text[] := string_to_array(coalesce(TG_ARGV[0], 'id'), ',');
begin
  v_rec := to_jsonb(NEW);
  v_org := coalesce(v_rec ->> 'organizacao_id', v_rec ->> 'id')::uuid;

  select string_agg(v_rec ->> t.k, ':' order by t.ord)
    into v_entidade_id
    from unnest(v_chaves) with ordinality as t(k, ord);

  if TG_OP = 'INSERT' then
    v_dados := v_rec;
  else
    v_dados := jsonb_build_object('antes', to_jsonb(OLD), 'depois', v_rec);
  end if;

  -- Serializa a cadeia por organização. A 2 escritas por minuto sobra folga.
  -- ponytail: uma cadeia por organização é o tecto; se um dia houver contenção,
  -- parte-se a cadeia por obra.
  perform pg_advisory_xact_lock(hashtext('betonagens.ledger:' || v_org::text)::bigint);

  select coalesce(max(l.seq), 0) + 1 into v_seq
    from betonagens.ledger l
   where l.organizacao_id = v_org;

  select l.hash into v_anterior
    from betonagens.ledger l
   where l.organizacao_id = v_org
   order by l.seq desc
   limit 1;

  insert into betonagens.ledger
    (organizacao_id, seq, entidade, entidade_id, acao, utilizador_id,
     momento, dados, hash_anterior, hash)
  values
    (v_org, v_seq, TG_TABLE_NAME, v_entidade_id, TG_OP,
     betonagens_priv.utilizador_atual(), v_momento, v_dados, v_anterior,
     -- extract(epoch ...) e não v_momento::text: o texto de um timestamptz é
     -- renderizado no TimeZone da sessão, portanto quem escreve o elo e quem o
     -- verifica podiam obter strings diferentes para o mesmo instante — e INV6
     -- acusaria adulteração onde não houve nenhuma. Em PG >= 14 extract devolve
     -- numeric, cuja representação textual é determinística.
     sha256(convert_to(
       coalesce(encode(v_anterior, 'hex'), '') || '|' ||
       v_seq::text || '|' || TG_TABLE_NAME || '|' || v_entidade_id || '|' ||
       TG_OP || '|' || v_dados::text || '|' || extract(epoch from v_momento)::text,
       'UTF8')));

  return null;
end
$fn$;

-- ── imutabilidade ───────────────────────────────────────────────────────────
-- TG_ARGV[0] = lista de colunas que podem ser escritas uma única vez, de nulo
-- para valor. Sem argumento, nenhuma coluna pode mudar.
create function betonagens_priv.impedir_alteracao()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_permitidas text[] := case
                           when coalesce(TG_ARGV[0], '') = '' then '{}'::text[]
                           else string_to_array(TG_ARGV[0], ',')
                         end;
  v_antes      jsonb;
  v_depois     jsonb;
  v_alteradas  text[];
  v_coluna     text;
begin
  if TG_OP = 'DELETE' then
    raise exception
      'A tabela % é append-only e não aceita DELETE. Nada se apaga: anula-se ou corrige-se com registo novo.',
      TG_TABLE_NAME
      using errcode = 'PT403';
  end if;

  v_antes  := to_jsonb(OLD);
  v_depois := to_jsonb(NEW);

  select coalesce(array_agg(e.key), '{}'::text[])
    into v_alteradas
    from jsonb_each(v_depois) e
   where e.value is distinct from v_antes -> e.key;

  foreach v_coluna in array v_alteradas loop
    if not (v_coluna = any (v_permitidas)) then
      raise exception
        'A tabela % é append-only: a coluna % não pode ser alterada. Correções criam registo novo.',
        TG_TABLE_NAME, v_coluna
        using errcode = 'PT403';
    end if;
    if coalesce(v_antes -> v_coluna, 'null'::jsonb) <> 'null'::jsonb then
      raise exception
        'A coluna %.% só pode ser escrita uma vez, de nulo para valor.',
        TG_TABLE_NAME, v_coluna
        using errcode = 'PT403';
    end if;
  end loop;

  return NEW;
end
$fn$;

-- B4 · DELETE revogado em todas as tabelas de domínio, incluindo as de estado
create function betonagens_priv.impedir_remocao()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  raise exception
    'DELETE revogado em %. Nada se apaga: anula-se com motivo. A contagem de registos nunca decresce.',
    TG_TABLE_NAME
    using errcode = 'PT403';
end
$fn$;

-- ── derivação da substituição (§1.10) ───────────────────────────────────────
-- O registo novo traz substitui_id e o motivo. Este gatilho é o único que
-- escreve a ligação para a frente no registo anterior. Nenhum facto é alterado.
--
-- É BEFORE INSERT, não AFTER: os índices únicos parciais (guia em vigor, item
-- em vigor, ficheiro em vigor) são verificados no momento do INSERT, portanto a
-- linha anterior tem de deixar de estar em vigor antes disso. É a chave
-- estrangeira DEFERRABLE que permite apontar para uma linha que ainda não
-- existe; a verificação acontece no commit.
create function betonagens_priv.marcar_substituido()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_afectadas integer;
begin
  if NEW.substitui_id is null then
    return NEW;
  end if;

  if NEW.substitui_id = NEW.id then
    raise exception 'Um registo não pode substituir-se a si próprio.'
      using errcode = 'PT422';
  end if;

  execute format(
    'update %I.%I set %I = $1 where id = $2 and %I is null',
    TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[0], TG_ARGV[0])
  using NEW.id, NEW.substitui_id;

  get diagnostics v_afectadas = row_count;

  if v_afectadas <> 1 then
    raise exception
      'O registo % de %.% não existe ou já tinha sido substituído.',
      NEW.substitui_id, TG_TABLE_SCHEMA, TG_TABLE_NAME
      using errcode = 'PT409';
  end if;

  return NEW;
end
$fn$;

-- =============================================================================
-- Aplicação dos gatilhos
-- =============================================================================

-- ── tabelas append-only, sem nenhuma coluna alterável ───────────────────────
create trigger ficheiro_imutavel
  before update or delete on betonagens.ficheiro
  for each row execute function betonagens_priv.impedir_alteracao();

create trigger sequencia_dispositivo_imutavel
  before update or delete on betonagens.sequencia_dispositivo
  for each row execute function betonagens_priv.impedir_alteracao();

create trigger parametro_imutavel
  before update or delete on betonagens.parametro
  for each row execute function betonagens_priv.impedir_alteracao();

create trigger excecao_imutavel
  before update or delete on betonagens.excecao
  for each row execute function betonagens_priv.impedir_alteracao();

create trigger fcq_assinatura_imutavel
  before update or delete on betonagens.fcq_seccao_assinatura
  for each row execute function betonagens_priv.impedir_alteracao();

create trigger fcq_versao_imutavel
  before update or delete on betonagens.fcq_versao
  for each row execute function betonagens_priv.impedir_alteracao();

create trigger ledger_imutavel
  before update or delete on betonagens.ledger
  for each row execute function betonagens_priv.impedir_alteracao();

-- ── tabelas append-only com uma única coluna escrita uma só vez ─────────────
create trigger guia_remessa_imutavel
  before update or delete on betonagens.guia_remessa
  for each row execute function betonagens_priv.impedir_alteracao('substituida_por_id');

create trigger fcq_item_imutavel
  before update or delete on betonagens.fcq_item
  for each row execute function betonagens_priv.impedir_alteracao('substituido_por_id');

create trigger alerta_imutavel
  before update or delete on betonagens.alerta
  for each row execute function betonagens_priv.impedir_alteracao('resolvido_em,resolvido_por,motivo_resolucao');

create trigger evento_saida_imutavel
  before update or delete on betonagens.evento_saida
  for each row execute function betonagens_priv.impedir_alteracao('publicado_em');

create trigger utilizador_obra_imutavel
  before update or delete on betonagens.utilizador_obra
  for each row execute function betonagens_priv.impedir_alteracao('revogado_em,revogado_por');

-- ── tabelas de estado: alteram-se pelas funções de serviço, nunca se apagam ──
create trigger organizacao_sem_delete
  before delete on betonagens.organizacao
  for each row execute function betonagens_priv.impedir_remocao();

create trigger utilizador_sem_delete
  before delete on betonagens.utilizador
  for each row execute function betonagens_priv.impedir_remocao();

create trigger obra_sem_delete
  before delete on betonagens.obra
  for each row execute function betonagens_priv.impedir_remocao();

create trigger frente_sem_delete
  before delete on betonagens.frente
  for each row execute function betonagens_priv.impedir_remocao();

create trigger central_sem_delete
  before delete on betonagens.central_betonagem
  for each row execute function betonagens_priv.impedir_remocao();

create trigger pab_sem_delete
  before delete on betonagens.pab
  for each row execute function betonagens_priv.impedir_remocao();

create trigger fcq_sem_delete
  before delete on betonagens.fcq
  for each row execute function betonagens_priv.impedir_remocao();

create trigger modelo_impresso_sem_delete
  before delete on betonagens.modelo_impresso
  for each row execute function betonagens_priv.impedir_remocao();

create trigger fcq_linha_sem_delete
  before delete on betonagens.fcq_linha
  for each row execute function betonagens_priv.impedir_remocao();

-- ── derivação da substituição ───────────────────────────────────────────────
-- Nomes escolhidos para correrem depois de guia_remessa_ano_civil: os gatilhos
-- BEFORE da mesma tabela disparam por ordem alfabética.
create trigger guia_remessa_substituicao
  before insert on betonagens.guia_remessa
  for each row execute function betonagens_priv.marcar_substituido('substituida_por_id');

create trigger fcq_item_substituicao
  before insert on betonagens.fcq_item
  for each row execute function betonagens_priv.marcar_substituido('substituido_por_id');

-- ── ledger ──────────────────────────────────────────────────────────────────
-- Ficam de fora, por serem derivados de factos já encadeados:
--   sequencia_dispositivo (o conteúdo repete-se na guia ou no item),
--   evento_saida (é a projecção de transições já ledgeradas),
--   modelo_impresso e fcq_linha (dados de referência que só o SQL Editor
--   escreve, e cuja integridade é garantida pelo sha256 verificado no motor).
create trigger organizacao_ledger
  after insert or update on betonagens.organizacao
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger utilizador_ledger
  after insert or update on betonagens.utilizador
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger obra_ledger
  after insert or update on betonagens.obra
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger frente_ledger
  after insert or update on betonagens.frente
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger utilizador_obra_ledger
  after insert or update on betonagens.utilizador_obra
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger central_ledger
  after insert or update on betonagens.central_betonagem
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger parametro_ledger
  after insert or update on betonagens.parametro
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger ficheiro_ledger
  after insert or update on betonagens.ficheiro
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger pab_ledger
  after insert or update on betonagens.pab
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger guia_remessa_ledger
  after insert or update on betonagens.guia_remessa
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger fcq_ledger
  after insert or update on betonagens.fcq
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger fcq_item_ledger
  after insert or update on betonagens.fcq_item
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger fcq_assinatura_ledger
  after insert or update on betonagens.fcq_seccao_assinatura
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger fcq_versao_ledger
  after insert or update on betonagens.fcq_versao
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger alerta_ledger
  after insert or update on betonagens.alerta
  for each row execute function betonagens_priv.registar_no_ledger();

create trigger excecao_ledger
  after insert or update on betonagens.excecao
  for each row execute function betonagens_priv.registar_no_ledger();

reset role;

insert into betonagens.migracao (ficheiro) values ('0006_ledger_append_only.sql');
