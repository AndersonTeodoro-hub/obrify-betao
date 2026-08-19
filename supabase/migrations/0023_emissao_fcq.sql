-- =============================================================================
-- 0023_emissao_fcq.sql · Obrify Betão
--
-- A emissão da FCQ: o balde onde vive o documento gerado, e a função que o
-- regista como versão.
--
-- ── O QUE FALTAVA ───────────────────────────────────────────────────────────
-- betonagens.fcq_versao existe desde a 0004, com ficheiro_pdf_id, sha256_pdf,
-- dados e as regras D4 da reemissão. O que nunca existiu foi quem lá escrevesse:
-- a 0021 declarou-o («a emissão em betonagens.fcq_versao vem numa migração à
-- parte, depois desta ter feito commit», por causa do ALTER TYPE que criou a
-- origem GERADO). É esta a migração à parte.
--
-- ── PORQUE É QUE O PAB PASSA A FCQ_FECHADA AQUI ─────────────────────────────
-- 'FCQ_FECHADA' está no enum desde a 0001 e as constraints da 0003 já a
-- previam — mas nenhuma função a atribuía. Verificado hoje contra o repositório:
-- nenhum caminho de escrita punha o PAB nesse estado. Faz sentido: o PAB fecha
-- quando a ficha dele é emitida, e emitir é o último acto (cabeçalho da 0004).
-- É por isso que a transição vive aqui e não no fechar_betonagem.
--
-- ── O QUE A FUNÇÃO NÃO RECEBE ───────────────────────────────────────────────
-- A conformidade não é parâmetro: deriva-se dos itens em vigor. Quem emite não
-- declara se a ficha está conforme — a ficha é que diz. E as observações vêm do
-- PAB, que é onde já são escritas e onde o documento do PAB as mostra.
-- ponytail: se um dia as observações da FCQ tiverem de ser distintas das do
-- PAB, é uma coluna em fcq e um campo no ecrã — não se inventa agora um campo
-- para o qual não há sítio no fluxo.
--
-- ── DUAS QUEBRAS DE CONVENÇÃO, AS MESMAS DA 0018 E DA 0021 ──────────────────
-- A parte do storage não corre sob `set role betonagens_servico` — esse papel
-- não é dono do esquema storage.
--
-- Termina com o revoke da convenção fixada pela 0015.
--
-- Depende de: 0022.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0023_emissao_fcq.sql') then
    raise exception 'A migração 0023_emissao_fcq.sql já foi aplicada.';
  end if;
end $$;

-- ── o balde do documento emitido ────────────────────────────────────────────
-- Privado e sem escrita para ninguém, pela mesma razão do balde das guias: quem
-- escreve é a Edge Function gerar-fcq, com a chave de serviço, e o sha256 que
-- fica em ficheiro e em fcq_versao é calculado sobre os bytes que ela acabou de
-- produzir. Se o cliente pudesse escrever aqui, o hash deixava de provar nada.
--
-- 20 MB: uma FCQ é o impresso de uma página mais uma camada de texto — a
-- primeira que gerámos tem 73 kB. O tecto é folga, não expectativa.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fcq', 'fcq', false, 20971520, array['application/pdf']);

create policy fcq_leitura_por_obra on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'fcq'
    and (storage.foldername(name))[1]::uuid in (
      select betonagens_priv.obras_visiveis()
    )
  );

-- A prova de que ninguém escreve, como na 0018 e na 0021.
do $$
declare
  v_escrita integer;
begin
  select count(*) into v_escrita
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'storage' and c.relname = 'objects'
     and p.polcmd in ('a', 'w', 'd')            -- INSERT, UPDATE, DELETE
     and pg_get_expr(coalesce(p.polqual, p.polwithcheck), p.polrelid) like '%''fcq''%';

  if v_escrita <> 0 then
    raise exception
      'Há % políticas de escrita a mencionar o balde fcq. O único escritor tem de ser a Edge Function.',
      v_escrita;
  end if;
end $$;

set role betonagens_servico;

-- ── a emissão ───────────────────────────────────────────────────────────────
create function betonagens.emitir_fcq(
  p_fcq_id           uuid,
  p_versao           integer,
  p_ficheiro_pdf_id  uuid,
  p_sha256_pdf       bytea,
  p_dados            jsonb,
  p_motivo_reemissao text default null
)
returns betonagens.fcq_versao
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor        betonagens.utilizador := betonagens_priv.exigir_actor();
  v_fcq          betonagens.fcq;
  v_pab          betonagens.pab;
  v_ficheiro     betonagens.ficheiro;
  v_existente    betonagens.fcq_versao;
  v_versao       betonagens.fcq_versao;
  v_proxima      integer;
  v_conformidade betonagens.fcq_conformidade;
  v_itens        integer;
  v_autoriza     uuid;
