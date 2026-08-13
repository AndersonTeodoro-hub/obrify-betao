-- =============================================================================
-- 0008_servico.sql · Obrify Betão
--
-- Cria: a camada de serviço (funções SECURITY DEFINER) e fecha os privilégios.
-- Depende de: 0007.
--
-- Regras que valem para TODAS as funções deste ficheiro:
--   · security definer, dono betonagens_servico, set search_path = ''
--   · a primeira coisa que fazem é identificar quem chama; nada é anónimo
--   · nenhum parâmetro obrigatório tem DEFAULT (A2)
--   · os erros saem com SQLSTATE 'PT403' / 'PT409' / 'PT422', que o PostgREST
--     traduz directamente no estado HTTP correspondente
--   · nenhum bloco de exceção engole um erro: quando existe, é para trocar uma
--     mensagem genérica por uma explícita e voltar a levantar
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0008_servico.sql') then
    raise exception 'A migração 0008_servico.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- =============================================================================
-- Arranque
-- =============================================================================

-- Única função sem actor: cria a organização, o primeiro ADMIN e os parâmetros
-- cujo valor já foi decidido. Não é concedida a ninguém — corre no SQL Editor.
create function betonagens.criar_organizacao(
  p_codigo            text,
  p_designacao        text,
  p_admin_nome        text,
  p_admin_email       text,
  p_admin_auth_user_id uuid
)
returns betonagens.organizacao
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_org   betonagens.organizacao;
  v_admin betonagens.utilizador;
begin
  insert into betonagens.organizacao (codigo, designacao)
  values (p_codigo, p_designacao)
  returning * into v_org;

  insert into betonagens.utilizador (organizacao_id, auth_user_id, nome, email, perfil)
  values (v_org.id, p_admin_auth_user_id, p_admin_nome, p_admin_email, 'ADMIN')
  returning * into v_admin;

  -- Só se semeia o que já foi decidido. Limiares normativos (slump, tempo de
  -- carga a descarga, temperatura) NÃO são semeados: enquanto não estiverem
  -- confirmados contra a NP EN 206, a NP EN 13670 e o caderno de encargos, a
  -- regra correspondente fica por avaliar e diz isso em voz alta, através de um
  -- alerta LIMIAR_NAO_CONFIGURADO. Inventar um valor seria pior.
  insert into betonagens.parametro
    (organizacao_id, obra_id, chave, valor_num, valor_txt, unidade,
     vigente_desde, definido_por, justificacao, normativo_confirmado, fonte)
  values
    (v_org.id, null, 'tolerancia_volume_pct', 10, null, '%',
     v_org.criada_em, v_admin.id,
     'Valor por defeito da organização, decidido na definição do módulo (Q5).',
     true, 'Decisão da direção do projeto. Não deriva de norma.'),
    (v_org.id, null, 'atraso_sinal_h', 4, null, 'h',
     v_org.criada_em, v_admin.id,
     'Janela a partir da qual o atraso de sincronização entra na fila do fiscal (C5).',
     true, 'Decisão da direção do projeto.'),
    (v_org.id, null, 'atraso_elevado_h', 24, null, 'h',
     v_org.criada_em, v_admin.id,
     'Janela a partir da qual o atraso de sincronização é sinal de risco elevado (C5).',
     true, 'Decisão da direção do projeto.'),
    (v_org.id, null, 'observacoes_modelo', null,
     'Betonagem coberta pelo PAB n.º {N}. {n} guias de remessa em anexo. ' ||
     'Volume total {real} m3 para {previsto} m3 previstos ({desvio}%). ' ||
     'Classe {classe} conforme aprovado.', null,
     v_org.criada_em, v_admin.id,
     'Texto-tipo do campo Observações do impresso I.CR.033 (D1).',
     true, 'Decisão da direção do projeto.'),
    (v_org.id, null, 'anotacao_marcador_anexo', null, 'ver anexo', null,
     v_org.criada_em, v_admin.id,
     'Marcador impresso na coluna de anotações quando o texto não cabe na largura medida.',
     true, 'Decisão da direção do projeto.');

  return v_org;
end
$fn$;

-- =============================================================================
-- Utilizadores, obras, frentes, centrais, acessos
-- =============================================================================

create function betonagens.registar_utilizador(
  p_auth_user_id uuid,
  p_nome         text,
  p_email        text,
  p_perfil       betonagens.perfil_utilizador
)
returns betonagens.utilizador
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor betonagens.utilizador := betonagens_priv.exigir_actor();
  v_novo  betonagens.utilizador;
begin
  perform betonagens_priv.exigir_perfil(v_actor, 'ADMIN'::betonagens.perfil_utilizador);

  insert into betonagens.utilizador (organizacao_id, auth_user_id, nome, email, perfil)
  values (v_actor.organizacao_id, p_auth_user_id, p_nome, p_email, p_perfil)
  returning * into v_novo;

  return v_novo;
end
$fn$;

create function betonagens.desativar_utilizador(p_utilizador_id uuid)
returns betonagens.utilizador
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor betonagens.utilizador := betonagens_priv.exigir_actor();
  v_alvo  betonagens.utilizador;
begin
  perform betonagens_priv.exigir_perfil(v_actor, 'ADMIN'::betonagens.perfil_utilizador);

  update betonagens.utilizador
     set ativo = false, desativado_em = now(), desativado_por = v_actor.id
   where id = p_utilizador_id
     and organizacao_id = v_actor.organizacao_id
     and ativo
  returning * into v_alvo;

  if not found then
    raise exception 'Utilizador % não encontrado na organização, ou já desativado.', p_utilizador_id
      using errcode = 'PT409';
  end if;

  -- D7 · a desativação impede escrita futura; o histórico mantém-se válido e
  -- atribuído, e as assinaturas antigas continuam a valer.
  return v_alvo;
end
$fn$;

create function betonagens.criar_obra(
  p_codigo       text,
  p_designacao   text,
  p_dono_obra    text default null,
  p_empreiteiro  text default null,
  p_fiscalizacao text default null
)
returns betonagens.obra
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor betonagens.utilizador := betonagens_priv.exigir_actor();
  v_obra  betonagens.obra;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'ADMIN'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  insert into betonagens.obra
    (organizacao_id, codigo, designacao, dono_obra, empreiteiro, fiscalizacao)
  values
    (v_actor.organizacao_id, p_codigo, p_designacao, p_dono_obra, p_empreiteiro, p_fiscalizacao)
  returning * into v_obra;

  return v_obra;
end
$fn$;

