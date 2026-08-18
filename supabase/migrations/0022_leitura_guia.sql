-- =============================================================================
-- 0022_leitura_guia.sql · Obrify Betão
--
-- A guia de remessa lida por modelo de visão, e a proveniência de cada campo.
--
-- ── O PROBLEMA QUE ISTO RESOLVE ─────────────────────────────────────────────
-- Até aqui o empreiteiro transcrevia a guia de papel para o formulário, e o
-- servidor cruzava com o PAB aquilo que ele escreveu. Quem escreve o que quer
-- passa em qualquer regra: bastava escrever a classe do PAB para a R2 nunca
-- disparar. A fotografia estava lá — como prova — mas ninguém a lia.
--
-- Agora lê-se. Uma Edge Function manda a fotografia a um modelo de visão, o
-- extraído fica aqui, e o servidor compara o que foi submetido com o que foi
-- lido. O empreiteiro deixa de ser a única fonte do que a guia diz.
--
-- ── PORQUE É QUE A LEITURA É UMA TABELA, E NÃO COLUNAS NA GUIA ──────────────
-- Duas razões, ambas do esquema que já existe:
--   1. betonagens.guia_remessa é append-only (gatilho guia_remessa_imutavel da
--      0006). Uma coluna preenchida depois do INSERT não existe neste esquema.
--   2. A leitura acontece ANTES de a guia existir: fotografa-se, lê-se, e só
--      depois se confirma e regista. Não há linha onde a pôr.
--
-- ── A PROVENIÊNCIA É DERIVADA, NUNCA DECLARADA ──────────────────────────────
-- guia_remessa.proveniencia não é um parâmetro. gravar_guia compara, campo a
-- campo, o que chegou com o que a leitura diz, e escreve LIDO ou CORRIGIDO. Se
-- fosse o cliente a declará-la, um cliente adulterado declarava LIDO em cima de
-- um valor inventado — e a proveniência passava a decorar em vez de provar.
-- A ausência de uma chave é a terceira hipótese: manual.
--
-- ── AS DUAS REGRAS NOVAS ────────────────────────────────────────────────────
-- R9  · um campo CORRIGIDO cuja leitura tinha confiança ALTA baixa a guia a
--       COM_ALERTA. É a brecha C7/V12: confirmar sem ler, ou corrigir para o
--       valor que convém.
-- R10 · se a classe LIDA com confiança ALTA divergir da classe do PAB, a guia é
--       NAO_CONFORME mesmo que o empreiteiro tenha escrito a classe do PAB. Sem
--       esta regra, ler a guia não fecha porta nenhuma: bastava reescrever o
--       campo. Guardada por ALTA para um engano do modelo não condenar betão
--       conforme.
-- Nenhuma das duas recusa: grava-se sempre, como manda a R2. A única recusa
-- nova é estrutural — a leitura tem de ser da fotografia que se está a
-- registar.
--
-- ── SEM GATILHO DE LEDGER, DECLARADO ────────────────────────────────────────
-- leitura_guia não entra no ledger. O que o ledger encadeia são os factos do
-- domínio, e o facto aqui é a guia: a linha dela no ledger passa a levar
-- leitura_id e proveniencia dentro de `dados`, porque registar_no_ledger grava
-- o tuplo inteiro. A leitura em si é o artefacto de uma chamada a um modelo —
-- fica imutável e legível, mas não é elo da cadeia. Se um dia for preciso
-- encadeá-la, é um gatilho e uma linha em com_ledger no verificador.
--
-- ── DROP + CREATE, E NÃO CREATE OR REPLACE ──────────────────────────────────
-- gravar_guia e registar_guia ganham um parâmetro. Em PostgreSQL, acrescentar
-- um parâmetro cria uma SOBRECARGA em vez de substituir — e duas sobrecargas
-- com defeitos tornam a chamada ambígua. Por isso caem e nascem outra vez.
-- corrigir_guia não muda: chama gravar_guia com os mesmos 20 argumentos
-- posicionais e o novo fica no valor por defeito. Uma correcção é um acto
-- manual, e é isso que a proveniência nula dela diz.
--
-- Termina com o revoke da convenção fixada pela 0015.
--
-- Depende de: 0021.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0022_leitura_guia.sql') then
    raise exception 'A migração 0022_leitura_guia.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- ── a leitura ───────────────────────────────────────────────────────────────
