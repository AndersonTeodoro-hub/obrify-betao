-- =============================================================================
-- 0005_alertas_excecoes_eventos.sql · Obrify Betão
--
-- Cria: alerta, excecao, evento_saida e os auxiliares que os escrevem.
-- Depende de: 0004.
--
-- Alerta e exceção são coisas diferentes e por isso são tabelas diferentes:
-- um alerta é uma condição detetada pelo sistema, que se resolve; uma exceção é
-- um desvio deliberado de uma pessoa, que não se resolve — fica contado.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0005_alertas_excecoes_eventos.sql') then
    raise exception 'A migração 0005_alertas_excecoes_eventos.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- ── alertas ─────────────────────────────────────────────────────────────────
create table betonagens.alerta (
  id               uuid primary key default gen_random_uuid(),
  organizacao_id   uuid not null,
  obra_id          uuid not null,
  pab_id           uuid,
  guia_id          uuid,
  fcq_id           uuid,
  tipo             betonagens.alerta_tipo not null,
  severidade       betonagens.alerta_severidade not null,
  mensagem         text not null check (length(btrim(mensagem)) >= 10),
  parametro_id     uuid references betonagens.parametro(id),
  criado_em        timestamptz not null default now(),
  resolvido_em     timestamptz,
  resolvido_por    uuid references betonagens.utilizador(id),
  motivo_resolucao text,
  constraint alerta_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id),
  constraint alerta_pab_fk foreign key (pab_id, obra_id)
    references betonagens.pab (id, obra_id),
  constraint alerta_guia_fk foreign key (guia_id, obra_id)
    references betonagens.guia_remessa (id, obra_id),
  constraint alerta_fcq_fk foreign key (fcq_id, obra_id)
    references betonagens.fcq (id, obra_id),
  constraint alerta_resolucao_nominal check ((resolvido_em is null) = (resolvido_por is null)),
  -- C5 das brechas · um alerta não se ignora: resolve-se com ação e motivo, ou
  -- fica aberto. Não existe botão de dispensar.
  constraint alerta_resolucao_justificada
    check (resolvido_em is null or length(btrim(coalesce(motivo_resolucao, ''))) >= 20)
);
create index alerta_abertos on betonagens.alerta (obra_id, severidade, criado_em)
  where resolvido_em is null;
create index alerta_por_pab on betonagens.alerta (pab_id);
create index alerta_por_guia on betonagens.alerta (guia_id);
create index alerta_por_fcq on betonagens.alerta (fcq_id);
create index alerta_por_resolvedor on betonagens.alerta (resolvido_por);
create index alerta_por_parametro on betonagens.alerta (parametro_id);

comment on column betonagens.alerta.parametro_id is
  'D3 · qual foi o limiar aplicado. Alterar o limiar depois não muda os alertas antigos.';

-- ── exceções ────────────────────────────────────────────────────────────────
-- As quatro condições da regra geral das brechas: nominal (utilizador_id),
-- justificada (>= 20 caracteres e diferente da última do próprio),
-- visível (entra na fila e no resumo), contada (conta-se por obra e por pessoa).
create table betonagens.excecao (
  id                       uuid primary key default gen_random_uuid(),
  organizacao_id           uuid not null,
  obra_id                  uuid not null,
  tipo                     betonagens.excecao_tipo not null,
  entidade                 text not null,
  entidade_id              uuid not null,
  utilizador_id            uuid not null references betonagens.utilizador(id),
  justificacao             text not null check (length(btrim(justificacao)) >= 20),
  justificacao_normalizada text not null,
  criada_em                timestamptz not null default now(),
  constraint excecao_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id)
);
create index excecao_por_obra on betonagens.excecao (obra_id, criada_em desc);
create index excecao_ultima_do_utilizador on betonagens.excecao (utilizador_id, criada_em desc);
create index excecao_por_entidade on betonagens.excecao (entidade, entidade_id);