create function betonagens.criar_frente(
  p_obra_id    uuid,
  p_designacao text,
  p_latitude   numeric default null,
  p_longitude  numeric default null,
  p_raio_m     integer default null
)
returns betonagens.frente
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor  betonagens.utilizador := betonagens_priv.exigir_actor();
  v_frente betonagens.frente;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'ADMIN'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador,
    'FISCALIZACAO'::betonagens.perfil_utilizador);
  perform betonagens_priv.exigir_acesso_obra(v_actor, p_obra_id);

  insert into betonagens.frente
    (organizacao_id, obra_id, designacao, latitude, longitude, raio_m)
  values
    (v_actor.organizacao_id, p_obra_id, p_designacao, p_latitude, p_longitude, p_raio_m)
  returning * into v_frente;

  return v_frente;
end
$fn$;

create function betonagens.criar_central(
  p_designacao    text,
  p_prefixo_guias text default null
)
returns betonagens.central_betonagem
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor   betonagens.utilizador := betonagens_priv.exigir_actor();
  v_central betonagens.central_betonagem;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'ADMIN'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador,
    'FISCALIZACAO'::betonagens.perfil_utilizador);

  insert into betonagens.central_betonagem (organizacao_id, designacao, prefixo_guias)
  values (v_actor.organizacao_id, p_designacao, p_prefixo_guias)
  returning * into v_central;

  return v_central;
end
$fn$;

create function betonagens.atribuir_obra(
  p_utilizador_id uuid,
  p_obra_id       uuid
)
returns betonagens.utilizador_obra
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor betonagens.utilizador := betonagens_priv.exigir_actor();
  v_lig   betonagens.utilizador_obra;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'ADMIN'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  if not exists (
    select 1 from betonagens.utilizador u
     where u.id = p_utilizador_id and u.organizacao_id = v_actor.organizacao_id
  ) then
    raise exception 'O utilizador % não pertence a esta organização.', p_utilizador_id
      using errcode = 'PT422';
  end if;

  insert into betonagens.utilizador_obra
    (organizacao_id, utilizador_id, obra_id, atribuido_por)
  values
    (v_actor.organizacao_id, p_utilizador_id, p_obra_id, v_actor.id)
  returning * into v_lig;

  return v_lig;
end
$fn$;

create function betonagens.revogar_obra(
  p_utilizador_id uuid,
  p_obra_id       uuid
)
returns betonagens.utilizador_obra
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor betonagens.utilizador := betonagens_priv.exigir_actor();
  v_lig   betonagens.utilizador_obra;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'ADMIN'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  update betonagens.utilizador_obra
     set revogado_em = now(), revogado_por = v_actor.id
   where utilizador_id = p_utilizador_id
     and obra_id = p_obra_id
     and organizacao_id = v_actor.organizacao_id
     and revogado_em is null
  returning * into v_lig;

  if not found then
    raise exception 'Não há acesso activo do utilizador % à obra %.', p_utilizador_id, p_obra_id
      using errcode = 'PT409';
  end if;

  return v_lig;
end
$fn$;

-- D3 · limiares só editáveis pelo diretor de qualidade, com histórico
create function betonagens.definir_parametro(
  p_chave                text,
  p_vigente_desde        timestamptz,
  p_justificacao         text,
  p_obra_id              uuid default null,
  p_valor_num            numeric default null,
  p_valor_txt            text default null,
  p_unidade              text default null,
  p_normativo_confirmado boolean default false,
  p_fonte                text default null
)
returns betonagens.parametro
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor betonagens.utilizador := betonagens_priv.exigir_actor();
  v_param betonagens.parametro;