-- `extraido` guarda o JSON do modelo tal e qual, sem normalização: é a resposta
-- que o modelo deu àquela fotografia, e é contra ela que amanhã se explica
-- porque é que um campo ficou LIDO. Normalizar aqui era perder a prova.
create table betonagens.leitura_guia (
  id               uuid primary key,          -- gerado no dispositivo, como o ficheiro
  organizacao_id   uuid not null,
  obra_id          uuid not null,
  ficheiro_id      uuid not null,             -- a fotografia que foi lida
  modelo           text not null check (length(btrim(modelo)) >= 3),
  extraido         jsonb not null check (jsonb_typeof(extraido) = 'object'),
  tokens_entrada   integer not null check (tokens_entrada > 0),
  tokens_saida     integer not null check (tokens_saida > 0),
  lida_por         uuid not null references betonagens.utilizador(id),
  lida_em          timestamptz not null default now(),
  constraint leitura_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id),
  constraint leitura_ficheiro_fk foreign key (ficheiro_id, obra_id)
    references betonagens.ficheiro (id, obra_id)
);

create index leitura_guia_por_obra on betonagens.leitura_guia (obra_id, lida_em desc);
create index leitura_guia_por_ficheiro on betonagens.leitura_guia (ficheiro_id);
create index leitura_guia_por_leitor on betonagens.leitura_guia (lida_por);

comment on table betonagens.leitura_guia is
  'O que o modelo de visão leu na fotografia da guia, imutável. Não é o registo da guia: é a origem contra a qual a proveniência dos campos se deriva.';
comment on column betonagens.leitura_guia.modelo is
  'Qual o modelo que leu. Trocar de modelo não reescreve leituras antigas — cada uma diz quem a fez.';

alter table betonagens.leitura_guia enable row level security;

create policy leitura_guia_leitura on betonagens.leitura_guia
  for select
  to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create trigger leitura_guia_imutavel
  before update or delete on betonagens.leitura_guia
  for each row execute function betonagens_priv.impedir_alteracao();

-- ── a guia passa a poder apontar para a leitura ─────────────────────────────
-- Sem constraint sobre o vocabulário de `proveniencia`: um CHECK não pode ter
-- subconsulta, e o único escritor destas duas colunas é gravar_guia, que as
-- constrói a partir de uma lista fixa de campos. O que se verifica aqui é a
-- coerência entre as duas — uma proveniência sem leitura seria uma afirmação
-- sem origem.
alter table betonagens.guia_remessa
  add column leitura_id   uuid references betonagens.leitura_guia(id),
  add column proveniencia jsonb,
  add constraint guia_proveniencia_coerente
    check ((leitura_id is null) = (proveniencia is null)
           and (proveniencia is null or jsonb_typeof(proveniencia) = 'object'));

create index guia_por_leitura on betonagens.guia_remessa (leitura_id);

comment on column betonagens.guia_remessa.proveniencia is
  'Derivada no servidor por gravar_guia: LIDO se o valor submetido é igual ao lido, CORRIGIDO se difere. A ausência da chave é manual. O cliente não a envia.';

-- ── registar a leitura ──────────────────────────────────────────────────────
create function betonagens.registar_leitura_guia(
  p_id             uuid,
  p_ficheiro_id    uuid,
  p_modelo         text,
  p_extraido       jsonb,
  p_tokens_entrada integer,
  p_tokens_saida   integer
)
returns betonagens.leitura_guia
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor     betonagens.utilizador := betonagens_priv.exigir_actor();
  v_ficheiro  betonagens.ficheiro;
  v_existente betonagens.leitura_guia;
  v_leitura   betonagens.leitura_guia;
begin
  if p_id is null or p_ficheiro_id is null
     or p_modelo is null or length(btrim(p_modelo)) = 0
     or p_extraido is null
     or p_tokens_entrada is null or p_tokens_saida is null then
    raise exception 'Faltam campos obrigatórios no registo da leitura.'
      using errcode = 'PT422';
  end if;

  if jsonb_typeof(p_extraido) <> 'object' then
    raise exception 'O extraído tem de ser um objecto JSON, veio %.', jsonb_typeof(p_extraido)
      using errcode = 'PT422';
  end if;

  select * into v_ficheiro from betonagens.ficheiro f where f.id = p_ficheiro_id;
  if not found then
    raise exception 'O ficheiro % não está registado.', p_ficheiro_id using errcode = 'PT422';
  end if;
  if v_ficheiro.tipo <> 'GUIA' then
    raise exception 'O ficheiro % não é uma fotografia de guia.', p_ficheiro_id
      using errcode = 'PT422';
  end if;

  perform betonagens_priv.exigir_acesso_obra(v_actor, v_ficheiro.obra_id);

  -- idempotência: a mesma leitura reenviada devolve o que já lá está; a mesma
  -- chave com outro conteúdo é erro, não sobreposição
  select * into v_existente from betonagens.leitura_guia l where l.id = p_id;
  if found then
    if v_existente.ficheiro_id = p_ficheiro_id and v_existente.extraido = p_extraido then
      return v_existente;
    end if;
    raise exception 'A leitura % já está registada com outro conteúdo.', p_id
      using errcode = 'PT409';
  end if;

  insert into betonagens.leitura_guia
    (id, organizacao_id, obra_id, ficheiro_id, modelo, extraido,
     tokens_entrada, tokens_saida, lida_por)
  values
    (p_id, v_ficheiro.organizacao_id, v_ficheiro.obra_id, p_ficheiro_id,
     btrim(p_modelo), p_extraido, p_tokens_entrada, p_tokens_saida, v_actor.id)
  returning * into v_leitura;

  return v_leitura;