begin
  -- A FCQ é o documento da fiscalização. Quem regista guias não a emite.
  perform betonagens_priv.exigir_perfil(
    v_actor,
    'FISCALIZACAO'::betonagens.perfil_utilizador,
    'DIRETOR_QUALIDADE'::betonagens.perfil_utilizador);

  if p_fcq_id is null or p_versao is null or p_ficheiro_pdf_id is null
     or p_sha256_pdf is null or p_dados is null then
    raise exception 'Faltam campos obrigatórios na emissão da FCQ.' using errcode = 'PT422';
  end if;

  if jsonb_typeof(p_dados) <> 'object' then
    raise exception 'Os dados impressos têm de ser um objecto JSON, veio %.',
      jsonb_typeof(p_dados) using errcode = 'PT422';
  end if;

  -- for update: a versão deriva-se de um máximo, e duas emissões ao mesmo tempo
  -- não podem chegar as duas à mesma conclusão.
  select * into v_fcq from betonagens.fcq f where f.id = p_fcq_id for update;
  if not found then
    raise exception 'A ficha % não existe.', p_fcq_id using errcode = 'PT422';
  end if;
  perform betonagens_priv.exigir_acesso_obra(v_actor, v_fcq.obra_id);

  select * into v_pab from betonagens.pab p where p.id = v_fcq.pab_id;
  if v_pab.estado not in ('BETONADO','FCQ_FECHADA') then
    raise exception
      'O PAB % está em % e a ficha ainda não se emite. A FCQ é o último acto: emite-se com a betonagem fechada.',
      v_pab.numero, v_pab.estado
      using errcode = 'PT409';
  end if;

  -- ── idempotência por versão ───────────────────────────────────────────────
  -- A Edge Function pode reenviar depois de uma falha de rede a meio: o mesmo
  -- documento, com o mesmo hash, devolve a versão que já existe em vez de criar
  -- outra. Outro documento com o mesmo número de versão é conflito.
  select * into v_existente from betonagens.fcq_versao v
   where v.fcq_id = p_fcq_id and v.versao = p_versao;
  if found then
    if v_existente.ficheiro_pdf_id = p_ficheiro_pdf_id
       and v_existente.sha256_pdf = p_sha256_pdf then
      return v_existente;
    end if;
    raise exception
      'A versão % desta ficha já foi emitida com outro documento.', p_versao
      using errcode = 'PT409';
  end if;

  select coalesce(max(v.versao), 0) + 1 into v_proxima
    from betonagens.fcq_versao v where v.fcq_id = p_fcq_id;

  if p_versao <> v_proxima then
    raise exception
      'A ficha vai na versão %; pediu-se a %. Alguém emitiu entretanto — volte a gerar.',
      v_proxima, p_versao
      using errcode = 'PT409';
  end if;

  -- ── D4 · reemissão nominal, justificada, versionada e contada ─────────────
  if v_proxima > 1
     and (p_motivo_reemissao is null or length(btrim(p_motivo_reemissao)) < 20) then
    raise exception
      'Reemitir a ficha exige um motivo escrito com pelo menos 20 caracteres. A versão % substitui um documento que já saiu.',
      v_proxima - 1
      using errcode = 'PT422';
  end if;

  -- a partir da segunda reabertura escala para a direção de qualidade
  if v_proxima >= 3 then
    if v_actor.perfil <> 'DIRETOR_QUALIDADE' then
      raise exception
        'A partir da terceira versão a reemissão é autorizada pela direção de qualidade. O perfil % não a autoriza.',
        v_actor.perfil
        using errcode = 'PT403';
    end if;
    v_autoriza := v_actor.id;
  end if;

  -- ── o documento ───────────────────────────────────────────────────────────
  select * into v_ficheiro from betonagens.ficheiro f where f.id = p_ficheiro_pdf_id;
  if not found then
    raise exception 'O ficheiro % não está registado.', p_ficheiro_pdf_id using errcode = 'PT422';
  end if;
  if v_ficheiro.tipo <> 'FCQ_PDF' then
    raise exception 'O ficheiro % não é um PDF de ficha.', p_ficheiro_pdf_id using errcode = 'PT422';
  end if;
  if v_ficheiro.origem <> 'GERADO' then
    raise exception
      'O ficheiro % não foi gerado pela plataforma (origem %). Uma FCQ não se carrega: gera-se.',
      p_ficheiro_pdf_id, v_ficheiro.origem
      using errcode = 'PT422';
  end if;
  if v_ficheiro.obra_id <> v_fcq.obra_id then
    raise exception 'O ficheiro % é de outra obra.', p_ficheiro_pdf_id using errcode = 'PT422';
  end if;
  -- O hash do ficheiro foi calculado no servidor sobre os bytes guardados. Se o
  -- que se declara aqui divergir, os dois registos ficariam a dizer coisas
  -- diferentes sobre o mesmo documento.
  if v_ficheiro.sha256 <> p_sha256_pdf then
    raise exception
      'O sha256 declarado não é o do ficheiro registado. O documento e o registo têm de falar do mesmo PDF.'
      using errcode = 'PT422';
  end if;

  -- ── conformidade, derivada ────────────────────────────────────────────────
  -- Não é parâmetro: quem emite não declara se a ficha está conforme. Vale o
  -- último valor de cada linha — uma não conformidade reinspeccionada e depois
  -- conforme deixa marca (CONFORME_COM_OBS), mas não condena a ficha.
  select count(*) into v_itens
    from betonagens.fcq_item i
   where i.fcq_id = p_fcq_id and i.substituido_por_id is null;

  if v_itens = 0 then
    raise exception
      'A ficha % não tem um único critério preenchido. Um impresso em branco não é uma FCQ emitida.',
      v_fcq.numero
      using errcode = 'PT409';
  end if;

  select case
           when bool_or(f.valor_final = 'NC')  then 'NAO_CONFORME'
           when bool_or(f.teve_nc)             then 'CONFORME_COM_OBS'
           else 'CONFORME'
         end::betonagens.fcq_conformidade
    into v_conformidade
    from (
      select (array_agg(i.valor order by array_position(
                array['insp','reinsp1','reinsp2','reinsp3']::text[], i.coluna::text) desc))[1]
                                             as valor_final,
             bool_or(i.valor = 'NC')         as teve_nc
        from betonagens.fcq_item i
       where i.fcq_id = p_fcq_id and i.substituido_por_id is null
       group by i.linha_codigo
    ) f;

  insert into betonagens.fcq_versao
    (organizacao_id, obra_id, fcq_id, versao, modelo_impresso_id, conformidade,
     observacoes, dados, ficheiro_pdf_id, sha256_pdf, emitida_por,
     motivo_reemissao, autorizada_por)
  values
    (v_fcq.organizacao_id, v_fcq.obra_id, v_fcq.id, v_proxima,
     v_fcq.modelo_impresso_id, v_conformidade,
     coalesce(v_pab.observacoes, ''), p_dados, p_ficheiro_pdf_id, p_sha256_pdf,
     v_actor.id, nullif(btrim(coalesce(p_motivo_reemissao, '')), ''), v_autoriza)
  returning * into v_versao;

  update betonagens.fcq set estado = 'EMITIDA' where id = v_fcq.id;

  -- O PAB fecha quando a ficha dele sai. A constraint pab_estado_exige_fecho já
  -- garante que só chega aqui quem tem betonagem_fechada_em preenchido.
  if v_pab.estado = 'BETONADO' then
    update betonagens.pab set estado = 'FCQ_FECHADA' where id = v_pab.id;
  end if;

  perform betonagens_priv.emitir_evento(
    v_fcq.organizacao_id, v_fcq.obra_id, 'FCQ_EMITIDA', 'fcq', v_fcq.id,
    jsonb_build_object(
      'numero', v_fcq.numero,
      'versao', v_proxima,
      'conformidade', v_conformidade,
      'pab_numero', v_pab.numero,
      'emitida_por', v_actor.id,
      'sha256_pdf', encode(p_sha256_pdf, 'hex')));

  return v_versao;
end
$fn$;

reset role;

grant execute on function betonagens.emitir_fcq(uuid, integer, uuid, bytea, jsonb, text)
  to authenticated;

-- ── convenção fixada pela 0015 ──────────────────────────────────────────────
set role betonagens_servico;
revoke execute on all routines in schema betonagens, betonagens_priv from public;
reset role;

insert into betonagens.migracao (ficheiro) values ('0023_emissao_fcq.sql');