begin
  -- D3 · quem é avaliado não mexe no limiar pelo qual é avaliado
  perform betonagens_priv.exigir_perfil(
    v_actor, 'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  if p_obra_id is not null then
    perform betonagens_priv.exigir_acesso_obra(v_actor, p_obra_id);
  end if;

  if num_nonnulls(p_valor_num, p_valor_txt) <> 1 then
    raise exception 'Indique exactamente um valor: numérico ou textual.'
      using errcode = 'PT422';
  end if;

  insert into betonagens.parametro
    (organizacao_id, obra_id, chave, valor_num, valor_txt, unidade,
     vigente_desde, definido_por, justificacao, normativo_confirmado, fonte)
  values
    (v_actor.organizacao_id, p_obra_id, p_chave, p_valor_num, p_valor_txt, p_unidade,
     p_vigente_desde, v_actor.id, p_justificacao, p_normativo_confirmado, p_fonte)
  returning * into v_param;

  return v_param;
end
$fn$;

-- =============================================================================
-- Ficheiros
-- =============================================================================

-- O sha256 é calculado pela Edge Function que recebe os bytes, nunca pelo
-- cliente. C1 · a galeria é um caminho de exceção: nominal e justificado.
create function betonagens.registar_ficheiro(
  p_id                  uuid,
  p_obra_id             uuid,
  p_tipo                betonagens.ficheiro_tipo,
  p_origem              betonagens.ficheiro_origem,
  p_caminho_storage     text,
  p_sha256              bytea,
  p_bytes               bigint,
  p_mime                text,
  p_justificacao_galeria text default null
)
returns betonagens.ficheiro
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor      betonagens.utilizador := betonagens_priv.exigir_actor();
  v_ficheiro   betonagens.ficheiro;
  v_existente  betonagens.ficheiro;
  v_constraint text;
begin
  perform betonagens_priv.exigir_acesso_obra(v_actor, p_obra_id);

  if p_id is null or p_tipo is null or p_origem is null
     or p_caminho_storage is null or p_sha256 is null
     or p_bytes is null or p_mime is null then
    raise exception 'Faltam campos obrigatórios no registo do ficheiro.'
      using errcode = 'PT422';
  end if;

  -- idempotência da fila offline
  select * into v_existente from betonagens.ficheiro f where f.id = p_id;
  if found then
    if v_existente.sha256 = p_sha256 and v_existente.obra_id = p_obra_id then
      return v_existente;
    end if;
    raise exception 'O ficheiro % já existe com outro conteúdo.', p_id
      using errcode = 'PT409';
  end if;

  if p_origem = 'GALERIA' then
    if p_tipo <> 'GUIA' then
      raise exception 'A origem GALERIA só se aplica a fotografias de guia.'
        using errcode = 'PT422';
    end if;
    perform betonagens_priv.registar_excecao(
      v_actor.organizacao_id, p_obra_id, 'FOTO_GALERIA'::betonagens.excecao_tipo,
      'ficheiro', p_id, v_actor.id, p_justificacao_galeria);
  end if;

  begin
    insert into betonagens.ficheiro
      (id, organizacao_id, obra_id, tipo, origem, caminho_storage,
       sha256, bytes, mime, carregado_por)
    values
      (p_id, v_actor.organizacao_id, p_obra_id, p_tipo, p_origem, p_caminho_storage,
       p_sha256, p_bytes, p_mime, v_actor.id)
    returning * into v_ficheiro;
  exception when unique_violation then
    -- Não é um catch silencioso: identifica-se qual foi a colisão e volta a
    -- levantar com uma mensagem que se percebe. Uma mensagem errada é tão má
    -- como nenhuma.
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'ficheiro_guia_sha256_unico' then
      raise exception
        'Esta fotografia já foi carregada nesta organização (INV3). Fotografe a guia; não reutilize um ficheiro.'
        using errcode = 'PT409';
    elsif v_constraint = 'ficheiro_caminho_storage_key' then
      raise exception 'O caminho de armazenamento % já está ocupado.', p_caminho_storage
        using errcode = 'PT409';
    else
      raise exception 'Colisão de unicidade em ficheiro (%).', coalesce(v_constraint, 'desconhecida')
        using errcode = 'PT409';
    end if;
  end;

  return v_ficheiro;
end
$fn$;

-- =============================================================================
-- PAB
-- =============================================================================

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
  p_observacoes         text default null
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
     submetido_por, submetido_em, submetido_momento_declarado)
  values
    (v_actor.organizacao_id, p_obra_id, p_frente_id, v_numero, btrim(p_elemento),
     p_volume_previsto_m3, btrim(p_classe_betao), p_classe_exposicao,
     p_dmax_agregado_mm, p_classe_consistencia, p_data_pedido, p_data_prevista,
     'SUBMETIDO', p_ficheiro_impresso_id, p_observacoes,
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

create function betonagens.aprovar_pab(
  p_pab_id                 uuid,
  p_momento_declarado      timestamptz,
  p_dispositivo_id         text,
  p_sequencia              bigint,
  p_override_r6_justificacao text default null
)
returns betonagens.pab
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor      betonagens.utilizador := betonagens_priv.exigir_actor();
  v_pab        betonagens.pab;
  v_fcq        betonagens.fcq;
  v_assin      betonagens.fcq_seccao_assinatura;
  v_seccao     betonagens.fcq_seccao;
  v_pre        betonagens.fcq_seccao[] :=
                 array['implantacao','cofragem','armaduras']::betonagens.fcq_seccao[];
  v_nc         bigint;
  v_bloqueio   bigint;
  v_retrocesso boolean;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'FISCALIZACAO'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  if p_momento_declarado is null or p_dispositivo_id is null or p_sequencia is null then
    raise exception 'Faltam campos obrigatórios na aprovação do PAB.' using errcode = 'PT422';
  end if;

  select * into v_pab from betonagens.pab p where p.id = p_pab_id for update;
  if not found then
    raise exception 'PAB % não existe.', p_pab_id using errcode = 'PT422';
  end if;
  perform betonagens_priv.exigir_acesso_obra(v_actor, v_pab.obra_id);

  -- A3 · o estado só muda por transições; fora do grafo é 409
  if v_pab.estado <> 'SUBMETIDO' then
    raise exception 'O PAB % está em % e não pode ser aprovado.', v_pab.numero, v_pab.estado
      using errcode = 'PT409';
  end if;

  if p_momento_declarado > now() then
    raise exception 'O momento declarado está no futuro do relógio do servidor.'
      using errcode = 'PT422';
  end if;

  select * into v_fcq from betonagens.fcq f where f.pab_id = v_pab.id;
  if not found then
    raise exception 'O PAB % não tem ficha associada.', v_pab.numero using errcode = 'PT409';
  end if;

  -- F2 · gate de aprovação: implantação, cofragem e armaduras assinadas e em
  -- vigor. Juntas fica de fora por decisão de campo: uma junta de betonagem
  -- nasce durante o processo e o corte e a selagem são posteriores.
  foreach v_seccao in array v_pre loop
    select * into v_assin
      from betonagens.fcq_seccao_assinatura a
     where a.fcq_id = v_fcq.id and a.seccao = v_seccao and a.coluna = 'insp'
     order by a.versao desc
     limit 1;

    if not found then
      raise exception
        'A secção % ainda não está assinada. O PAB não pode ser aprovado antes das verificações pré-betonagem.',
        v_seccao
        using errcode = 'PT409';
    end if;

    if v_assin.itens_hash <> betonagens_priv.itens_hash(v_fcq.id, v_seccao, 'insp') then
      raise exception
        'A assinatura da secção % já não cobre o estado actual dos itens. É preciso reassinar antes de aprovar.',
        v_seccao
        using errcode = 'PT409';
    end if;

    if v_assin.momento_declarado > p_momento_declarado then
      raise exception
        'Cronologia inválida: a secção % foi assinada em % , depois do momento de aprovação declarado.',
        v_seccao, v_assin.momento_declarado
        using errcode = 'PT409';
    end if;
  end loop;

  -- nenhuma linha pré-betonagem pode ficar NC por reinspecionar
  select count(*) into v_nc
    from (
      select distinct on (i.linha_codigo) i.linha_codigo, i.valor
        from betonagens.fcq_item i
       where i.fcq_id = v_fcq.id
         and i.substituido_por_id is null
         and i.seccao = any (v_pre)
       order by i.linha_codigo, i.coluna desc
    ) ultimo
   where ultimo.valor = 'NC';

  if v_nc > 0 then
    raise exception
      'Há % verificações pré-betonagem em não conformidade por reinspecionar.', v_nc
      using errcode = 'PT409';
  end if;

  -- R6 · bloqueio na frente
  select count(*) into v_bloqueio
    from betonagens.pab p
   where p.frente_id = v_pab.frente_id
     and p.id <> v_pab.id
     and (
       p.estado = 'EM_BETONAGEM'
       or (p.estado = 'APROVADO'
           and p.data_prevista < current_date
           and not exists (
             select 1 from betonagens.guia_remessa g
              where g.pab_id = p.id and g.substituida_por_id is null))
     );

  if v_bloqueio > 0 then
    if p_override_r6_justificacao is null then
      raise exception
        'R6: a frente tem % PAB por fechar. Aprovar este exige justificação escrita.', v_bloqueio
        using errcode = 'PT409';
    end if;
    perform betonagens_priv.registar_excecao(
      v_pab.organizacao_id, v_pab.obra_id, 'OVERRIDE_R6'::betonagens.excecao_tipo,
      'pab', v_pab.id, v_actor.id, p_override_r6_justificacao);
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'OVERRIDE_R6'::betonagens.alerta_tipo, 'AVISO'::betonagens.alerta_severidade,
      format('R6 levantada por %s com %s PAB por fechar na frente.', v_actor.nome, v_bloqueio),
      v_pab.id, null, v_fcq.id, null);
  end if;

  v_retrocesso := betonagens_priv.reservar_sequencia(
    v_pab.organizacao_id, p_dispositivo_id, p_sequencia, v_actor.id,
    'pab', v_pab.id, p_momento_declarado);

  update betonagens.pab
     set estado = 'APROVADO',
         aprovado_por = v_actor.id,
         aprovado_em = now(),
         aprovado_momento_declarado = p_momento_declarado
   where id = v_pab.id
  returning * into v_pab;

  if v_retrocesso then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'CRONOLOGIA_DISPOSITIVO'::betonagens.alerta_tipo, 'INFO'::betonagens.alerta_severidade,
      format('O relógio do dispositivo %s recuou entre registos.', p_dispositivo_id),
      v_pab.id, null, null, null);
  end if;

  perform betonagens_priv.emitir_evento(
    v_pab.organizacao_id, v_pab.obra_id, 'PAB_APROVADO', 'pab', v_pab.id,
    jsonb_build_object(
      'numero', v_pab.numero,
      'frente_id', v_pab.frente_id,
      'classe_betao', v_pab.classe_betao,
      'volume_previsto_m3', v_pab.volume_previsto_m3,
      'aprovado_por', v_actor.id,
      'aprovado_em', v_pab.aprovado_em));

  return v_pab;