end
$fn$;

-- ── o núcleo da guia, com a leitura ─────────────────────────────────────────
drop function betonagens.registar_guia(
  uuid, uuid, uuid, text, timestamptz, numeric, text, uuid, timestamptz, text,
  bigint, timestamptz, integer, numeric, numeric, numeric, numeric);

drop function betonagens_priv.gravar_guia(
  betonagens.utilizador, uuid, uuid, uuid, text, timestamptz, numeric, text,
  uuid, timestamptz, text, bigint, timestamptz, integer, numeric, numeric,
  numeric, numeric, uuid, text);

create function betonagens_priv.gravar_guia(
  p_actor               betonagens.utilizador,
  p_id                  uuid,
  p_pab_id              uuid,
  p_central_id          uuid,
  p_numero_guia         text,
  p_data_hora_betonagem timestamptz,
  p_volume_m3           numeric,
  p_classe_betao        text,
  p_ficheiro_id         uuid,
  p_momento_declarado   timestamptz,
  p_dispositivo_id      text,
  p_sequencia           bigint,
  p_hora_carga          timestamptz,
  p_slump_mm            integer,
  p_temperatura_c       numeric,
  p_latitude            numeric,
  p_longitude           numeric,
  p_precisao_gps_m      numeric,
  p_substitui_id        uuid,
  p_motivo_substituicao text,
  p_leitura_id          uuid default null
)
returns betonagens.guia_remessa
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_pab        betonagens.pab;
  v_frente     betonagens.frente;
  v_ficheiro   betonagens.ficheiro;
  v_existente  betonagens.guia_remessa;
  v_anterior   betonagens.guia_remessa;
  v_guia       betonagens.guia_remessa;
  v_tol        betonagens.parametro;
  v_p_sinal    betonagens.parametro;
  v_p_elevado  betonagens.parametro;
  v_p_slump_min betonagens.parametro;
  v_p_slump_max betonagens.parametro;
  v_conf       betonagens.guia_conformidade := 'CONFORME';
  v_acumulado  numeric;
  v_limite     numeric;
  v_retrocesso boolean;
  v_atraso_h   numeric;
  v_dist       numeric;
  v_por_fisc   boolean;
  v_constraint text;
  -- leitura
  v_leitura    betonagens.leitura_guia;
  v_prov       jsonb;
  v_alta_corr  boolean := false;
  v_classe_lida text;
  v_classe_pab text;
  v_campo      text;
  v_declarado  text;
  v_lido       text;
  v_confianca  text;