-- ── eventos de domínio (outbox) ─────────────────────────────────────────────
-- Ninguém consome isto agora. Existe para que a integração futura na
-- obrify.tech não obrigue a mexer no domínio.
create table betonagens.evento_saida (
  id             bigint generated always as identity primary key,
  organizacao_id uuid not null,
  obra_id        uuid not null,
  tipo           text not null,
  agregado       text not null,
  agregado_id    uuid not null,
  payload        jsonb not null,
  ocorrido_em    timestamptz not null default now(),
  publicado_em   timestamptz,
  constraint evento_saida_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id),
  constraint evento_saida_tipo_conhecido
    check (tipo in ('PAB_APROVADO','BETONAGEM_FECHADA','FCQ_EMITIDA'))
);
create index evento_saida_por_publicar on betonagens.evento_saida (id) where publicado_em is null;
create index evento_saida_por_obra on betonagens.evento_saida (obra_id, ocorrido_em desc);

-- ── auxiliares de escrita ───────────────────────────────────────────────────

create function betonagens_priv.criar_alerta(
  p_organizacao_id uuid,
  p_obra_id        uuid,
  p_tipo           betonagens.alerta_tipo,
  p_severidade     betonagens.alerta_severidade,
  p_mensagem       text,
  p_pab_id         uuid default null,
  p_guia_id        uuid default null,
  p_fcq_id         uuid default null,
  p_parametro_id   uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id uuid;
begin
  insert into betonagens.alerta
    (organizacao_id, obra_id, pab_id, guia_id, fcq_id, tipo, severidade, mensagem, parametro_id)
  values
    (p_organizacao_id, p_obra_id, p_pab_id, p_guia_id, p_fcq_id,
     p_tipo, p_severidade, p_mensagem, p_parametro_id)
  returning id into v_id;
  return v_id;
end
$fn$;

-- C6 · justificação com um mínimo de caracteres e nunca reaproveitada da
-- anterior do mesmo utilizador. A comparação é com a última, como está escrito
-- nas brechas: um índice único global proibiria repetir um motivo legítimo dois
-- anos depois. É uma regra temporal e por isso vive na função.
create function betonagens_priv.registar_excecao(
  p_organizacao_id uuid,
  p_obra_id        uuid,
  p_tipo           betonagens.excecao_tipo,
  p_entidade       text,
  p_entidade_id    uuid,
  p_utilizador_id  uuid,
  p_justificacao   text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_norm   text;
  v_ultima text;
  v_id     uuid;
begin
  if p_justificacao is null or length(btrim(p_justificacao)) < 20 then
    raise exception
      'A justificação tem de ter pelo menos 20 caracteres. Escreveu %.',
      length(btrim(coalesce(p_justificacao, '')))
      using errcode = 'PT422';
  end if;

  v_norm := lower(regexp_replace(btrim(p_justificacao), '\s+', ' ', 'g'));

  select e.justificacao_normalizada into v_ultima
    from betonagens.excecao e
   where e.utilizador_id = p_utilizador_id
   order by e.criada_em desc, e.id desc
   limit 1;

  if v_ultima is not null and v_ultima = v_norm then
    raise exception
      'Esta justificação é igual à última que registou. Cada exceção precisa da sua própria razão.'
      using errcode = 'PT422';
  end if;

  insert into betonagens.excecao
    (organizacao_id, obra_id, tipo, entidade, entidade_id,
     utilizador_id, justificacao, justificacao_normalizada)
  values
    (p_organizacao_id, p_obra_id, p_tipo, p_entidade, p_entidade_id,
     p_utilizador_id, btrim(p_justificacao), v_norm)
  returning id into v_id;

  return v_id;
end
$fn$;

create function betonagens_priv.emitir_evento(
  p_organizacao_id uuid,
  p_obra_id        uuid,
  p_tipo           text,
  p_agregado       text,
  p_agregado_id    uuid,
  p_payload        jsonb
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id bigint;
begin
  insert into betonagens.evento_saida
    (organizacao_id, obra_id, tipo, agregado, agregado_id, payload)
  values
    (p_organizacao_id, p_obra_id, p_tipo, p_agregado, p_agregado_id, p_payload)
  returning id into v_id;
  return v_id;
end
$fn$;

reset role;

insert into betonagens.migracao (ficheiro) values ('0005_alertas_excecoes_eventos.sql');