end
$fn$;

create function betonagens.rejeitar_pab(
  p_pab_id uuid,
  p_motivo text
)
returns betonagens.pab
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor betonagens.utilizador := betonagens_priv.exigir_actor();
  v_pab   betonagens.pab;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'FISCALIZACAO'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  select * into v_pab from betonagens.pab p where p.id = p_pab_id for update;
  if not found then
    raise exception 'PAB % não existe.', p_pab_id using errcode = 'PT422';
  end if;
  perform betonagens_priv.exigir_acesso_obra(v_actor, v_pab.obra_id);

  if v_pab.estado <> 'SUBMETIDO' then
    raise exception 'O PAB % está em % e não pode ser rejeitado.', v_pab.numero, v_pab.estado
      using errcode = 'PT409';
  end if;

  if p_motivo is null or length(btrim(p_motivo)) < 20 then
    raise exception 'A rejeição precisa de um motivo com pelo menos 20 caracteres.'
      using errcode = 'PT422';
  end if;

  update betonagens.pab
     set estado = 'REJEITADO',
         rejeitado_por = v_actor.id,
         rejeitado_em = now(),
         motivo_rejeicao = btrim(p_motivo)
   where id = v_pab.id
  returning * into v_pab;

  return v_pab;
end
$fn$;

create function betonagens.anular_pab(
  p_pab_id uuid,
  p_motivo text
)
returns betonagens.pab
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor betonagens.utilizador := betonagens_priv.exigir_actor();
  v_pab   betonagens.pab;
  v_guias bigint;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'FISCALIZACAO'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  select * into v_pab from betonagens.pab p where p.id = p_pab_id for update;
  if not found then
    raise exception 'PAB % não existe.', p_pab_id using errcode = 'PT422';
  end if;
  perform betonagens_priv.exigir_acesso_obra(v_actor, v_pab.obra_id);

  if v_pab.estado <> 'APROVADO' then
    raise exception 'Só se anula um PAB aprovado. O PAB % está em %.', v_pab.numero, v_pab.estado
      using errcode = 'PT409';
  end if;

  select count(*) into v_guias
    from betonagens.guia_remessa g
   where g.pab_id = v_pab.id and g.substituida_por_id is null;

  if v_guias > 0 then
    raise exception 'O PAB % já tem % guias e não pode ser anulado.', v_pab.numero, v_guias
      using errcode = 'PT409';
  end if;

  if p_motivo is null or length(btrim(p_motivo)) < 20 then
    raise exception 'A anulação precisa de um motivo com pelo menos 20 caracteres.'
      using errcode = 'PT422';
  end if;

  update betonagens.pab
     set estado = 'ANULADO',
         anulado_por = v_actor.id,
         anulado_em = now(),
         motivo_anulacao = btrim(p_motivo)
   where id = v_pab.id
  returning * into v_pab;

  return v_pab;
end
$fn$;

-- =============================================================================
-- Guias de remessa
-- =============================================================================

-- Núcleo partilhado pelo registo e pela correção. Uma correção é um registo
-- novo e completo que referencia o anterior — não é uma edição.
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
  p_motivo_substituicao text
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
    -- R7 · depois da FCQ fechada só por reabertura explícita
    if v_pab.estado not in ('APROVADO','EM_BETONAGEM','BETONADO') then
      raise exception
        'O PAB % está em % e as guias são read-only.', v_pab.numero, v_pab.estado
        using errcode = 'PT409';
    end if;
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

  v_por_fisc := p_actor.perfil in ('FISCALIZACAO','DIRETOR_QUALIDADE');

  -- R2 · classe divergente: a guia grava-se na mesma, não se apaga; o desvio
  -- tem de ficar registado.
  if btrim(p_classe_betao) <> v_pab.classe_betao then
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
       substitui_id, motivo_substituicao)
    values
      (p_id, v_pab.organizacao_id, v_pab.obra_id, v_pab.id, p_central_id,
       btrim(p_numero_guia), 0, p_data_hora_betonagem, p_hora_carga, p_volume_m3,
       btrim(p_classe_betao), p_slump_mm, p_temperatura_c, p_ficheiro_id, v_conf,
       p_actor.id, v_por_fisc, p_momento_declarado, p_dispositivo_id,
       p_sequencia, p_latitude, p_longitude, p_precisao_gps_m,
       p_substitui_id, nullif(btrim(coalesce(p_motivo_substituicao, '')), ''))
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
  if v_guia.classe_betao <> v_pab.classe_betao then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'CLASSE_DIVERGENTE'::betonagens.alerta_tipo, 'CRITICO'::betonagens.alerta_severidade,
      format('Guia %s entregue em %s; o PAB %s aprovou %s.',
             v_guia.numero_guia, v_guia.classe_betao, v_pab.numero, v_pab.classe_betao),
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
  p_precisao_gps_m      numeric default null
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
    p_latitude, p_longitude, p_precisao_gps_m, null, null);
end
$fn$;

-- B3 · corrigir não é editar: nasce um registo novo que referencia o anterior
create function betonagens.corrigir_guia(
  p_id                  uuid,
  p_substitui_id        uuid,
  p_motivo              text,
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
  p_precisao_gps_m      numeric default null
)
returns betonagens.guia_remessa
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if p_substitui_id is null then
    raise exception 'Indique a guia a corrigir.' using errcode = 'PT422';
  end if;
  return betonagens_priv.gravar_guia(
    betonagens_priv.exigir_actor(),
    p_id, p_pab_id, p_central_id, p_numero_guia, p_data_hora_betonagem,
    p_volume_m3, p_classe_betao, p_ficheiro_id, p_momento_declarado,
    p_dispositivo_id, p_sequencia, p_hora_carga, p_slump_mm, p_temperatura_c,
    p_latitude, p_longitude, p_precisao_gps_m, p_substitui_id, p_motivo);
end
$fn$;