begin
  -- A2 · nenhum campo obrigatório tem valor por defeito no servidor
  if p_id is null or p_pab_id is null or p_central_id is null
     or p_numero_guia is null or length(btrim(p_numero_guia)) = 0
     or p_data_hora_betonagem is null or p_volume_m3 is null
     or p_classe_betao is null or length(btrim(p_classe_betao)) = 0
     or p_ficheiro_id is null or p_momento_declarado is null
     or p_dispositivo_id is null or p_sequencia is null then
    raise exception
      'Faltam campos obrigatórios no registo da guia. Nenhum é assumido pelo servidor.'
      using errcode = 'PT422';
  end if;

  if p_volume_m3 <= 0 then
    raise exception 'O volume da guia tem de ser maior do que zero.' using errcode = 'PT422';
  end if;

  if p_momento_declarado > now() then
    raise exception 'O momento declarado está no futuro do relógio do servidor.'
      using errcode = 'PT422';
  end if;

  -- idempotência da fila offline: a mesma guia reenviada devolve o que já lá
  -- está; a mesma chave com outro conteúdo é erro, não sobreposição
  select * into v_existente from betonagens.guia_remessa g where g.id = p_id;
  if found then
    if v_existente.pab_id = p_pab_id
       and v_existente.numero_guia = btrim(p_numero_guia)
       and v_existente.volume_m3 = p_volume_m3
       and v_existente.classe_betao = btrim(p_classe_betao)
       and v_existente.ficheiro_id = p_ficheiro_id
       and v_existente.data_hora_betonagem = p_data_hora_betonagem then
      return v_existente;
    end if;
    raise exception 'A guia % já está registada com outro conteúdo.', p_id
      using errcode = 'PT409';
  end if;

  -- R1 · sem PAB não há guia. A chave estrangeira é o último travão; este é o
  -- primeiro, e dá uma mensagem que se percebe.
  select * into v_pab from betonagens.pab p where p.id = p_pab_id for update;
  if not found then
    raise exception 'Não existe o PAB %. Nenhuma guia entra sem PAB.', p_pab_id
      using errcode = 'PT422';
  end if;
  perform betonagens_priv.exigir_acesso_obra(p_actor, v_pab.obra_id);

  if p_substitui_id is null then
    if v_pab.estado not in ('APROVADO','EM_BETONAGEM') then
      raise exception
        'O PAB %  está em % e não aceita guias.', v_pab.numero, v_pab.estado
        using errcode = 'PT409';
    end if;
  else
    select * into v_anterior from betonagens.guia_remessa g where g.id = p_substitui_id;
    if not found then
      raise exception 'A guia a corrigir (%) não existe.', p_substitui_id using errcode = 'PT422';
    end if;
    if v_anterior.substituida_por_id is not null then
      raise exception 'A guia % já foi corrigida antes.', p_substitui_id using errcode = 'PT409';
    end if;
    if v_anterior.pab_id <> p_pab_id then
      raise exception 'A correção tem de ficar no mesmo PAB da guia original.' using errcode = 'PT422';
    end if;
    -- R7 · depois da FCQ fechada só por reabertura explícita.
    -- A seguir à confirmação de que a guia anterior é deste PAB, e não antes:
    -- avaliado primeiro, este teste falava do estado de um PAB que podia nem
    -- ser o da guia, e a mensagem apontava para o lado errado. Dívida A4.2,
    -- declarada a 2026-08-13 ao lado do teste, paga na 0019.
    if v_pab.estado not in ('APROVADO','EM_BETONAGEM','BETONADO') then
      raise exception
        'O PAB % está em % e as guias são read-only.', v_pab.numero, v_pab.estado
        using errcode = 'PT409';
    end if;
    if p_motivo_substituicao is null or length(btrim(p_motivo_substituicao)) < 20 then
      raise exception 'A correção precisa de um motivo com pelo menos 20 caracteres.'
        using errcode = 'PT422';
    end if;
  end if;

  -- V6 · betonar primeiro e pedir depois não passa. Compara-se declarado com
  -- declarado, senão uma aprovação feita sem rede recusaria a primeira guia.
  if p_data_hora_betonagem < v_pab.aprovado_momento_declarado then
    raise exception
      'A betonagem declarada (%) é anterior à aprovação do PAB (%).',
      p_data_hora_betonagem, v_pab.aprovado_momento_declarado
      using errcode = 'PT409';
  end if;

  select * into v_ficheiro from betonagens.ficheiro f where f.id = p_ficheiro_id;
  if not found then
    raise exception 'O ficheiro % não está registado.', p_ficheiro_id using errcode = 'PT422';
  end if;
  if v_ficheiro.tipo <> 'GUIA' then
    raise exception 'O ficheiro % não é uma fotografia de guia.', p_ficheiro_id using errcode = 'PT422';
  end if;
  if v_ficheiro.obra_id <> v_pab.obra_id then
    raise exception 'O ficheiro % é de outra obra.', p_ficheiro_id using errcode = 'PT422';
  end if;

  if not exists (
    select 1 from betonagens.central_betonagem c
     where c.id = p_central_id and c.organizacao_id = v_pab.organizacao_id and c.ativa
  ) then
    raise exception 'A central % não existe ou está inativa nesta organização.', p_central_id
      using errcode = 'PT422';
  end if;

  -- ── proveniência, derivada da leitura ─────────────────────────────────────
  -- A recusa estrutural: a leitura tem de ser da fotografia que se está a
  -- registar. É esta amarra que impede declarar a proveniência de outra foto.
  if p_leitura_id is not null then
    select * into v_leitura from betonagens.leitura_guia l where l.id = p_leitura_id;
    if not found then
      raise exception 'A leitura % não existe.', p_leitura_id using errcode = 'PT422';
    end if;
    if v_leitura.ficheiro_id <> p_ficheiro_id then
      raise exception
        'A leitura % é da fotografia %, e esta guia usa a fotografia %. A proveniência vem da fotografia que se regista, não de outra.',
        p_leitura_id, v_leitura.ficheiro_id, p_ficheiro_id
        using errcode = 'PT422';
    end if;

    v_prov := '{}'::jsonb;

    -- Quatro campos, e só quatro: os que se comparam por igualdade sem
    -- adivinhar nada. A central fica de fora porque o nome impresso
    -- («BETÃO LIZ - LAGOS») nunca bate certo com a designação da tabela por
    -- igualdade, e comparar nomes por aproximação era ruído a fingir de rigor.
    -- O slump fica de fora porque é manuscrito e caligrafia não se lê como
    -- dado. Ambos ficam em extraido, para o fiscal comparar com os olhos.
    -- ponytail: quando houver histórico que sustente uma correspondência com
    -- prova, a central passa a derivada como estes quatro.
    for v_campo, v_declarado in
      select c.campo, c.declarado from (values
        ('numero_guia'::text,  upper(btrim(p_numero_guia))),
        ('volume_m3',          trim(to_char(p_volume_m3, 'FM9999999990.00'))),
        ('classe_betao',       upper(replace(btrim(p_classe_betao), ' ', ''))),
        ('data',               to_char(p_data_hora_betonagem at time zone 'Europe/Lisbon',
                                       'YYYY-MM-DD'))
      ) as c(campo, declarado)
    loop
      v_lido := v_leitura.extraido -> v_campo ->> 'valor';
      v_confianca := v_leitura.extraido -> v_campo ->> 'confianca';

      -- Normaliza cada campo à sua maneira. O que não passar na guarda fica
      -- nulo e o campo conta como não lido: não se compara o que não se
      -- percebeu.
      v_lido := case v_campo
                  when 'numero_guia'  then upper(btrim(v_lido))
                  when 'classe_betao' then upper(replace(btrim(v_lido), ' ', ''))
                  when 'volume_m3'    then
                    case when v_lido ~ '^[0-9]+([.][0-9]+)?$'
                         then trim(to_char(v_lido::numeric, 'FM9999999990.00')) end
                  when 'data'         then
                    case when v_lido ~ '^\d{4}-\d{2}-\d{2}$' then v_lido end
                end;

      -- Sem valor ou sem confiança declarada: o campo é manual, e manual é a
      -- ausência da chave. Não se escreve LIDO sobre o que não foi lido.
      if v_lido is null or coalesce(btrim(v_confianca), '') = '' then
        continue;
      end if;

      if v_lido = v_declarado then
        v_prov := v_prov || jsonb_build_object(v_campo, 'LIDO');
      else
        v_prov := v_prov || jsonb_build_object(v_campo, 'CORRIGIDO');
        if v_confianca = 'ALTA' then
          v_alta_corr := true;
        end if;
      end if;
    end loop;

    if v_leitura.extraido -> 'classe_betao' ->> 'confianca' = 'ALTA' then
      v_classe_lida := upper(replace(
        btrim(v_leitura.extraido -> 'classe_betao' ->> 'valor'), ' ', ''));
    end if;
  end if;

  v_por_fisc := p_actor.perfil in ('FISCALIZACAO','DIRETOR_QUALIDADE');

  -- R2 · classe divergente: a guia grava-se na mesma, não se apaga; o desvio
  -- tem de ficar registado.
  if btrim(p_classe_betao) <> v_pab.classe_betao then
    v_conf := 'NAO_CONFORME';
  end if;

  -- R10 · a classe do papel manda. Se a leitura de confiança alta diz outra
  -- classe que não a do PAB, a guia é não conforme mesmo que quem registou
  -- tenha escrito a classe do PAB. Sem isto, ler a guia não fechava porta
  -- nenhuma: bastava reescrever o campo.
  v_classe_pab := upper(replace(btrim(v_pab.classe_betao), ' ', ''));
  if v_classe_lida is not null and v_classe_lida <> v_classe_pab then
    v_conf := 'NAO_CONFORME';
  end if;

  -- R3 · volume acumulado contra o previsto e a tolerância em vigor
  v_tol := betonagens_priv.parametro_em(
    v_pab.organizacao_id, v_pab.obra_id, 'tolerancia_volume_pct', p_data_hora_betonagem);

  select coalesce(sum(g.volume_m3), 0) into v_acumulado
    from betonagens.guia_remessa g
   where g.pab_id = v_pab.id
     and g.substituida_por_id is null
     and (p_substitui_id is null or g.id <> p_substitui_id);

  if v_tol.id is null then
    v_limite := null;
  else
    v_limite := v_pab.volume_previsto_m3 * (1 + v_tol.valor_num / 100);
  end if;

  if v_limite is not null and (v_acumulado + p_volume_m3) > v_limite and v_conf = 'CONFORME' then
    v_conf := 'COM_ALERTA';
  end if;

  -- R4 · slump face ao intervalo da classe de consistência do PAB
  if v_pab.classe_consistencia is not null and p_slump_mm is not null then
    v_p_slump_min := betonagens_priv.parametro_em(
      v_pab.organizacao_id, v_pab.obra_id,
      'slump_' || v_pab.classe_consistencia || '_min', p_data_hora_betonagem);
    v_p_slump_max := betonagens_priv.parametro_em(
      v_pab.organizacao_id, v_pab.obra_id,
      'slump_' || v_pab.classe_consistencia || '_max', p_data_hora_betonagem);
    if v_p_slump_min.id is not null and v_p_slump_max.id is not null then
      if p_slump_mm < v_p_slump_min.valor_num or p_slump_mm > v_p_slump_max.valor_num then
        if v_conf = 'CONFORME' then v_conf := 'COM_ALERTA'; end if;
      end if;
    end if;
  end if;

  -- R9 · corrigir por cima de uma leitura de confiança alta não é transcrever:
  -- é discordar do papel. A guia entra, e entra assinalada.
  if v_alta_corr and v_conf = 'CONFORME' then
    v_conf := 'COM_ALERTA';
  end if;

  v_retrocesso := betonagens_priv.reservar_sequencia(
    v_pab.organizacao_id, p_dispositivo_id, p_sequencia, p_actor.id,
    'guia_remessa', p_id, p_momento_declarado);

  begin
    insert into betonagens.guia_remessa
      (id, organizacao_id, obra_id, pab_id, central_id, numero_guia,
       ano_civil, data_hora_betonagem, hora_carga, volume_m3, classe_betao,
       slump_mm, temperatura_c, ficheiro_id, conformidade, registado_por,
       registado_por_fiscalizacao, momento_declarado, dispositivo_id,
       sequencia_dispositivo, latitude, longitude, precisao_gps_m,
       substitui_id, motivo_substituicao, leitura_id, proveniencia)
    values
      (p_id, v_pab.organizacao_id, v_pab.obra_id, v_pab.id, p_central_id,
       btrim(p_numero_guia), 0, p_data_hora_betonagem, p_hora_carga, p_volume_m3,
       btrim(p_classe_betao), p_slump_mm, p_temperatura_c, p_ficheiro_id, v_conf,
       p_actor.id, v_por_fisc, p_momento_declarado, p_dispositivo_id,
       p_sequencia, p_latitude, p_longitude, p_precisao_gps_m,
       p_substitui_id, nullif(btrim(coalesce(p_motivo_substituicao, '')), ''),
       p_leitura_id, v_prov)
    returning * into v_guia;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'guia_unica_por_central' then
      raise exception
        'A guia % da central indicada já está registada em % (INV2/B5). A mesma guia não serve dois PAB.',
        btrim(p_numero_guia),
        coalesce((select 'PAB ' || p.numero::text
                    from betonagens.guia_remessa g
                    join betonagens.pab p on p.id = g.pab_id
                   where g.organizacao_id = v_pab.organizacao_id
                     and g.central_id = p_central_id
                     and g.numero_guia = btrim(p_numero_guia)
                     and g.substituida_por_id is null
                   limit 1), 'outro PAB')
        using errcode = 'PT409';
    elsif v_constraint = 'guia_ficheiro_unico' then
      raise exception 'Esta fotografia já está associada a outra guia em vigor.'
        using errcode = 'PT409';
    else
      raise exception 'Colisão de unicidade em guia_remessa (%).',
        coalesce(v_constraint, 'desconhecida')
        using errcode = 'PT409';
    end if;
  end;

  -- ── alertas ───────────────────────────────────────────────────────────────
  -- Um alerta só para a classe: se o registo já diverge do PAB, é essa a frase
  -- que interessa; só quando o registo bate certo com o PAB e é a LEITURA que
  -- diverge é que se conta a outra história. Dois alertas para o mesmo facto
  -- ensinariam a fila do fiscal a ser lida na diagonal.
  if v_guia.classe_betao <> v_pab.classe_betao then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'CLASSE_DIVERGENTE'::betonagens.alerta_tipo, 'CRITICO'::betonagens.alerta_severidade,
      format('Guia %s entregue em %s; o PAB %s aprovou %s.',
             v_guia.numero_guia, v_guia.classe_betao, v_pab.numero, v_pab.classe_betao),
      v_pab.id, v_guia.id, null, null);
  elsif v_classe_lida is not null and v_classe_lida <> v_classe_pab then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'CLASSE_DIVERGENTE'::betonagens.alerta_tipo, 'CRITICO'::betonagens.alerta_severidade,
      format('R10 · a leitura da guia %s diz %s; o PAB %s aprovou %s e o registo foi feito em %s.',
             v_guia.numero_guia,
             v_leitura.extraido -> 'classe_betao' ->> 'valor',
             v_pab.numero, v_pab.classe_betao, v_guia.classe_betao),
      v_pab.id, v_guia.id, null, null);
  end if;

  if v_limite is null then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'LIMIAR_NAO_CONFIGURADO'::betonagens.alerta_tipo, 'INFO'::betonagens.alerta_severidade,
      'R3 por avaliar: não há tolerância de volume em vigor para esta obra.',
      v_pab.id, v_guia.id, null, null);
  elsif (v_acumulado + v_guia.volume_m3) > v_limite then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'VOLUME_EXCEDIDO'::betonagens.alerta_tipo, 'AVISO'::betonagens.alerta_severidade,
      format('Acumulado %s m3 no PAB %s para %s m3 previstos, acima da tolerância de %s%%.',
             round(v_acumulado + v_guia.volume_m3, 2), v_pab.numero,
             v_pab.volume_previsto_m3, v_tol.valor_num),
      v_pab.id, v_guia.id, null, v_tol.id);
  end if;

  if v_pab.classe_consistencia is not null and v_guia.slump_mm is not null then
    if v_p_slump_min.id is null or v_p_slump_max.id is null then
      perform betonagens_priv.criar_alerta(
        v_pab.organizacao_id, v_pab.obra_id,
        'LIMIAR_NAO_CONFIGURADO'::betonagens.alerta_tipo, 'INFO'::betonagens.alerta_severidade,
        format('R4 por avaliar: não há intervalo de slump em vigor para a classe %s.',
               v_pab.classe_consistencia),
        v_pab.id, v_guia.id, null, null);
    elsif v_guia.slump_mm < v_p_slump_min.valor_num or v_guia.slump_mm > v_p_slump_max.valor_num then
      perform betonagens_priv.criar_alerta(
        v_pab.organizacao_id, v_pab.obra_id,
        'SLUMP_FORA'::betonagens.alerta_tipo, 'AVISO'::betonagens.alerta_severidade,
        format('Slump %s mm fora do intervalo %s-%s mm da classe %s.',
               v_guia.slump_mm, v_p_slump_min.valor_num, v_p_slump_max.valor_num,
               v_pab.classe_consistencia),
        v_pab.id, v_guia.id, null, v_p_slump_min.id);
    end if;
  end if;

  -- C5 · o atraso nunca recusa o registo. Sinaliza, entra na fila e conta.
  v_atraso_h := extract(epoch from (v_guia.recebido_em - v_guia.momento_declarado)) / 3600.0;
  v_p_sinal := betonagens_priv.parametro_em(
    v_pab.organizacao_id, v_pab.obra_id, 'atraso_sinal_h', v_guia.recebido_em);
  v_p_elevado := betonagens_priv.parametro_em(
    v_pab.organizacao_id, v_pab.obra_id, 'atraso_elevado_h', v_guia.recebido_em);

  if v_p_sinal.id is null or v_p_elevado.id is null then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'LIMIAR_NAO_CONFIGURADO'::betonagens.alerta_tipo, 'INFO'::betonagens.alerta_severidade,
      'Janelas de atraso de sincronização por configurar; o atraso desta guia não foi avaliado.',
      v_pab.id, v_guia.id, null, null);
  elsif v_atraso_h >= v_p_elevado.valor_num then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'ATRASO_SINCRONIZACAO'::betonagens.alerta_tipo, 'CRITICO'::betonagens.alerta_severidade,
      format('Guia %s chegou %s h depois do momento declarado.',
             v_guia.numero_guia, round(v_atraso_h, 1)),
      v_pab.id, v_guia.id, null, v_p_elevado.id);
  elsif v_atraso_h >= v_p_sinal.valor_num then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'ATRASO_SINCRONIZACAO'::betonagens.alerta_tipo, 'AVISO'::betonagens.alerta_severidade,
      format('Guia %s chegou %s h depois do momento declarado.',
             v_guia.numero_guia, round(v_atraso_h, 1)),
      v_pab.id, v_guia.id, null, v_p_sinal.id);
  end if;

  -- C1 · a galeria já gerou exceção no registo do ficheiro; aqui garante-se que
  -- a guia entra sempre na fila do fiscal
  if v_ficheiro.origem = 'GALERIA' then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'ORIGEM_GALERIA'::betonagens.alerta_tipo, 'AVISO'::betonagens.alerta_severidade,
      format('A fotografia da guia %s não veio da câmara da aplicação.', v_guia.numero_guia),
      v_pab.id, v_guia.id, null, null);
  end if;

  if v_retrocesso then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'CRONOLOGIA_DISPOSITIVO'::betonagens.alerta_tipo, 'INFO'::betonagens.alerta_severidade,
      format('O relógio do dispositivo %s recuou entre registos.', p_dispositivo_id),
      v_pab.id, v_guia.id, null, null);
  end if;

  -- geofence: sinal, nunca trava
  select * into v_frente from betonagens.frente f where f.id = v_pab.frente_id;
  if v_frente.latitude is not null and v_frente.raio_m is not null
     and v_guia.latitude is not null then
    v_dist := betonagens_priv.distancia_m(
      v_frente.latitude, v_frente.longitude, v_guia.latitude, v_guia.longitude);
    if v_dist > v_frente.raio_m then
      perform betonagens_priv.criar_alerta(
        v_pab.organizacao_id, v_pab.obra_id,
        'GPS_FORA_FRENTE'::betonagens.alerta_tipo, 'INFO'::betonagens.alerta_severidade,
        format('Registo a %s m da frente %s (raio %s m).',
               round(v_dist), v_frente.designacao, v_frente.raio_m),
        v_pab.id, v_guia.id, null, null);
    end if;
  end if;

  -- §3 da spec · a primeira guia põe o PAB em betonagem
  if v_pab.estado = 'APROVADO' then
    update betonagens.pab set estado = 'EM_BETONAGEM' where id = v_pab.id;
  end if;

  return v_guia;
