-- =============================================================================
-- 0019_gravar_guia_ordem.sql · Obrify Betão
--
-- Paga a dívida técnica A4.2, declarada a 2026-08-13.
--
-- ── O DEFEITO ───────────────────────────────────────────────────────────────
-- No ramo da correcção de betonagens_priv.gravar_guia, o estado do PAB era
-- avaliado ANTES de se confirmar que a guia a corrigir pertence a esse PAB.
-- Consequência: quem tentasse mover uma guia para outro PAB recebia
--     PT409 «o PAB N está em SUBMETIDO e as guias são read-only»
-- que é verdade sobre o PAB indicado e não diz nada sobre o que se tentou
-- fazer. A recusa certa é PT422 «a correcção tem de ficar no mesmo PAB da guia
-- original», e só aparecia quando o outro PAB por acaso estivesse num estado
-- que deixasse passar o primeiro teste.
--
-- ── O QUE MUDA ──────────────────────────────────────────────────────────────
-- A verificação do estado desce para depois de v_anterior.pab_id = p_pab_id.
-- Passa a ser, por construção, o estado do PAB da própria guia — que é o que
-- ela sempre quis dizer.
--
-- Mais nada. O corpo foi extraído da 0008 e reordenado por programa, não
-- transcrito: as únicas linhas novas são o `or replace` e o comentário que
-- explica a ordem. Nenhuma regra, mensagem ou código de erro foi tocado.
--
-- ── PORQUE É QUE ISTO É SEGURO AGORA ────────────────────────────────────────
-- Quando a dívida foi declarada, mexer aqui custava um create or replace de
-- ~360 linhas sem rede. Hoje a suite cobre gravar_guia por A1.1-A1.3, A2.1-A2.3,
-- A4.1-A4.2, A5.1-A5.4, B3, B5.1-B5.2, B6.1, B7.1-B7.3 e D01-D06 — vinte e
-- cinco verificações. Se esta reordenação partir alguma coisa, a suite diz
-- qual.
--
-- Depois disto, a asserção A4.2 pode voltar para junto da A4.1 na suite. Não
-- volta nesta entrega: mudá-la de sítio obrigava a ter o PAB 2 aprovado mais
-- cedo, e isso mexe na cronologia do fixture, que é matéria à parte.
--
-- Termina com o revoke da convenção fixada pela 0015.
--
-- Depende de: 0018.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0019_gravar_guia_ordem.sql') then
    raise exception 'A migração 0019_gravar_guia_ordem.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

create or replace function betonagens_priv.gravar_guia(
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
    -- declarada a 2026-08-13 ao lado do teste, paga aqui.
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
reset role;

-- ── convenção fixada pela 0015 ──────────────────────────────────────────────
set role betonagens_servico;
revoke execute on all routines in schema betonagens, betonagens_priv from public;
reset role;

insert into betonagens.migracao (ficheiro) values ('0019_gravar_guia_ordem.sql');