create function betonagens.fechar_betonagem(
  p_pab_id            uuid,
  p_momento_declarado timestamptz,
  p_dispositivo_id    text,
  p_sequencia         bigint
)
returns betonagens.pab
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor      betonagens.utilizador := betonagens_priv.exigir_actor();
  v_pab        betonagens.pab;
  v_guias      bigint;
  v_ultima     timestamptz;
  v_total      numeric;
  v_retrocesso boolean;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'EMPREITEIRO'::betonagens.perfil_utilizador,
    'FISCALIZACAO'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  if p_momento_declarado is null or p_dispositivo_id is null or p_sequencia is null then
    raise exception 'Faltam campos obrigatórios no fecho da betonagem.' using errcode = 'PT422';
  end if;

  select * into v_pab from betonagens.pab p where p.id = p_pab_id for update;
  if not found then
    raise exception 'PAB % não existe.', p_pab_id using errcode = 'PT422';
  end if;
  perform betonagens_priv.exigir_acesso_obra(v_actor, v_pab.obra_id);

  if v_pab.estado <> 'EM_BETONAGEM' then
    raise exception 'O PAB % está em % e não pode ser fechado.', v_pab.numero, v_pab.estado
      using errcode = 'PT409';
  end if;

  -- R8 · não se fecha uma betonagem sem guias
  select count(*), max(g.data_hora_betonagem), coalesce(sum(g.volume_m3), 0)
    into v_guias, v_ultima, v_total
    from betonagens.guia_remessa g
   where g.pab_id = v_pab.id and g.substituida_por_id is null;

  if v_guias = 0 then
    raise exception 'O PAB % não tem guias associadas e não pode ser dado como betonado.', v_pab.numero
      using errcode = 'PT409';
  end if;

  if p_momento_declarado < v_ultima then
    raise exception
      'Cronologia inválida: o fecho declarado (%) é anterior à última guia (%).',
      p_momento_declarado, v_ultima
      using errcode = 'PT409';
  end if;

  v_retrocesso := betonagens_priv.reservar_sequencia(
    v_pab.organizacao_id, p_dispositivo_id, p_sequencia, v_actor.id,
    'pab', v_pab.id, p_momento_declarado);

  update betonagens.pab
     set estado = 'BETONADO',
         betonagem_fechada_por = v_actor.id,
         betonagem_fechada_em = now(),
         betonagem_fechada_momento_declarado = p_momento_declarado
   where id = v_pab.id
  returning * into v_pab;

  if v_retrocesso then
    perform betonagens_priv.criar_alerta(
      v_pab.organizacao_id, v_pab.obra_id,
      'CRONOLOGIA_DISPOSITIVO'::betonagens.alerta_tipo, 'INFO'::betonagens.alerta_severidade,
      format('O relógio do dispositivo %s recuou entre registos.', p_dispositivo_id),
      v_pab.id, null, null, null);
  end if;

  perform betonagens_priv.emitir_evento(
    v_pab.organizacao_id, v_pab.obra_id, 'BETONAGEM_FECHADA', 'pab', v_pab.id,
    jsonb_build_object(
      'numero', v_pab.numero,
      'guias', v_guias,
      'volume_total_m3', v_total,
      'volume_previsto_m3', v_pab.volume_previsto_m3,
      'fechada_por', v_actor.id,
      'fechada_em', v_pab.betonagem_fechada_em));

  return v_pab;
end
$fn$;

-- =============================================================================
-- Checklist I.CR.033
-- =============================================================================

create function betonagens_priv.gravar_item_fcq(
  p_actor               betonagens.utilizador,
  p_id                  uuid,
  p_fcq_id              uuid,
  p_linha_codigo        text,
  p_coluna              betonagens.fcq_coluna,
  p_valor               betonagens.fcq_valor,
  p_momento_declarado   timestamptz,
  p_dispositivo_id      text,
  p_sequencia           bigint,
  p_anotacao            text,
  p_latitude            numeric,
  p_longitude           numeric,
  p_precisao_gps_m      numeric,
  p_substitui_id        uuid,
  p_motivo_substituicao text
)
returns betonagens.fcq_item
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_fcq        betonagens.fcq;
  v_pab        betonagens.pab;
  v_linha      betonagens.fcq_linha;
  v_existente  betonagens.fcq_item;
  v_anterior   betonagens.fcq_item;
  v_item       betonagens.fcq_item;
  v_assinada   boolean;
  v_pre        betonagens.fcq_seccao[] :=
                 array['implantacao','cofragem','armaduras']::betonagens.fcq_seccao[];
  v_severidade betonagens.alerta_severidade;
  v_retrocesso boolean;