end
$fn$;

create function betonagens.registar_guia(
  p_id                  uuid,
  p_pab_id              uuid,
  p_central_id          uuid,
  p_numero_guia         text,
  p_data_hora_betonagem timestamptz,
  p_volume_m3           numeric,
  p_classe_betao        text,
  p_ficheiro_id         uuid,
  p_momento_declarado   timestamptz,
  p_dispositivo_id      text,
  p_sequencia           bigint,
  p_hora_carga          timestamptz default null,
  p_slump_mm            integer default null,
  p_temperatura_c       numeric default null,
  p_latitude            numeric default null,
  p_longitude           numeric default null,
  p_precisao_gps_m      numeric default null,
  p_leitura_id          uuid default null
)
returns betonagens.guia_remessa
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  return betonagens_priv.gravar_guia(
    betonagens_priv.exigir_actor(),
    p_id, p_pab_id, p_central_id, p_numero_guia, p_data_hora_betonagem,
    p_volume_m3, p_classe_betao, p_ficheiro_id, p_momento_declarado,
    p_dispositivo_id, p_sequencia, p_hora_carga, p_slump_mm, p_temperatura_c,
    p_latitude, p_longitude, p_precisao_gps_m, null, null, p_leitura_id);
end
$fn$;

reset role;

grant select on betonagens.leitura_guia to authenticated;

-- A leitura regista-se com o JWT de quem chamou, como o ficheiro e a guia. A
-- Edge Function ler-guia não usa chave de serviço em passo nenhum: lê o
-- ficheiro, descarrega a fotografia e regista a leitura com o token da sessão,
-- e é a RLS que decide. Por isso aqui não há service_role.
grant execute on function betonagens.registar_leitura_guia(uuid, uuid, text, jsonb, integer, integer)
  to authenticated;

grant execute on function betonagens.registar_guia(
  uuid, uuid, uuid, text, timestamptz, numeric, text, uuid, timestamptz, text,
  bigint, timestamptz, integer, numeric, numeric, numeric, numeric, uuid)
  to authenticated, service_role;

-- ── convenção fixada pela 0015 ──────────────────────────────────────────────
set role betonagens_servico;
revoke execute on all routines in schema betonagens, betonagens_priv from public;
reset role;

insert into betonagens.migracao (ficheiro) values ('0022_leitura_guia.sql');