begin
  perform betonagens_priv.exigir_perfil(
    p_actor,
    'FISCALIZACAO'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  if p_id is null or p_fcq_id is null or p_linha_codigo is null
     or p_coluna is null or p_valor is null or p_momento_declarado is null
     or p_dispositivo_id is null or p_sequencia is null then
    raise exception 'Faltam campos obrigatórios no registo do item.' using errcode = 'PT422';
  end if;

  if p_momento_declarado > now() then
    raise exception 'O momento declarado está no futuro do relógio do servidor.'
      using errcode = 'PT422';
  end if;

  select * into v_existente from betonagens.fcq_item i where i.id = p_id;
  if found then
    if v_existente.fcq_id = p_fcq_id
       and v_existente.linha_codigo = p_linha_codigo
       and v_existente.coluna = p_coluna
       and v_existente.valor = p_valor then
      return v_existente;
    end if;
    raise exception 'O item % já está registado com outro conteúdo.', p_id using errcode = 'PT409';
  end if;

  select * into v_fcq from betonagens.fcq f where f.id = p_fcq_id;
  if not found then
    raise exception 'A ficha % não existe.', p_fcq_id using errcode = 'PT422';
  end if;
  perform betonagens_priv.exigir_acesso_obra(p_actor, v_fcq.obra_id);

  -- R7 · depois de emitida, só por reabertura explícita
  if v_fcq.estado <> 'RASCUNHO' then
    raise exception 'A ficha % já foi emitida e é read-only.', v_fcq.numero using errcode = 'PT409';
  end if;

  select * into v_linha
    from betonagens.fcq_linha l
   where l.modelo_impresso_id = v_fcq.modelo_impresso_id and l.codigo = p_linha_codigo;
  if not found then
    raise exception 'A linha % não existe no modelo desta ficha.', p_linha_codigo
      using errcode = 'PT422';
  end if;

  select * into v_pab from betonagens.pab p where p.id = v_fcq.pab_id;

  -- Cronologia por secção (C2):
  --   pré-betonagem na coluna insp  → só enquanto o PAB está por aprovar
  --   pós-betonagem                 → só depois do fecho da betonagem
  --   juntas e betonagem            → livres, apenas antes da emissão
  --
  -- A condição só se aplica a um item NOVO (p_substitui_id nulo). Corrigir um
  -- item já existente é permitido depois da aprovação, e é o cenário que custa:
  -- gera exceção nominal e alerta, e no caso pré-betonagem com PAB aprovado o
  -- alerta é CRÍTICO e trava a emissão da FCQ sem desaprovar o PAB.
  if v_linha.seccao = any (v_pre) and p_coluna = 'insp'
     and p_substitui_id is null and v_pab.estado <> 'SUBMETIDO' then
    raise exception
      'A secção % já serviu de gate à aprovação do PAB. Use uma coluna de reinspeção ou uma correção justificada.',
      v_linha.seccao
      using errcode = 'PT409';
  end if;

  if v_linha.seccao = 'pos_betonagem' then
    if v_pab.betonagem_fechada_momento_declarado is null then
      raise exception 'A secção pós-betonagem só se preenche depois de fechada a betonagem.'
        using errcode = 'PT409';
    end if;
    if p_momento_declarado < v_pab.betonagem_fechada_momento_declarado then
      raise exception
        'Cronologia inválida: o item pós-betonagem é anterior ao fecho da betonagem (%).',
        v_pab.betonagem_fechada_momento_declarado
        using errcode = 'PT409';
    end if;
  end if;

  if p_valor = 'NC' and length(btrim(coalesce(p_anotacao, ''))) < 5 then
    raise exception 'Uma não conformidade precisa de anotação a dizer o que está mal.'
      using errcode = 'PT422';
  end if;

  if p_substitui_id is null then
    if exists (
      select 1 from betonagens.fcq_item i
       where i.fcq_id = p_fcq_id and i.linha_codigo = p_linha_codigo
         and i.coluna = p_coluna and i.substituido_por_id is null
    ) then
      raise exception
        'A linha % já tem valor na coluna %. Para mudar, corrija com motivo.',
        p_linha_codigo, p_coluna
        using errcode = 'PT409';
    end if;
  else
    select * into v_anterior from betonagens.fcq_item i where i.id = p_substitui_id;
    if not found then
      raise exception 'O item a corrigir (%) não existe.', p_substitui_id using errcode = 'PT422';
    end if;
    if v_anterior.substituido_por_id is not null then
      raise exception 'O item % já foi corrigido antes.', p_substitui_id using errcode = 'PT409';
    end if;
    if v_anterior.fcq_id <> p_fcq_id
       or v_anterior.linha_codigo <> p_linha_codigo
       or v_anterior.coluna <> p_coluna then
      raise exception 'A correção tem de ficar na mesma linha e coluna do item original.'
        using errcode = 'PT422';
    end if;
    if p_motivo_substituicao is null or length(btrim(p_motivo_substituicao)) < 20 then
      raise exception 'A correção precisa de um motivo com pelo menos 20 caracteres.'
        using errcode = 'PT422';
    end if;
  end if;

  v_retrocesso := betonagens_priv.reservar_sequencia(
    v_fcq.organizacao_id, p_dispositivo_id, p_sequencia, p_actor.id,
    'fcq_item', p_id, p_momento_declarado);

  insert into betonagens.fcq_item
    (id, organizacao_id, obra_id, fcq_id, modelo_impresso_id, linha_codigo,
     seccao, coluna, valor, anotacao, registado_por, momento_declarado,
     dispositivo_id, sequencia_dispositivo, latitude, longitude, precisao_gps_m,
     substitui_id, motivo_substituicao)
  values
    (p_id, v_fcq.organizacao_id, v_fcq.obra_id, v_fcq.id, v_fcq.modelo_impresso_id,
     p_linha_codigo, v_linha.seccao, p_coluna, p_valor,
     nullif(btrim(coalesce(p_anotacao, '')), ''), p_actor.id, p_momento_declarado,
     p_dispositivo_id, p_sequencia, p_latitude, p_longitude, p_precisao_gps_m,
     p_substitui_id, nullif(btrim(coalesce(p_motivo_substituicao, '')), ''))
  returning * into v_item;

  if v_retrocesso then
    perform betonagens_priv.criar_alerta(
      v_fcq.organizacao_id, v_fcq.obra_id,
      'CRONOLOGIA_DISPOSITIVO'::betonagens.alerta_tipo, 'INFO'::betonagens.alerta_severidade,
      format('O relógio do dispositivo %s recuou entre registos.', p_dispositivo_id),
      v_pab.id, null, v_fcq.id, null);
  end if;

  -- Correção numa secção já assinada: a assinatura não muda de estado, deixa de
  -- estar em vigor por aritmética. O que custa é isto — exceção nominal e
  -- alerta na fila do fiscal.
  if p_substitui_id is not null then
    select true into v_assinada
      from betonagens.fcq_seccao_assinatura a
     where a.fcq_id = v_fcq.id and a.seccao = v_linha.seccao and a.coluna = p_coluna
     limit 1;

    if v_assinada then
      -- pré-betonagem com PAB já aprovado põe em causa o gate que autorizou a
      -- aprovação. Não desaprova o PAB — betão colocado não se despeja — mas
      -- impede a emissão da FCQ até alguém identificado resolver o alerta.
      if v_linha.seccao = any (v_pre) and v_pab.estado <> 'SUBMETIDO' then
        v_severidade := 'CRITICO';
      else
        v_severidade := 'AVISO';
      end if;

      perform betonagens_priv.registar_excecao(
        v_fcq.organizacao_id, v_fcq.obra_id,
        'CORRECAO_APOS_ASSINATURA'::betonagens.excecao_tipo,
        'fcq_item', v_item.id, p_actor.id, p_motivo_substituicao);

      perform betonagens_priv.criar_alerta(
        v_fcq.organizacao_id, v_fcq.obra_id,
        'CORRECAO_APOS_ASSINATURA'::betonagens.alerta_tipo, v_severidade,
        format('Item %s da secção %s corrigido depois de assinado. A assinatura deixou de estar em vigor.',
               p_linha_codigo, v_linha.seccao),
        v_pab.id, null, v_fcq.id, null);
    end if;
  end if;

  return v_item;
end
$fn$;

-- C3 · um item de cada vez. Não existe "marcar tudo conforme".
create function betonagens.marcar_item_fcq(
  p_id                uuid,
  p_fcq_id            uuid,
  p_linha_codigo      text,
  p_coluna            betonagens.fcq_coluna,
  p_valor             betonagens.fcq_valor,
  p_momento_declarado timestamptz,
  p_dispositivo_id    text,
  p_sequencia         bigint,
  p_anotacao          text default null,
  p_latitude          numeric default null,
  p_longitude         numeric default null,
  p_precisao_gps_m    numeric default null
)
returns betonagens.fcq_item
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  return betonagens_priv.gravar_item_fcq(
    betonagens_priv.exigir_actor(),
    p_id, p_fcq_id, p_linha_codigo, p_coluna, p_valor, p_momento_declarado,
    p_dispositivo_id, p_sequencia, p_anotacao, p_latitude, p_longitude,
    p_precisao_gps_m, null, null);
end
$fn$;

create function betonagens.corrigir_item_fcq(
  p_id                uuid,
  p_substitui_id      uuid,
  p_motivo            text,
  p_fcq_id            uuid,
  p_linha_codigo      text,
  p_coluna            betonagens.fcq_coluna,
  p_valor             betonagens.fcq_valor,
  p_momento_declarado timestamptz,
  p_dispositivo_id    text,
  p_sequencia         bigint,
  p_anotacao          text default null,
  p_latitude          numeric default null,
  p_longitude         numeric default null,
  p_precisao_gps_m    numeric default null
)
returns betonagens.fcq_item
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if p_substitui_id is null then
    raise exception 'Indique o item a corrigir.' using errcode = 'PT422';
  end if;
  return betonagens_priv.gravar_item_fcq(
    betonagens_priv.exigir_actor(),
    p_id, p_fcq_id, p_linha_codigo, p_coluna, p_valor, p_momento_declarado,
    p_dispositivo_id, p_sequencia, p_anotacao, p_latitude, p_longitude,
    p_precisao_gps_m, p_substitui_id, p_motivo);
end
$fn$;

create function betonagens.assinar_seccao_fcq(
  p_fcq_id            uuid,
  p_seccao            betonagens.fcq_seccao,
  p_coluna            betonagens.fcq_coluna,
  p_momento_declarado timestamptz,
  p_dispositivo_id    text,
  p_sequencia         bigint,
  p_motivo_reassinatura text default null,
  p_latitude          numeric default null,
  p_longitude         numeric default null
)
returns betonagens.fcq_seccao_assinatura
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor      betonagens.utilizador := betonagens_priv.exigir_actor();
  v_fcq        betonagens.fcq;
  v_linhas     bigint;
  v_itens      bigint;
  v_pendentes  bigint;
  v_anterior   betonagens.fcq_seccao_assinatura;
  v_assin      betonagens.fcq_seccao_assinatura;
  v_versao     integer;
  v_hash_itens bytea;
  v_coluna_ant betonagens.fcq_coluna;
  v_retrocesso boolean;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'FISCALIZACAO'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  if p_fcq_id is null or p_seccao is null or p_coluna is null
     or p_momento_declarado is null or p_dispositivo_id is null or p_sequencia is null then
    raise exception 'Faltam campos obrigatórios na assinatura.' using errcode = 'PT422';
  end if;

  if p_momento_declarado > now() then
    raise exception 'O momento declarado está no futuro do relógio do servidor.'
      using errcode = 'PT422';
  end if;

  select * into v_fcq from betonagens.fcq f where f.id = p_fcq_id for update;
  if not found then
    raise exception 'A ficha % não existe.', p_fcq_id using errcode = 'PT422';
  end if;
  perform betonagens_priv.exigir_acesso_obra(v_actor, v_fcq.obra_id);

  if v_fcq.estado <> 'RASCUNHO' then
    raise exception 'A ficha % já foi emitida.', v_fcq.numero using errcode = 'PT409';
  end if;

  if p_coluna = 'insp' then
    -- na primeira inspeção todas as linhas da secção têm de ter valor; NA é o
    -- valor normal quando o projeto não exige o item
    select count(*) into v_linhas
      from betonagens.fcq_linha l
     where l.modelo_impresso_id = v_fcq.modelo_impresso_id and l.seccao = p_seccao;

    select count(*) into v_itens
      from betonagens.fcq_item i
     where i.fcq_id = v_fcq.id and i.seccao = p_seccao and i.coluna = 'insp'
       and i.substituido_por_id is null;

    if v_itens <> v_linhas then
      raise exception
        'A secção % tem % de % critérios preenchidos na inspeção. Não se assina uma secção incompleta.',
        p_seccao, v_itens, v_linhas
        using errcode = 'PT409';
    end if;
  else
    -- numa reinspeção só se verificam as linhas que ficaram NC na coluna
    -- anterior: exigir a secção inteira seria mentir sobre o que se foi ver
    v_coluna_ant := case p_coluna
                      when 'reinsp1' then 'insp'::betonagens.fcq_coluna
                      when 'reinsp2' then 'reinsp1'::betonagens.fcq_coluna
                      else 'reinsp2'::betonagens.fcq_coluna
                    end;

    select count(*) into v_linhas
      from betonagens.fcq_item i
     where i.fcq_id = v_fcq.id and i.seccao = p_seccao and i.coluna = v_coluna_ant
       and i.substituido_por_id is null and i.valor = 'NC';

    if v_linhas = 0 then
      raise exception
        'Não há não conformidades na coluna % da secção % para reinspecionar.', v_coluna_ant, p_seccao
        using errcode = 'PT409';
    end if;

    select count(*) into v_pendentes
      from betonagens.fcq_item ant
     where ant.fcq_id = v_fcq.id and ant.seccao = p_seccao and ant.coluna = v_coluna_ant
       and ant.substituido_por_id is null and ant.valor = 'NC'
       and not exists (
         select 1 from betonagens.fcq_item novo
          where novo.fcq_id = v_fcq.id and novo.linha_codigo = ant.linha_codigo
            and novo.coluna = p_coluna and novo.substituido_por_id is null);

    if v_pendentes > 0 then
      raise exception
        'Faltam % linhas por reinspecionar na secção %.', v_pendentes, p_seccao
        using errcode = 'PT409';
    end if;
  end if;

  select * into v_anterior
    from betonagens.fcq_seccao_assinatura a
   where a.fcq_id = v_fcq.id and a.seccao = p_seccao and a.coluna = p_coluna
   order by a.versao desc
   limit 1;

  if found then
    v_versao := v_anterior.versao + 1;
    if p_motivo_reassinatura is null or length(btrim(p_motivo_reassinatura)) < 20 then
      raise exception
        'Reassinar exige motivo com pelo menos 20 caracteres. A assinatura anterior mantém-se no registo.'
        using errcode = 'PT422';
    end if;
  else
    v_versao := 1;
    v_anterior := null;
  end if;

  v_hash_itens := betonagens_priv.itens_hash(v_fcq.id, p_seccao, p_coluna);

  v_retrocesso := betonagens_priv.reservar_sequencia(
    v_fcq.organizacao_id, p_dispositivo_id, p_sequencia, v_actor.id,
    'fcq_seccao_assinatura', v_fcq.id, p_momento_declarado);

  insert into betonagens.fcq_seccao_assinatura
    (organizacao_id, obra_id, fcq_id, seccao, coluna, versao, substitui_id,
     motivo_reassinatura, utilizador_id, nome_completo, nome_impresso,
     momento_declarado, dispositivo_id, latitude, longitude, itens_hash, hash)
  values
    (v_fcq.organizacao_id, v_fcq.obra_id, v_fcq.id, p_seccao, p_coluna, v_versao,
     v_anterior.id, nullif(btrim(coalesce(p_motivo_reassinatura, '')), ''),
     v_actor.id, v_actor.nome, betonagens_priv.nome_impresso(v_actor.nome),
     p_momento_declarado, p_dispositivo_id, p_latitude, p_longitude,
     v_hash_itens,
     sha256(convert_to(
       v_actor.id::text || '|' || v_actor.nome || '|' || v_fcq.id::text || '|' ||
       p_seccao::text || '|' || p_coluna::text || '|' || v_versao::text || '|' ||
       p_momento_declarado::text || '|' || encode(v_hash_itens, 'hex'),
       'UTF8')))
  returning * into v_assin;

  if v_retrocesso then
    perform betonagens_priv.criar_alerta(
      v_fcq.organizacao_id, v_fcq.obra_id,
      'CRONOLOGIA_DISPOSITIVO'::betonagens.alerta_tipo, 'INFO'::betonagens.alerta_severidade,
      format('O relógio do dispositivo %s recuou entre registos.', p_dispositivo_id),
      v_fcq.pab_id, null, v_fcq.id, null);
  end if;

  return v_assin;
end
$fn$;

-- =============================================================================
-- Alertas
-- =============================================================================

-- C5 das brechas · não existe "ignorar": resolve-se com ação e motivo
create function betonagens.resolver_alerta(
  p_alerta_id uuid,
  p_motivo    text
)
returns betonagens.alerta
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor  betonagens.utilizador := betonagens_priv.exigir_actor();
  v_alerta betonagens.alerta;
begin
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'FISCALIZACAO'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  select * into v_alerta from betonagens.alerta a where a.id = p_alerta_id for update;
  if not found then
    raise exception 'O alerta % não existe.', p_alerta_id using errcode = 'PT422';
  end if;
  perform betonagens_priv.exigir_acesso_obra(v_actor, v_alerta.obra_id);

  if v_alerta.resolvido_em is not null then
    raise exception 'O alerta % já foi resolvido.', p_alerta_id using errcode = 'PT409';
  end if;

  if p_motivo is null or length(btrim(p_motivo)) < 20 then
    raise exception 'Resolver um alerta exige motivo com pelo menos 20 caracteres.'
      using errcode = 'PT422';
  end if;

  update betonagens.alerta
     set resolvido_em = now(), resolvido_por = v_actor.id, motivo_resolucao = btrim(p_motivo)
   where id = p_alerta_id
  returning * into v_alerta;

  return v_alerta;
end
$fn$;

reset role;

-- =============================================================================
-- Privilégios
--
-- Nada escreve tabelas directamente — nem authenticated, nem service_role. Uma
-- chave de serviço fugida não consegue inserir uma guia sem PAB, porque não tem
-- INSERT em lado nenhum: só EXECUTE nas funções acima.
-- =============================================================================

revoke all on all tables    in schema betonagens      from public, anon, authenticated, service_role;
revoke all on all functions in schema betonagens      from public, anon, authenticated, service_role;
revoke all on all functions in schema betonagens_priv from public, anon, service_role;
revoke all on all sequences in schema betonagens      from public, anon, authenticated, service_role;

grant select on
  betonagens.organizacao,
  betonagens.utilizador,
  betonagens.utilizador_obra,
  betonagens.obra,
  betonagens.frente,
  betonagens.central_betonagem,
  betonagens.parametro,
  betonagens.ficheiro,
  betonagens.pab,
  betonagens.guia_remessa,
  betonagens.modelo_impresso,
  betonagens.fcq_linha,
  betonagens.fcq,
  betonagens.fcq_item,
  betonagens.fcq_seccao_assinatura,
  betonagens.fcq_versao,
  betonagens.alerta,
  betonagens.excecao,
  betonagens.evento_saida,
  betonagens.ledger,
  betonagens.fcq_seccao_estado
to authenticated;

-- as auxiliares que a RLS e a vista precisam de executar em nome de quem consulta
grant execute on function betonagens_priv.utilizador_atual()  to authenticated;
grant execute on function betonagens_priv.organizacao_atual() to authenticated;
grant execute on function betonagens_priv.obras_visiveis()    to authenticated;
grant execute on function betonagens_priv.itens_hash(
  uuid, betonagens.fcq_seccao, betonagens.fcq_coluna) to authenticated;

-- camada de serviço
grant execute on function betonagens.registar_utilizador(uuid, text, text, betonagens.perfil_utilizador) to authenticated;
grant execute on function betonagens.desativar_utilizador(uuid) to authenticated;
grant execute on function betonagens.criar_obra(text, text, text, text, text) to authenticated;
grant execute on function betonagens.criar_frente(uuid, text, numeric, numeric, integer) to authenticated;
grant execute on function betonagens.criar_central(text, text) to authenticated;
grant execute on function betonagens.atribuir_obra(uuid, uuid) to authenticated;
grant execute on function betonagens.revogar_obra(uuid, uuid) to authenticated;
grant execute on function betonagens.definir_parametro(text, timestamptz, text, uuid, numeric, text, text, boolean, text) to authenticated;
grant execute on function betonagens.registar_ficheiro(uuid, uuid, betonagens.ficheiro_tipo, betonagens.ficheiro_origem, text, bytea, bigint, text, text) to authenticated, service_role;
grant execute on function betonagens.submeter_pab(uuid, uuid, text, numeric, text, date, date, timestamptz, text, integer, text, uuid, text) to authenticated;
grant execute on function betonagens.aprovar_pab(uuid, timestamptz, text, bigint, text) to authenticated;
grant execute on function betonagens.rejeitar_pab(uuid, text) to authenticated;
grant execute on function betonagens.anular_pab(uuid, text) to authenticated;
grant execute on function betonagens.registar_guia(uuid, uuid, uuid, text, timestamptz, numeric, text, uuid, timestamptz, text, bigint, timestamptz, integer, numeric, numeric, numeric, numeric) to authenticated, service_role;
grant execute on function betonagens.corrigir_guia(uuid, uuid, text, uuid, uuid, text, timestamptz, numeric, text, uuid, timestamptz, text, bigint, timestamptz, integer, numeric, numeric, numeric, numeric) to authenticated;
grant execute on function betonagens.fechar_betonagem(uuid, timestamptz, text, bigint) to authenticated;
grant execute on function betonagens.marcar_item_fcq(uuid, uuid, text, betonagens.fcq_coluna, betonagens.fcq_valor, timestamptz, text, bigint, text, numeric, numeric, numeric) to authenticated;
grant execute on function betonagens.corrigir_item_fcq(uuid, uuid, text, uuid, text, betonagens.fcq_coluna, betonagens.fcq_valor, timestamptz, text, bigint, text, numeric, numeric, numeric) to authenticated;
grant execute on function betonagens.assinar_seccao_fcq(uuid, betonagens.fcq_seccao, betonagens.fcq_coluna, timestamptz, text, bigint, text, numeric, numeric) to authenticated;
grant execute on function betonagens.resolver_alerta(uuid, text) to authenticated;

-- betonagens.criar_organizacao NÃO é concedida a ninguém, de propósito: é o
-- arranque e corre no SQL Editor.

insert into betonagens.migracao (ficheiro) values ('0008_servico.sql');
