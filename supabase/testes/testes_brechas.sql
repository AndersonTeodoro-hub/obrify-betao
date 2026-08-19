-- =============================================================================
-- testes_brechas.sql · Obrify Betão
--
-- Secções A e B do documento de brechas, mais os cenários que nasceram nesta
-- sessão (correção com o mesmo número de guia, correção após assinatura,
-- assinatura fora de vigor). Corre contra a base de dados real: sem mocks,
-- sem duplos, sem fingir.
--
-- COMO CORRER: SQL Editor do Supabase, colar o ficheiro inteiro, Run.
--              Não precisa de psql, de Docker, do CLI, nem de extensões.
--              Ver LEIAME.md nesta pasta.
--
-- PORQUE É QUE ESTÁ ASSIM ESCRITO
--   Todo o trabalho acontece dentro de uma subtransação que é abortada de
--   propósito na última linha. Isso desfaz os dados de teste até ao último
--   registo — o que é obrigatório, porque neste esquema DELETE está revogado
--   e dados de teste não se limpam depois.
--   Os resultados sobrevivem porque vivem numa variável de plpgsql, e as
--   variáveis de plpgsql não são transacionais. É esse o truque, e é o único
--   sítio do ficheiro onde há um.
--   Os blocos de exceção existem para CLASSIFICAR o erro e mostrá-lo na linha
--   do teste. Nenhum é silencioso: tudo o que apanham aparece no resultado.
--
-- O QUE ESPERAR
--   Base vazia (migrações por aplicar): todas as linhas a NAO OK.
--   Migrações 0001 a 0010 aplicadas:    todas as linhas a ok, excepto duas
--                                       marcadas "fora de F1", que são
--                                       omissões declaradas e não falhas.
-- =============================================================================

set search_path = public, pg_catalog;

-- ── auxiliares de teste, em pg_temp: desaparecem com a sessão ────────────────

-- Sem DROP: um `drop table if exists ctx` sem qualificação apanharia uma tabela
-- permanente com o mesmo nome. CREATE TEMP cria sempre em pg_temp, que é o
-- primeiro schema procurado para relações.
create temp table if not exists ctx (chave text primary key, valor uuid);
delete from ctx;

create temp table if not exists resultado_testes (n bigint, estado text, teste text);
delete from resultado_testes;

-- Espera que p_sql falhe com um SQLSTATE concreto. Falhar com outro código é
-- tão mau como não falhar: as duas coisas dão NAO OK, com o código que veio.
create or replace function pg_temp.atira(p_sql text, p_codigo text, p_nome text)
returns text language plpgsql as $h$
begin
  execute p_sql;
  return format('NAO OK  %s  ->  esperava erro %s, a operação passou', p_nome, p_codigo);
exception when others then
  if sqlstate = p_codigo then
    return format('ok      %s', p_nome);
  end if;
  return format('NAO OK  %s  ->  esperava %s, veio %s: %s', p_nome, p_codigo, sqlstate, sqlerrm);
end
$h$;

-- Espera que p_sql corra sem erro.
create or replace function pg_temp.corre(p_sql text, p_nome text)
returns text language plpgsql as $h$
begin
  execute p_sql;
  return format('ok      %s', p_nome);
exception when others then
  return format('NAO OK  %s  ->  %s: %s', p_nome, sqlstate, sqlerrm);
end
$h$;

-- Espera um valor concreto. Recebe SQL em texto para que uma tabela
-- inexistente dê NAO OK em vez de abortar a suite.
create or replace function pg_temp.vale(p_sql text, p_esperado text, p_nome text)
returns text language plpgsql as $h$
declare v text;
begin
  execute p_sql into v;
  if v is not distinct from p_esperado then
    return format('ok      %s', p_nome);
  end if;
  return format('NAO OK  %s  ->  esperava [%s], obteve [%s]', p_nome, p_esperado, coalesce(v, 'NULO'));
exception when others then
  return format('NAO OK  %s  ->  %s: %s', p_nome, sqlstate, sqlerrm);
end
$h$;

-- Igual ao anterior, mas com o papel authenticated e um JWT concreto: é a
-- única forma de observar a RLS, que não se aplica ao dono das tabelas.
--
-- ── ESTAS DUAS EMPRESTAM A IDENTIDADE; NÃO A SUBSTITUEM ─────────────────────
-- O `reset role` do fim repõe o PAPEL, mas o JWT ficava com o último p_sub até
-- alguém o voltar a pôr à mão. Metade do trabalho — e a metade que fica é
-- invisível: o teste a seguir não falha por causa dela, falha um teste de
-- escrita muito mais abaixo, com um PT403 a dizer o nome de outra pessoa.
-- Foi exactamente o que aconteceu ao bloco LG: uma linha a observar a RLS pelos
-- olhos do empreiteiro da outra obra deixou-o a escrever nesta.
-- Por isso guardam o que estava e repõem-no. '' é o que estas definições valem
-- quando ninguém as pôs: identidade_externa() faz nullif sobre ambas.
create or replace function pg_temp.vale_como(p_sql text, p_esperado text, p_nome text, p_sub uuid)
returns text language plpgsql as $h$
declare v text; v_res text; v_claims text; v_sub text;
begin
  v_claims := coalesce(current_setting('request.jwt.claims', true), '');
  v_sub    := coalesce(current_setting('request.jwt.claim.sub', true), '');

  perform set_config('request.jwt.claims', json_build_object('sub', p_sub)::text, true);
  perform set_config('request.jwt.claim.sub', p_sub::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql into v;
    if v is not distinct from p_esperado then
      v_res := format('ok      %s', p_nome);
    else
      v_res := format('NAO OK  %s  ->  esperava [%s], obteve [%s]',
                      p_nome, p_esperado, coalesce(v, 'NULO'));
    end if;
  exception when others then
    v_res := format('NAO OK  %s  ->  %s: %s', p_nome, sqlstate, sqlerrm);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', v_claims, true);
  perform set_config('request.jwt.claim.sub', v_sub, true);
  return v_res;
end
$h$;

create or replace function pg_temp.atira_como(p_sql text, p_codigo text, p_nome text, p_sub uuid)
returns text language plpgsql as $h$
declare v_res text; v_claims text; v_sub text;
begin
  v_claims := coalesce(current_setting('request.jwt.claims', true), '');
  v_sub    := coalesce(current_setting('request.jwt.claim.sub', true), '');

  perform set_config('request.jwt.claims', json_build_object('sub', p_sub)::text, true);
  perform set_config('request.jwt.claim.sub', p_sub::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql;
    v_res := format('NAO OK  %s  ->  esperava erro %s, a operação passou', p_nome, p_codigo);
  exception when others then
    if sqlstate = p_codigo then
      v_res := format('ok      %s', p_nome);
    else
      v_res := format('NAO OK  %s  ->  esperava %s, veio %s: %s', p_nome, p_codigo, sqlstate, sqlerrm);
    end if;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', v_claims, true);
  perform set_config('request.jwt.claim.sub', v_sub, true);
  return v_res;
end
$h$;

-- Igual a vale(), mas com outro fuso horário de sessão. Serve para verificar
-- que nada do que é assinado ou encadeado depende de uma definição de sessão.
create or replace function pg_temp.vale_com_fuso(
  p_sql text, p_esperado text, p_nome text, p_fuso text)
returns text language plpgsql as $h$
declare v text; v_res text;
begin
  perform set_config('TimeZone', p_fuso, true);
  begin
    execute p_sql into v;
    if v is not distinct from p_esperado then
      v_res := format('ok      %s', p_nome);
    else
      v_res := format('NAO OK  %s  ->  esperava [%s], obteve [%s]', p_nome, p_esperado, coalesce(v, 'NULO'));
    end if;
  exception when others then
    v_res := format('NAO OK  %s  ->  %s: %s', p_nome, sqlstate, sqlerrm);
  end;
  perform set_config('TimeZone', 'UTC', true);
  return v_res;
end
$h$;

-- Muda o actor da sessão. Não toca no esquema betonagens, logo é seguro numa
-- base vazia.
create or replace function pg_temp.actor(p_sub uuid)
returns void language plpgsql as $h$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub)::text, true);
  perform set_config('request.jwt.claim.sub', p_sub::text, true);
end
$h$;

-- Preenche as 20 linhas pré-betonagem de uma ficha. Não é um "marcar tudo
-- conforme": é o fixture a fazer, um a um, o que o fiscal faria em obra.
create or replace function pg_temp.preencher_pre_betonagem(
  p_fcq uuid, p_disp text, p_base bigint, p_momento timestamptz)
returns void language plpgsql as $h$
declare l record; n bigint := 0;
begin
  for l in select fl.codigo
             from betonagens.fcq_linha fl
             join betonagens.fcq f on f.modelo_impresso_id = fl.modelo_impresso_id
            where f.id = p_fcq
              and fl.seccao in ('implantacao','cofragem','armaduras')
            order by fl.ordem
  loop
    n := n + 1;
    perform betonagens.marcar_item_fcq(
      gen_random_uuid(), p_fcq, l.codigo, 'insp', 'C', p_momento, p_disp, p_base + n);
  end loop;
end
$h$;

create or replace function pg_temp.assinar_pre_betonagem(
  p_fcq uuid, p_disp text, p_base bigint, p_momento timestamptz)
returns void language plpgsql as $h$
begin
  perform betonagens.assinar_seccao_fcq(p_fcq, 'implantacao', 'insp', p_momento, p_disp, p_base + 1);
  perform betonagens.assinar_seccao_fcq(p_fcq, 'cofragem',    'insp', p_momento, p_disp, p_base + 2);
  perform betonagens.assinar_seccao_fcq(p_fcq, 'armaduras',   'insp', p_momento, p_disp, p_base + 3);
end
$h$;

-- =============================================================================
-- A suite
-- =============================================================================

do $suite$
declare
  r text[] := '{}';

  -- identidades fixas, para poder pôr o JWT a apontar para elas
  k_admin  constant uuid := '10000000-0000-4000-8000-000000000001';
  k_fiscal constant uuid := '10000000-0000-4000-8000-000000000002';
  k_empr   constant uuid := '10000000-0000-4000-8000-000000000003';
  k_empr2  constant uuid := '10000000-0000-4000-8000-000000000004';

begin
  begin   -- <<<<<< subtransação: tudo o que está aqui dentro é desfeito no fim

  -- ══════════════════════════════════════════════════════════════════════════
  -- ESTRUTURA · o que tem de ser verdade antes de existir um único registo
  -- ══════════════════════════════════════════════════════════════════════════

  r := r || pg_temp.vale(
    $q$ select (to_regnamespace('betonagens') is not null)::text $q$,
    'true', 'E01 · esquema betonagens existe');

  r := r || pg_temp.vale(
    $q$ select (to_regnamespace('betonagens_priv') is not null)::text $q$,
    'true', 'E02 · esquema betonagens_priv existe');

  -- B1 · a coluna que nasce NULL "para não bloquear o piloto" e nunca mais
  -- deixa de ser. Este teste é o que faz falhar a revisão de esquema.
  r := r || pg_temp.vale(
    $q$ select a.attnotnull::text from pg_attribute a
         where a.attrelid = 'betonagens.guia_remessa'::regclass and a.attname = 'pab_id' $q$,
    'true', 'E03 · B1 · guia_remessa.pab_id é NOT NULL');

  r := r || pg_temp.vale(
    $q$ select exists (select 1 from pg_constraint c
                        where c.conrelid = 'betonagens.guia_remessa'::regclass
                          and c.conname = 'guia_pab_fk' and c.contype = 'f')::text $q$,
    'true', 'E04 · B1 · chave estrangeira guia_pab_fk existe');

  r := r || pg_temp.vale(
    $q$ select (to_regclass('betonagens.guia_unica_por_central') is not null)::text $q$,
    'true', 'E05 · B5 · índice único da guia por central e ano existe');

  r := r || pg_temp.vale(
    $q$ select (to_regclass('betonagens.ficheiro_guia_sha256_unico') is not null)::text $q$,
    'true', 'E06 · B6 · índice único do sha256 do ficheiro de guia existe');

  -- A1 · o botão está inativo na app, mas e o endpoint? Aqui não há endpoint:
  -- o papel da aplicação não tem privilégio de escrita em lado nenhum.
  r := r || pg_temp.vale(
    $q$ select case when to_regclass('betonagens.guia_remessa') is null then 'tabela inexistente'
               when has_table_privilege('authenticated','betonagens.guia_remessa','INSERT')
               then 'PODE inserir' else 'sem INSERT' end $q$,
    'sem INSERT', 'E07 · A1 · authenticated não tem INSERT em guia_remessa');

  r := r || pg_temp.vale(
    $q$ select case when to_regclass('betonagens.pab') is null then 'tabela inexistente'
               when has_table_privilege('authenticated','betonagens.pab','UPDATE')
               then 'PODE alterar' else 'sem UPDATE' end $q$,
    'sem UPDATE', 'E08 · A3 · authenticated não tem UPDATE em pab');

  r := r || pg_temp.vale(
    $q$ select case when to_regclass('betonagens.guia_remessa') is null then 'tabela inexistente'
               when has_table_privilege('authenticated','betonagens.guia_remessa','DELETE')
               then 'PODE apagar' else 'sem DELETE' end $q$,
    'sem DELETE', 'E09 · B4 · authenticated não tem DELETE em guia_remessa');

  r := r || pg_temp.vale(
    $q$ select case when to_regclass('betonagens.guia_remessa') is null then 'tabela inexistente'
               when has_table_privilege('authenticated','betonagens.guia_remessa','TRUNCATE')
               then 'PODE truncar' else 'sem TRUNCATE' end $q$,
    'sem TRUNCATE', 'E10 · B4 · authenticated não tem TRUNCATE em guia_remessa');

  r := r || pg_temp.vale(
    $q$ select case when to_regclass('betonagens.guia_remessa') is null then 'tabela inexistente'
               when has_table_privilege('service_role','betonagens.guia_remessa','INSERT')
               then 'PODE inserir' else 'sem INSERT' end $q$,
    'sem INSERT', 'E11 · A1 · service_role não tem INSERT em guia_remessa');

  -- A2 · nenhum campo obrigatório tem valor por defeito no servidor.
  -- registar_guia tem 17 parâmetros, 6 com defeito, logo 11 obrigatórios.
  r := r || pg_temp.vale(
    $q$ select (p.pronargs - p.pronargdefaults)::text
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'betonagens' and p.proname = 'registar_guia' $q$,
    '11', 'E12 · A2 · registar_guia tem 11 parâmetros obrigatórios sem defeito');

  -- A4 · todos os caminhos de escrita passam pelo mesmo serviço de domínio
  r := r || pg_temp.vale(
    $q$ select (count(*) = 2)::text from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'betonagens'
           and p.proname in ('registar_guia','corrigir_guia')
           and p.prosrc like '%gravar_guia%' $q$,
    'true', 'E13 · A4 · registar_guia e corrigir_guia usam o mesmo núcleo');

  r := r || pg_temp.vale(
    $q$ select (count(*) = 2)::text from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'betonagens'
           and p.proname in ('marcar_item_fcq','corrigir_item_fcq')
           and p.prosrc like '%gravar_item_fcq%' $q$,
    'true', 'E14 · A4 · marcar e corrigir item usam o mesmo núcleo');

  -- A3 · o estado não muda por PATCH: não existe política de escrita nenhuma
  r := r || pg_temp.vale(
    $q$ select count(*)::text from pg_policy p
          join pg_class c on c.oid = p.polrelid
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'betonagens' and p.polcmd <> 'r' $q$,
    '0', 'E15 · A3 · não existe nenhuma política de escrita no esquema');

  r := r || pg_temp.vale(
    $q$ select count(*)::text from pg_trigger t
         where t.tgrelid = 'betonagens.guia_remessa'::regclass
           and t.tgname = 'guia_remessa_imutavel' and not t.tgisinternal $q$,
    '1', 'E16 · B3 · gatilho de imutabilidade em guia_remessa');

  r := r || pg_temp.vale(
    $q$ select count(*)::text from pg_trigger t
         where t.tgrelid = 'betonagens.pab'::regclass
           and t.tgname = 'pab_sem_delete' and not t.tgisinternal $q$,
    '1', 'E17 · B4 · gatilho que revoga DELETE em pab');

  r := r || pg_temp.vale(
    $q$ select c.relrowsecurity::text from pg_class c
         where c.oid = 'betonagens.guia_remessa'::regclass $q$,
    'true', 'E18 · RLS activa em guia_remessa');

  -- ══════════════════════════════════════════════════════════════════════════
  -- FIXTURES · a via normal. Se estas linhas falharem, o resto falha por
  -- arrasto, e é isso que se quer ver numa base vazia.
  --
  -- Cronologia usada, toda no passado para haver espaço para testar atrasos:
  --   submissão  -50 h   itens -49 h   assinaturas -48 h   aprovação -47 h
  --   betonagem  -46 h   (a guia é declarada muito depois de descarregada)
  -- ══════════════════════════════════════════════════════════════════════════

  perform pg_temp.actor(k_admin);

  r := r || pg_temp.corre($q$
    insert into ctx select 'org', o.id from betonagens.criar_organizacao(
      'TESTE-BRECHAS', 'Organização de teste', 'Ana Arranque',
      'arranque@teste.local', '10000000-0000-4000-8000-000000000001') o
  $q$, 'F01 · organização e administrador criados');

  r := r || pg_temp.corre($q$
    insert into ctx select 'fiscal', u.id from betonagens.registar_utilizador(
      '10000000-0000-4000-8000-000000000002', 'Joaquim Salvador',
      'fiscal@teste.local', 'FISCALIZACAO') u
  $q$, 'F02 · fiscal registado');

  r := r || pg_temp.corre($q$
    insert into ctx select 'empr', u.id from betonagens.registar_utilizador(
      '10000000-0000-4000-8000-000000000003', 'Manuel Ferreira',
      'empreiteiro@teste.local', 'EMPREITEIRO') u
  $q$, 'F03 · empreiteiro registado');

  r := r || pg_temp.corre($q$
    insert into ctx select 'empr2', u.id from betonagens.registar_utilizador(
      '10000000-0000-4000-8000-000000000004', 'Rui Outro',
      'outro@teste.local', 'EMPREITEIRO') u
  $q$, 'F04 · empreiteiro de outra obra registado');

  r := r || pg_temp.corre($q$
    insert into ctx select 'obra1', o.id from betonagens.criar_obra(
      '2602', 'Marina Sul - Bloco B') o
  $q$, 'F05 · obra 2602 criada');

  r := r || pg_temp.corre($q$
    insert into ctx select 'obra2', o.id from betonagens.criar_obra(
      '2603', 'Outra obra') o
  $q$, 'F06 · obra 2603 criada');

  r := r || pg_temp.corre($q$
    insert into ctx select 'frente1', f.id from betonagens.criar_frente(
      (select valor from ctx where chave = 'obra1'), 'Bloco B / Piso 0') f
  $q$, 'F07 · frente criada');

  r := r || pg_temp.corre($q$
    insert into ctx select 'frente2', f.id from betonagens.criar_frente(
      (select valor from ctx where chave = 'obra2'), 'Piso -1') f
  $q$, 'F08 · frente da segunda obra criada');

  r := r || pg_temp.corre($q$
    insert into ctx select 'central', c.id from betonagens.criar_central('Betão Liz', 'BL') c
  $q$, 'F09 · central de betonagem criada');

  r := r || pg_temp.corre($q$
    select betonagens.atribuir_obra((select valor from ctx where chave='fiscal'),
                                    (select valor from ctx where chave='obra1'));
    select betonagens.atribuir_obra((select valor from ctx where chave='empr'),
                                    (select valor from ctx where chave='obra1'));
    select betonagens.atribuir_obra((select valor from ctx where chave='fiscal'),
                                    (select valor from ctx where chave='obra2'));
    select betonagens.atribuir_obra((select valor from ctx where chave='empr2'),
                                    (select valor from ctx where chave='obra2'))
  $q$, 'F10 · acessos às obras atribuídos');

  perform pg_temp.actor(k_empr);

  r := r || pg_temp.corre($q$
    insert into ctx select 'pab1', p.id from betonagens.submeter_pab(
      (select valor from ctx where chave='obra1'),
      (select valor from ctx where chave='frente1'),
      'Laje L0 - painel A', 86.00, 'C30/37',
      (current_date - 3), (current_date - 2),
      now() - interval '50 hours', 'XC4(P)', 22, 'S4',
      p_processo_betonagem => 'Bomba') p
  $q$, 'F11 · PAB 1 submetido');

  r := r || pg_temp.corre($q$
    insert into ctx select 'fcq1', f.id from betonagens.fcq f
     where f.pab_id = (select valor from ctx where chave='pab1')
  $q$, 'F12 · ficha nasceu com o PAB, em rascunho (C1)');

  perform pg_temp.actor(k_fiscal);

  r := r || pg_temp.corre($q$
    select pg_temp.preencher_pre_betonagem(
      (select valor from ctx where chave='fcq1'), 'DISP-FISCAL-0001', 1000,
      now() - interval '49 hours')
  $q$, 'F13 · 20 critérios pré-betonagem marcados um a um');

  r := r || pg_temp.corre($q$
    select pg_temp.assinar_pre_betonagem(
      (select valor from ctx where chave='fcq1'), 'DISP-FISCAL-0001', 1100,
      now() - interval '48 hours')
  $q$, 'F14 · implantação, cofragem e armaduras assinadas');

  r := r || pg_temp.corre($q$
    select betonagens.aprovar_pab((select valor from ctx where chave='pab1'),
      now() - interval '47 hours', 'DISP-FISCAL-0001', 1200)
  $q$, 'F15 · PAB 1 aprovado');

  perform pg_temp.actor(k_empr);

  r := r || pg_temp.corre($q$
    insert into ctx select 'fich1', f.id from betonagens.registar_ficheiro(
      '30000000-0000-4000-8000-000000000001',
      (select valor from ctx where chave='obra1'),
      'GUIA', 'CAMARA', 'guias/2602/118588.jpg',
      sha256(convert_to('fotografia-da-guia-118588','UTF8')), 152340, 'image/jpeg') f
  $q$, 'F16 · fotografia da guia registada');

  r := r || pg_temp.corre($q$
    insert into ctx select 'guia1', g.id from betonagens.registar_guia(
      '20000000-0000-4000-8000-000000000001',
      (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118588', now() - interval '46 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich1'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2001,
      now() - interval '46 hours' - interval '45 minutes', 190, 28.0) g
  $q$, 'F17 · guia registada pela via normal, em 45 segundos e quatro toques');

  r := r || pg_temp.vale($q$
    select p.estado::text from betonagens.pab p
     where p.id = (select valor from ctx where chave='pab1') $q$,
    'EM_BETONAGEM', 'F18 · a primeira guia pôs o PAB em betonagem');

  -- O PAB declara classe de consistência S4 e a guia traz slump, mas os
  -- intervalos de slump não estão semeados, por decisão: não se inventam
  -- valores normativos. A regra R4 fica por avaliar e diz-o em voz alta.
  r := r || pg_temp.vale($q$
    select a.severidade::text from betonagens.alerta a
     where a.tipo = 'LIMIAR_NAO_CONFIGURADO'
       and a.guia_id = (select valor from ctx where chave='guia1') $q$,
    'INFO', 'F19 · regra sem limiar configurado gera alerta, não silêncio');

  -- ══════════════════════════════════════════════════════════════════════════
  -- A · brechas de camada
  -- ══════════════════════════════════════════════════════════════════════════

  -- A1 · validação só no cliente
  r := r || pg_temp.atira($q$
    select betonagens.registar_guia(
      gen_random_uuid(), null, (select valor from ctx where chave='central'),
      '900001', now() - interval '46 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich1'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2900)
  $q$, 'PT422', 'A1.1 · registar_guia sem PAB é recusada pelo serviço');

  -- e a mesma regra, uma camada abaixo, com o esquema a ser atacado
  -- directamente: aqui não há serviço nenhum pelo meio
  r := r || pg_temp.corre($q$
    insert into betonagens.sequencia_dispositivo
      (organizacao_id, dispositivo_id, sequencia, utilizador_id, entidade, entidade_id, momento_declarado)
    values ((select valor from ctx where chave='org'), 'DISP-DIRECTO-001', 1,
            (select valor from ctx where chave='empr'), 'teste', gen_random_uuid(),
            now() - interval '46 hours')
  $q$, 'A1.2a · sequência preparada para o ataque directo');

  r := r || pg_temp.atira($q$
    insert into betonagens.guia_remessa
      (id, organizacao_id, obra_id, pab_id, central_id, numero_guia, ano_civil,
       data_hora_betonagem, volume_m3, classe_betao, ficheiro_id, conformidade,
       registado_por, registado_por_fiscalizacao, momento_declarado,
       dispositivo_id, sequencia_dispositivo)
    select gen_random_uuid(),
           (select valor from ctx where chave='org'),
           (select valor from ctx where chave='obra1'),
           null,
           (select valor from ctx where chave='central'),
           '900002', 0, now() - interval '46 hours', 8.00, 'C30/37',
           (select valor from ctx where chave='fich1'), 'CONFORME',
           (select valor from ctx where chave='empr'), false,
           now() - interval '46 hours', 'DISP-DIRECTO-001', 1
  $q$, '23502', 'A1.2 · INSERT directo sem pab_id viola NOT NULL');

  r := r || pg_temp.atira_como($q$
    insert into betonagens.guia_remessa (id, pab_id) values (gen_random_uuid(), null)
  $q$, '42501', 'A1.3 · authenticated não consegue sequer tentar o INSERT', k_empr);

  -- A2 · API mais permissiva que o UI
  r := r || pg_temp.atira($q$
    select betonagens.registar_guia(
      gen_random_uuid(), (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '900003', null, 8.00, 'C30/37',
      (select valor from ctx where chave='fich1'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2901)
  $q$, 'PT422', 'A2.1 · sem data/hora de betonagem o servidor não assume now()');

  r := r || pg_temp.atira($q$
    select betonagens.registar_guia(
      gen_random_uuid(), (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      null, now() - interval '46 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich1'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2902)
  $q$, 'PT422', 'A2.2 · sem número de guia é recusada');

  r := r || pg_temp.atira($q$
    select betonagens.registar_guia(
      gen_random_uuid(), (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '900004', now() - interval '46 hours', 8.00, 'C30/37',
      null, now() - interval '2 hours', 'DISP-EMPREIT-001', 2903)
  $q$, 'PT422', 'A2.3 · sem fotografia da guia é recusada');

  -- A3 · máquina de estados contornável
  r := r || pg_temp.atira_como($q$
    update betonagens.pab set estado = 'FCQ_FECHADA'
  $q$, '42501', 'A3.1 · authenticated não altera o estado do PAB', k_empr);

  perform pg_temp.actor(k_fiscal);

  r := r || pg_temp.atira($q$
    select betonagens.aprovar_pab((select valor from ctx where chave='pab1'),
      now() - interval '1 hour', 'DISP-FISCAL-0001', 1290)
  $q$, 'PT409', 'A3.2 · aprovar um PAB que já está em betonagem é 409');

  perform pg_temp.actor(k_empr);

  r := r || pg_temp.corre($q$
    insert into ctx select 'pab2', p.id from betonagens.submeter_pab(
      (select valor from ctx where chave='obra1'),
      (select valor from ctx where chave='frente1'),
      'Pilares P9 a P14', 18.50, 'C35/45',
      (current_date - 3), (current_date - 2),
      now() - interval '50 hours', 'XC4(P)', 22, 'S3',
      p_processo_betonagem => 'Balde') p
  $q$, 'A3.3a · PAB 2 submetido na mesma frente');

  r := r || pg_temp.atira($q$
    select betonagens.fechar_betonagem((select valor from ctx where chave='pab2'),
      now() - interval '1 hour', 'DISP-EMPREIT-001', 2910)
  $q$, 'PT409', 'A3.3 · fechar a betonagem de um PAB por aprovar é 409');

  -- A4 · regra implementada só num caminho
  r := r || pg_temp.atira($q$
    select betonagens.corrigir_guia(
      gen_random_uuid(), (select valor from ctx where chave='guia1'),
      'Correcao de teste com motivo suficientemente longo para passar.',
      null, (select valor from ctx where chave='central'),
      '118588', now() - interval '46 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich1'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2911)
  $q$, 'PT422', 'A4.1 · a correção também não aceita guia sem PAB');

  -- A4.2 não vive aqui. Está mais abaixo, a seguir a R6.3. Ver a nota lá.

  -- A5 · modo offline isento de regras
  r := r || pg_temp.atira($q$
    select betonagens.registar_guia(
      gen_random_uuid(), (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '900005', now() - interval '46 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich1'),
      now() + interval '3 hours', 'DISP-EMPREIT-001', 2913)
  $q$, 'PT422', 'A5.1 · registo offline com relógio adiantado é recusado à chegada');

  r := r || pg_temp.corre($q$
    select betonagens.registar_guia(
      '20000000-0000-4000-8000-000000000001',
      (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118588', now() - interval '46 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich1'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2001,
      now() - interval '46 hours' - interval '45 minutes', 190, 28.0)
  $q$, 'A5.2a · reenvio idêntico da fila offline é aceite');

  r := r || pg_temp.vale($q$
    select count(*)::text from betonagens.guia_remessa g
     where g.id = '20000000-0000-4000-8000-000000000001' $q$,
    '1', 'A5.2 · o reenvio não duplicou a guia');

  r := r || pg_temp.atira($q$
    select betonagens.registar_guia(
      '20000000-0000-4000-8000-000000000001',
      (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118999', now() - interval '46 hours', 9.00, 'C30/37',
      (select valor from ctx where chave='fich1'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2001)
  $q$, 'PT409', 'A5.3 · o mesmo id com outro conteúdo é 409, não sobreposição');

  r := r || pg_temp.corre($q$
    insert into ctx select 'fich2', f.id from betonagens.registar_ficheiro(
      '30000000-0000-4000-8000-000000000002',
      (select valor from ctx where chave='obra1'),
      'GUIA', 'CAMARA', 'guias/2602/118591.jpg',
      sha256(convert_to('fotografia-da-guia-118591','UTF8')), 148900, 'image/jpeg') f
  $q$, 'A5.4a · segunda fotografia registada');

  r := r || pg_temp.atira($q$
    select betonagens.registar_guia(
      gen_random_uuid(), (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118591', now() - interval '45 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich2'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2001)
  $q$, 'PT409', 'A5.4 · sequência do dispositivo repetida é 409 (fila adulterada)');

  -- ══════════════════════════════════════════════════════════════════════════
  -- B · brechas de modelo de dados
  -- ══════════════════════════════════════════════════════════════════════════

  -- B2 · PAB genérico / "diversos"
  r := r || pg_temp.atira($q$
    select betonagens.submeter_pab(
      (select valor from ctx where chave='obra1'),
      (select valor from ctx where chave='frente1'),
      '', 40.00, 'C30/37', current_date, current_date, now() - interval '1 hour',
      p_processo_betonagem => 'Bomba')
  $q$, 'PT422', 'B2.1 · PAB sem elemento é recusado');

  r := r || pg_temp.atira($q$
    select betonagens.submeter_pab(
      (select valor from ctx where chave='obra1'),
      (select valor from ctx where chave='frente1'),
      'Sapatas S12 a S15', 0, 'C30/37', current_date, current_date, now() - interval '1 hour',
      p_processo_betonagem => 'Bomba')
  $q$, 'PT422', 'B2.2 · PAB com volume zero é recusado');

  r := r || pg_temp.atira($q$
    insert into betonagens.pab
      (organizacao_id, obra_id, frente_id, numero, elemento, volume_previsto_m3,
       classe_betao, data_pedido, data_prevista, estado, submetido_por,
       submetido_em, submetido_momento_declarado)
    select (select valor from ctx where chave='org'),
           (select valor from ctx where chave='obra1'),
           (select valor from ctx where chave='frente1'),
           999, 'Diversos', 0, 'C30/37', current_date, current_date, 'SUBMETIDO',
           (select valor from ctx where chave='empr'), now(), now()
  $q$, '23514', 'B2.3 · INSERT directo com volume zero viola a constraint');

  -- B3 · edição silenciosa da guia
  r := r || pg_temp.atira($q$
    update betonagens.guia_remessa set volume_m3 = 99.00
     where id = (select valor from ctx where chave='guia1')
  $q$, 'PT403', 'B3.1 · UPDATE do volume da guia é bloqueado pelo gatilho');

  -- B4 · apagar em vez de anular
  r := r || pg_temp.atira($q$
    delete from betonagens.guia_remessa
     where id = (select valor from ctx where chave='guia1')
  $q$, 'PT403', 'B4.1 · DELETE de guia é bloqueado');

  r := r || pg_temp.atira($q$
    delete from betonagens.pab where id = (select valor from ctx where chave='pab2')
  $q$, 'PT403', 'B4.2 · DELETE de PAB é bloqueado');

  r := r || pg_temp.atira($q$
    delete from betonagens.fcq_item where true
  $q$, 'PT403', 'B4.3 · DELETE de itens da ficha é bloqueado');

  r := r || pg_temp.vale($q$
    select (count(*) >= 1)::text from betonagens.guia_remessa $q$,
    'true', 'B4.4 · a contagem de guias não decresceu depois das tentativas de DELETE');

  -- B5 · unicidade da guia só por PAB
  -- pab2 tem de ficar aprovado para poder receber guias: é aqui que R6 aparece
  perform pg_temp.actor(k_fiscal);

  r := r || pg_temp.corre($q$
    insert into ctx select 'fcq2', f.id from betonagens.fcq f
     where f.pab_id = (select valor from ctx where chave='pab2')
  $q$, 'B5.0a · ficha do PAB 2 localizada');

  r := r || pg_temp.corre($q$
    select pg_temp.preencher_pre_betonagem(
      (select valor from ctx where chave='fcq2'), 'DISP-FISCAL-0001', 1300,
      now() - interval '49 hours')
  $q$, 'B5.0b · pré-betonagem do PAB 2 preenchida');

  -- N11 e N12 encaixam aqui, antes de assinar
  r := r || pg_temp.atira($q$
    select betonagens.assinar_seccao_fcq((select valor from ctx where chave='fcq2'),
      'juntas', 'insp', now() - interval '48 hours', 'DISP-FISCAL-0001', 1390)
  $q$, 'PT409', 'N11 · não se assina uma secção incompleta');

  r := r || pg_temp.corre($q$
    select pg_temp.assinar_pre_betonagem(
      (select valor from ctx where chave='fcq2'), 'DISP-FISCAL-0001', 1400,
      now() - interval '48 hours')
  $q$, 'B5.0c · pré-betonagem do PAB 2 assinada');

  r := r || pg_temp.atira($q$
    select betonagens.assinar_seccao_fcq((select valor from ctx where chave='fcq2'),
      'cofragem', 'reinsp1', now() - interval '47 hours', 'DISP-FISCAL-0001', 1391)
  $q$, 'PT409', 'N12 · não há reinspeção sem não conformidade que a justifique');

  -- ══════════════════════════════════════════════════════════════════════════
  -- NOVOS CENÁRIOS · correção após assinatura e assinatura fora de vigor
  -- ══════════════════════════════════════════════════════════════════════════

  r := r || pg_temp.corre($q$
    insert into ctx select 'item_cof', i.id from betonagens.fcq_item i
      join betonagens.fcq_linha l
        on l.modelo_impresso_id = i.modelo_impresso_id and l.codigo = i.linha_codigo
     where i.fcq_id = (select valor from ctx where chave='fcq2')
       and l.seccao = 'cofragem' and i.coluna = 'insp' and i.substituido_por_id is null
     order by i.linha_codigo limit 1
  $q$, 'N02a · item de cofragem localizado');

  r := r || pg_temp.corre($q$
    select betonagens.corrigir_item_fcq(
      gen_random_uuid(), (select valor from ctx where chave='item_cof'),
      'Toque na linha errada durante a inspeccao das cofragens do alinhamento C.',
      (select valor from ctx where chave='fcq2'),
      (select i.linha_codigo from betonagens.fcq_item i
        where i.id = (select valor from ctx where chave='item_cof')),
      'insp', 'NC', now() - interval '47 hours', 'DISP-FISCAL-0001', 1420,
      'Escoramento por reforcar no alinhamento C')
  $q$, 'N01 · corrigir um item de uma secção já assinada é permitido');

  -- Presa ao item que substituiu o item_cof, não ao âmbito da obra: assim não
  -- se parte quando outra asserção criar uma segunda correção após assinatura.
  r := r || pg_temp.vale($q$
    select count(*)::text from betonagens.excecao e
     where e.tipo = 'CORRECAO_APOS_ASSINATURA'
       and e.entidade = 'fcq_item'
       and e.entidade_id = (select i.substituido_por_id from betonagens.fcq_item i
                             where i.id = (select valor from ctx where chave='item_cof')) $q$,
    '1', 'N02 · a correção após assinatura gerou exceção nominal e justificada');

  r := r || pg_temp.vale($q$
    select a.severidade::text from betonagens.alerta a
     where a.tipo = 'CORRECAO_APOS_ASSINATURA'
       and a.fcq_id = (select valor from ctx where chave='fcq2') $q$,
    'AVISO', 'N03 · com o PAB ainda por aprovar, o alerta é AVISO');

  r := r || pg_temp.vale($q$
    select e.em_vigor::text from betonagens.fcq_seccao_estado e
     where e.fcq_id = (select valor from ctx where chave='fcq2')
       and e.seccao = 'cofragem' and e.coluna = 'insp' $q$,
    'false', 'N04 · a assinatura deixou de estar em vigor, por aritmética');

  r := r || pg_temp.atira($q$
    select betonagens.aprovar_pab((select valor from ctx where chave='pab2'),
      now() - interval '46 hours', 'DISP-FISCAL-0001', 1430)
  $q$, 'PT409', 'N05 · não se aprova um PAB com assinatura fora de vigor');

  r := r || pg_temp.atira($q$
    select betonagens.assinar_seccao_fcq((select valor from ctx where chave='fcq2'),
      'cofragem', 'insp', now() - interval '46 hours', 'DISP-FISCAL-0001', 1431)
  $q$, 'PT422', 'N06 · reassinar sem motivo escrito é recusado');

  r := r || pg_temp.corre($q$
    select betonagens.assinar_seccao_fcq((select valor from ctx where chave='fcq2'),
      'cofragem', 'insp', now() - interval '46 hours', 'DISP-FISCAL-0001', 1432,
      'Reassinatura apos correccao do escoramento no alinhamento C.')
  $q$, 'N07 · reassinar com motivo cria uma versão nova');

  r := r || pg_temp.vale($q$
    select count(*)::text from betonagens.fcq_seccao_assinatura a
     where a.fcq_id = (select valor from ctx where chave='fcq2')
       and a.seccao = 'cofragem' and a.coluna = 'insp' $q$,
    '2', 'N08 · a assinatura anterior continua no registo; nada foi anulado');

  r := r || pg_temp.vale($q$
    select e.em_vigor::text from betonagens.fcq_seccao_estado e
     where e.fcq_id = (select valor from ctx where chave='fcq2')
       and e.seccao = 'cofragem' and e.coluna = 'insp' $q$,
    'true', 'N09 · a assinatura voltou a estar em vigor');

  -- a linha ficou NC, portanto a aprovação continua bloqueada por outra razão
  r := r || pg_temp.atira($q$
    select betonagens.aprovar_pab((select valor from ctx where chave='pab2'),
      now() - interval '46 hours', 'DISP-FISCAL-0001', 1433)
  $q$, 'PT409', 'N10 · não se aprova com uma não conformidade por reinspecionar');

  r := r || pg_temp.corre($q$
    select betonagens.marcar_item_fcq(
      gen_random_uuid(), (select valor from ctx where chave='fcq2'),
      (select i.linha_codigo from betonagens.fcq_item i
        where i.id = (select valor from ctx where chave='item_cof')),
      'reinsp1', 'C', now() - interval '46 hours', 'DISP-FISCAL-0001', 1440);
    select betonagens.assinar_seccao_fcq((select valor from ctx where chave='fcq2'),
      'cofragem', 'reinsp1', now() - interval '46 hours', 'DISP-FISCAL-0001', 1441)
  $q$, 'N13 · reinspeção da linha em falta e assinatura da coluna');

  -- R6 · a frente tem o PAB 1 em betonagem
  r := r || pg_temp.atira($q$
    select betonagens.aprovar_pab((select valor from ctx where chave='pab2'),
      now() - interval '45 hours', 'DISP-FISCAL-0001', 1450)
  $q$, 'PT409', 'R6.1 · nova aprovação na mesma frente é bloqueada');

  r := r || pg_temp.corre($q$
    select betonagens.aprovar_pab((select valor from ctx where chave='pab2'),
      now() - interval '45 hours', 'DISP-FISCAL-0001', 1451,
      'Betonagens simultaneas em painel separado, autorizado pelo director de obra.')
  $q$, 'R6.2 · a fiscalização levanta R6 com justificação escrita');

  -- Presa ao PAB 2, não a toda a organização: outro levantamento de R6 noutro
  -- PAB deixa de a afectar.
  r := r || pg_temp.vale($q$
    select count(*)::text from betonagens.excecao e
     where e.tipo = 'OVERRIDE_R6'
       and e.entidade = 'pab'
       and e.entidade_id = (select valor from ctx where chave='pab2') $q$,
    '1', 'R6.3 · o levantamento de R6 ficou registado como exceção');

  -- ── A4.2, deslocada da secção A ──────────────────────────────────────────
  -- Pertence à secção A, ao lado de A4.1: as duas provam que a correção
  -- obedece às mesmas regras do registo. Vive aqui por uma razão concreta.
  --
  -- Em betonagens_priv.gravar_guia, o ramo da correção avalia o ESTADO do PAB
  -- indicado antes de confirmar que esse PAB é o da própria guia. Com o PAB 2
  -- ainda em SUBMETIDO — como está lá em cima — a recusa vem com PT409 "as
  -- guias são read-only", que é verdade sobre o PAB 2 e não diz nada sobre o
  -- que se tentou fazer. Aqui, com o PAB 2 já aprovado, a verificação do
  -- estado passa e dispara a que interessa: PT422, não se muda uma guia de PAB.
  --
  -- DÍVIDA TÉCNICA DECLARADA (opção B, 2026-08-13): a ordem certa é carregar a
  -- guia anterior, confirmar que v_anterior.pab_id = p_pab_id, e só depois
  -- avaliar o estado — que passa então a ser, por construção, o do PAB da
  -- própria guia. Não se fez já porque obriga a um create or replace da função
  -- inteira, ~370 linhas de migração, para melhorar uma mensagem que só uma
  -- chamada malformada alcança: a aplicação passa sempre o pab_id que leu da
  -- guia. A executar na próxima migração que toque em gravar_guia por outra
  -- razão. Feito isso, esta asserção volta para junto de A4.1.
  r := r || pg_temp.atira($q$
    select betonagens.corrigir_guia(
      gen_random_uuid(), (select valor from ctx where chave='guia1'),
      'Correcao de teste com motivo suficientemente longo para passar.',
      (select valor from ctx where chave='pab2'),
      (select valor from ctx where chave='central'),
      '118588', now() - interval '46 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich1'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2912)
  $q$, 'PT422', 'A4.2 · a correção não muda a guia de PAB');

  -- C6 · justificação reaproveitada
  r := r || pg_temp.corre($q$
    insert into ctx select 'item_arm', i.id from betonagens.fcq_item i
      join betonagens.fcq_linha l
        on l.modelo_impresso_id = i.modelo_impresso_id and l.codigo = i.linha_codigo
     where i.fcq_id = (select valor from ctx where chave='fcq1')
       and l.seccao = 'armaduras' and i.coluna = 'insp' and i.substituido_por_id is null
     order by i.linha_codigo limit 1
  $q$, 'C6.0 · item de armaduras do PAB 1 localizado');

  r := r || pg_temp.atira($q$
    select betonagens.corrigir_item_fcq(
      gen_random_uuid(), (select valor from ctx where chave='item_arm'),
      'Betonagens simultaneas em painel separado, autorizado pelo director de obra.',
      (select valor from ctx where chave='fcq1'),
      (select i.linha_codigo from betonagens.fcq_item i
        where i.id = (select valor from ctx where chave='item_arm')),
      'insp', 'NC', now() - interval '44 hours', 'DISP-FISCAL-0001', 1460,
      'Recobrimento insuficiente')
  $q$, 'PT422', 'C6.1 · justificação igual à última do próprio utilizador é recusada');

  r := r || pg_temp.corre($q$
    select betonagens.corrigir_item_fcq(
      gen_random_uuid(), (select valor from ctx where chave='item_arm'),
      'Recobrimento medido de novo com espacadores conferidos no local.',
      (select valor from ctx where chave='fcq1'),
      (select i.linha_codigo from betonagens.fcq_item i
        where i.id = (select valor from ctx where chave='item_arm')),
      'insp', 'NC', now() - interval '44 hours', 'DISP-FISCAL-0001', 1461,
      'Recobrimento insuficiente')
  $q$, 'N14a · correção de armaduras com o PAB já aprovado');

  r := r || pg_temp.vale($q$
    select a.severidade::text from betonagens.alerta a
     where a.tipo = 'CORRECAO_APOS_ASSINATURA'
       and a.fcq_id = (select valor from ctx where chave='fcq1') $q$,
    'CRITICO', 'N14 · correção pré-betonagem com PAB aprovado é alerta CRÍTICO');

  r := r || pg_temp.vale($q$
    select p.estado::text from betonagens.pab p
     where p.id = (select valor from ctx where chave='pab1') $q$,
    'EM_BETONAGEM', 'N15 · o PAB não é desaprovado: betão colocado não se despeja');

  -- alerta não se ignora. Aponta ao alerta do PAB 2, que existe de certeza
  -- (foi criado em N01), para não passar por engano quando N14 falha.
  r := r || pg_temp.atira($q$
    select betonagens.resolver_alerta(
      (select a.id from betonagens.alerta a
        where a.fcq_id = (select valor from ctx where chave='fcq2')
          and a.tipo = 'CORRECAO_APOS_ASSINATURA' limit 1), 'ok')
  $q$, 'PT422', 'N16 · resolver um alerta com "ok" é recusado');

  r := r || pg_temp.corre($q$
    select betonagens.resolver_alerta(
      (select a.id from betonagens.alerta a
        where a.fcq_id = (select valor from ctx where chave='fcq2')
          and a.tipo = 'CORRECAO_APOS_ASSINATURA' limit 1),
      'Correccao verificada em obra; escoramento reforcado e reinspeccionado.')
  $q$, 'N17 · resolver com decisão e motivo escrito é aceite');

  -- ── de volta a B5 ─────────────────────────────────────────────────────────
  perform pg_temp.actor(k_empr);

  r := r || pg_temp.corre($q$
    insert into ctx select 'fich3', f.id from betonagens.registar_ficheiro(
      '30000000-0000-4000-8000-000000000003',
      (select valor from ctx where chave='obra1'),
      'GUIA', 'CAMARA', 'guias/2602/118588-repetida.jpg',
      sha256(convert_to('outra-fotografia-mesma-guia','UTF8')), 151000, 'image/jpeg') f
  $q$, 'B5.0d · terceira fotografia registada');

  r := r || pg_temp.atira($q$
    select betonagens.registar_guia(
      gen_random_uuid(), (select valor from ctx where chave='pab2'),
      (select valor from ctx where chave='central'),
      '118588', now() - interval '44 hours', 6.00, 'C35/45',
      (select valor from ctx where chave='fich3'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2020)
  $q$, 'PT409', 'B5.1 · a mesma guia noutro PAB da mesma obra é 409');

  -- e noutra obra, que é o caso que a unicidade só por PAB deixava passar
  perform pg_temp.actor(k_admin);
  r := r || pg_temp.corre($q$
    select betonagens.atribuir_obra((select valor from ctx where chave='empr'),
                                    (select valor from ctx where chave='obra2'))
  $q$, 'B5.2a · empreiteiro passa a ter acesso à segunda obra');

  perform pg_temp.actor(k_empr);
  r := r || pg_temp.corre($q$
    insert into ctx select 'pab3', p.id from betonagens.submeter_pab(
      (select valor from ctx where chave='obra2'),
      (select valor from ctx where chave='frente2'),
      'Muro M4', 12.00, 'C30/37',
      (current_date - 3), (current_date - 2), now() - interval '50 hours',
      p_processo_betonagem => 'Descarga directa') p
  $q$, 'B5.2b · PAB submetido na segunda obra');

  perform pg_temp.actor(k_fiscal);
  r := r || pg_temp.corre($q$
    insert into ctx select 'fcq3', f.id from betonagens.fcq f
     where f.pab_id = (select valor from ctx where chave='pab3');
    select pg_temp.preencher_pre_betonagem(
      (select f.id from betonagens.fcq f where f.pab_id = (select valor from ctx where chave='pab3')),
      'DISP-FISCAL-0001', 1500, now() - interval '49 hours');
    select pg_temp.assinar_pre_betonagem(
      (select f.id from betonagens.fcq f where f.pab_id = (select valor from ctx where chave='pab3')),
      'DISP-FISCAL-0001', 1600, now() - interval '48 hours');
    select betonagens.aprovar_pab((select valor from ctx where chave='pab3'),
      now() - interval '47 hours', 'DISP-FISCAL-0001', 1610)
  $q$, 'B5.2c · PAB da segunda obra aprovado');

  perform pg_temp.actor(k_empr);
  r := r || pg_temp.corre($q$
    insert into ctx select 'fich4', f.id from betonagens.registar_ficheiro(
      '30000000-0000-4000-8000-000000000004',
      (select valor from ctx where chave='obra2'),
      'GUIA', 'CAMARA', 'guias/2603/118588.jpg',
      sha256(convert_to('fotografia-obra-2603','UTF8')), 149000, 'image/jpeg') f
  $q$, 'B5.2d · fotografia registada na segunda obra');

  r := r || pg_temp.atira($q$
    select betonagens.registar_guia(
      gen_random_uuid(), (select valor from ctx where chave='pab3'),
      (select valor from ctx where chave='central'),
      '118588', now() - interval '46 hours', 6.00, 'C30/37',
      (select valor from ctx where chave='fich4'),
      now() - interval '2 hours', 'DISP-EMPREIT-001', 2030)
  $q$, 'PT409', 'B5.2 · a mesma guia noutra obra da organização é 409');

  -- B6 · ficheiro reutilizado
  r := r || pg_temp.atira($q$
    select betonagens.registar_ficheiro(
      gen_random_uuid(), (select valor from ctx where chave='obra1'),
      'GUIA', 'CAMARA', 'guias/2602/copia.jpg',
      sha256(convert_to('fotografia-da-guia-118588','UTF8')), 152340, 'image/jpeg')
  $q$, 'PT409', 'B6.1 · a mesma fotografia carregada duas vezes é 409');

  r := r || ('- - -   B6.2 · comparação percetual de imagem (pHash): FORA DE F1, '
             || 'por decisão explícita. Não é uma falha.');

  -- B7 · timestamp do cliente aceite como verdade
  r := r || pg_temp.vale($q$
    select (g.recebido_em > g.momento_declarado + interval '1 hour')::text
      from betonagens.guia_remessa g
     where g.id = (select valor from ctx where chave='guia1') $q$,
    'true', 'B7.1 · o servidor gravou o seu próprio relógio, não o do dispositivo');

  r := r || pg_temp.corre($q$
    insert into ctx select 'fich5', f.id from betonagens.registar_ficheiro(
      '30000000-0000-4000-8000-000000000005',
      (select valor from ctx where chave='obra1'),
      'GUIA', 'CAMARA', 'guias/2602/118594.jpg',
      sha256(convert_to('fotografia-da-guia-118594','UTF8')), 150100, 'image/jpeg') f
  $q$, 'B7.2a · fotografia da guia atrasada registada');

  r := r || pg_temp.corre($q$
    insert into ctx select 'guia2', g.id from betonagens.registar_guia(
      '20000000-0000-4000-8000-000000000002',
      (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118594', now() - interval '45 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich5'),
      now() - interval '6 hours', 'DISP-EMPREIT-001', 2040) g
  $q$, 'B7.2b · guia sincronizada 6 h depois do registo no telemóvel');

  r := r || pg_temp.vale($q$
    select a.severidade::text from betonagens.alerta a
     where a.tipo = 'ATRASO_SINCRONIZACAO'
       and a.guia_id = (select valor from ctx where chave='guia2') $q$,
    'AVISO', 'B7.2 · atraso acima de 4 h entra na fila do fiscal como AVISO');

  r := r || pg_temp.corre($q$
    insert into ctx select 'fich6', f.id from betonagens.registar_ficheiro(
      '30000000-0000-4000-8000-000000000006',
      (select valor from ctx where chave='obra1'),
      'GUIA', 'CAMARA', 'guias/2602/118597.jpg',
      sha256(convert_to('fotografia-da-guia-118597','UTF8')), 147000, 'image/jpeg') f
  $q$, 'B7.3a · fotografia da guia muito atrasada registada');

  r := r || pg_temp.corre($q$
    insert into ctx select 'guia3', g.id from betonagens.registar_guia(
      '20000000-0000-4000-8000-000000000003',
      (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118597', now() - interval '44 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich6'),
      now() - interval '30 hours', 'DISP-EMPREIT-001', 2050) g
  $q$, 'B7.3b · guia sincronizada 30 h depois do registo no telemóvel');

  r := r || pg_temp.vale($q$
    select a.severidade::text from betonagens.alerta a
     where a.tipo = 'ATRASO_SINCRONIZACAO'
       and a.guia_id = (select valor from ctx where chave='guia3') $q$,
    'CRITICO', 'B7.3 · atraso acima de 24 h é sinal de risco elevado');

  r := r || ('- - -   B7.4 · o documento de brechas fala em 15 min; a decisão desta '
             || 'sessão fixou 4 h e 24 h (C5). Divergência deliberada, registada aqui.');

  -- B8 · sequência de guias não verificada
  r := r || pg_temp.vale($q$
    select (to_regclass('betonagens.guia_sequencia_central') is not null)::text $q$,
    'true', 'B8.1 · índice que suporta a deteção de saltos por central e dia existe');

  r := r || ('- - -   B8.2 · deteção de saltos na sequência: FORA DE F1, é '
             || 'consolidação diária da fase do índice de risco. Não é uma falha.');

  -- ══════════════════════════════════════════════════════════════════════════
  -- Correção de guia · o cenário que a chave estrangeira DEFERRABLE resolve
  -- ══════════════════════════════════════════════════════════════════════════

  r := r || pg_temp.corre($q$
    insert into ctx select 'guia1b', g.id from betonagens.corrigir_guia(
      '20000000-0000-4000-8000-00000000000b',
      (select valor from ctx where chave='guia1'),
      'Volume mal transcrito da guia em papel: eram 8,5 e nao 8,0 metros cubicos.',
      (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118588', now() - interval '46 hours', 8.50, 'C30/37',
      (select valor from ctx where chave='fich1'),
      now() - interval '1 hour', 'DISP-EMPREIT-001', 2060,
      now() - interval '46 hours' - interval '45 minutes', 190, 28.0) g
  $q$, 'D01 · correção com o MESMO número de guia é aceite (FK deferrable)');

  r := r || pg_temp.vale($q$
    select count(*)::text from betonagens.guia_remessa g
     where g.numero_guia = '118588'
       and g.organizacao_id = (select valor from ctx where chave='org') $q$,
    '2', 'D02 · B3 · ficam dois registos visíveis, o original preservado');

  r := r || pg_temp.vale($q$
    select count(*)::text from betonagens.guia_remessa g
     where g.numero_guia = '118588' and g.substituida_por_id is null
       and g.organizacao_id = (select valor from ctx where chave='org') $q$,
    '1', 'D03 · só uma está em vigor');

  r := r || pg_temp.vale($q$
    select (g.substituida_por_id = (select valor from ctx where chave='guia1b'))::text
      from betonagens.guia_remessa g where g.id = (select valor from ctx where chave='guia1') $q$,
    'true', 'D04 · a original aponta para a que a substituiu');

  r := r || pg_temp.vale($q$
    select (g.volume_m3 = 8.00)::text from betonagens.guia_remessa g
     where g.id = (select valor from ctx where chave='guia1') $q$,
    'true', 'D05 · o valor original não foi alterado, foi superado');

  r := r || pg_temp.vale($q$
    select (g.ficheiro_id = (select valor from ctx where chave='fich1'))::text
      from betonagens.guia_remessa g where g.id = (select valor from ctx where chave='guia1b') $q$,
    'true', 'D06 · a correção reutiliza a fotografia original, sem a recarregar');

  -- ══════════════════════════════════════════════════════════════════════════
  -- Leitura da guia · o que o modelo leu, e a proveniência que daí se deriva
  --
  -- A questão que este bloco responde é uma só: quem escreveu os valores desta
  -- guia? Até à 0022 a resposta era sempre «o empreiteiro», e por isso as
  -- regras que comparavam com o PAB comparavam com o que ele escreveu. Agora há
  -- uma segunda fonte — a fotografia lida — e o servidor compara as duas.
  -- ══════════════════════════════════════════════════════════════════════════

  perform pg_temp.actor(k_empr);

  r := r || pg_temp.corre($q$
    insert into ctx select 'fich7', f.id from betonagens.registar_ficheiro(
      '30000000-0000-4000-8000-000000000007',
      (select valor from ctx where chave='obra1'),
      'GUIA', 'CAMARA', 'guias/2602/118601.jpg',
      sha256(convert_to('fotografia-da-guia-118601','UTF8')), 151900, 'image/jpeg') f
  $q$, 'LG00 · fotografia da guia 118601 registada');

  -- O extraído entra tal como o modelo o produziu: valor e confiança por campo.
  -- A data é construída a partir do mesmo instante que a guia vai declarar, para
  -- o teste dizer respeito à regra e não ao dia em que corre.
  r := r || pg_temp.corre($q$
    insert into ctx select 'leitura1', l.id from betonagens.registar_leitura_guia(
      '50000000-0000-4000-8000-000000000001',
      (select valor from ctx where chave='fich7'),
      'claude-opus-5',
      jsonb_build_object(
        'numero_guia',  jsonb_build_object('valor', '118601',  'confianca', 'ALTA'),
        'volume_m3',    jsonb_build_object('valor', 8,         'confianca', 'ALTA'),
        'classe_betao', jsonb_build_object('valor', 'C30/37',  'confianca', 'ALTA'),
        'data',         jsonb_build_object(
                          'valor', to_char((now() - interval '40 hours')
                                           at time zone 'Europe/Lisbon', 'YYYY-MM-DD'),
                          'confianca', 'ALTA'),
        'central_nome', jsonb_build_object('valor', 'BETAO LIZ - LAGOS', 'confianca', 'ALTA')),
      5200, 380) l
  $q$, 'LG01 · leitura da fotografia registada');

  r := r || pg_temp.vale($q$
    select l.modelo from betonagens.leitura_guia l
     where l.id = (select valor from ctx where chave='leitura1') $q$,
    'claude-opus-5', 'LG02 · a leitura diz que modelo a fez');

  -- A leitura é prova: não se emenda. Corrige-se lendo outra vez.
  r := r || pg_temp.atira($q$
    update betonagens.leitura_guia set modelo = 'outro-qualquer'
     where id = (select valor from ctx where chave='leitura1')
  $q$, 'PT403', 'LG03 · leitura_guia é append-only');

  r := r || pg_temp.vale_como($q$
    select count(*)::text from betonagens.leitura_guia $q$,
    '0', 'LG04 · empreiteiro de outra obra não vê leitura nenhuma', k_empr2);

  -- O travão do defeito que este bloco custou: observar a RLS pelos olhos de
  -- outra pessoa não pode deixar essa pessoa a escrever no lugar de quem estava.
  -- Sem esta linha, a fuga volta e só se manifesta cinco testes abaixo, com um
  -- PT403 a dizer um nome que ninguém pôs ali.
  -- Lê a definição de sessão em vez de chamar identidade_externa(): é a
  -- definição que fugia, e é a única coisa da suite inteira que precisaria de
  -- EXECUTE em betonagens_priv. Um teste que falhasse por privilégio diria
  -- exactamente nada sobre o que veio verificar.
  r := r || pg_temp.vale($q$
    select u.nome from betonagens.utilizador u
     where u.auth_user_id = nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $q$,
    'Manuel Ferreira', 'LG04b · observar a RLS não troca quem escreve a seguir');

  -- A recusa estrutural: a proveniência tem de vir da fotografia que se está a
  -- registar. Sem isto, bastava apontar para a leitura de uma guia conforme.
  r := r || pg_temp.corre($q$
    insert into ctx select 'fich8', f.id from betonagens.registar_ficheiro(
      '30000000-0000-4000-8000-000000000008',
      (select valor from ctx where chave='obra1'),
      'GUIA', 'CAMARA', 'guias/2602/118602.jpg',
      sha256(convert_to('fotografia-da-guia-118602','UTF8')), 149800, 'image/jpeg') f
  $q$, 'LG05a · segunda fotografia registada');

  r := r || pg_temp.atira($q$
    select betonagens.registar_guia(
      gen_random_uuid(), (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118602', now() - interval '40 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich8'),
      now() - interval '1 hour', 'DISP-EMPREIT-001', 2210,
      p_leitura_id => (select valor from ctx where chave='leitura1'))
  $q$, 'PT422', 'LG05 · uma leitura de outra fotografia é recusada');

  -- ── o caminho feliz: o registo bate certo com o papel ─────────────────────
  r := r || pg_temp.corre($q$
    insert into ctx select 'guia_lida', g.id from betonagens.registar_guia(
      '20000000-0000-4000-8000-000000000020',
      (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118601', now() - interval '40 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich7'),
      now() - interval '1 hour', 'DISP-EMPREIT-001', 2200,
      p_leitura_id => (select valor from ctx where chave='leitura1')) g
  $q$, 'LG06 · guia registada com a leitura da própria fotografia');

  r := r || pg_temp.vale($q$
    select (g.proveniencia = jsonb_build_object(
              'numero_guia','LIDO','volume_m3','LIDO','classe_betao','LIDO','data','LIDO'))::text
      from betonagens.guia_remessa g
     where g.id = (select valor from ctx where chave='guia_lida') $q$,
    'true', 'LG07 · os quatro campos ficaram LIDO, derivados pelo servidor');

  r := r || pg_temp.vale($q$
    select g.conformidade::text from betonagens.guia_remessa g
     where g.id = (select valor from ctx where chave='guia_lida') $q$,
    'CONFORME', 'LG08 · registo igual ao lido não levanta nada');

  -- ── R9 · corrigir por cima de uma leitura de confiança alta ───────────────
  r := r || pg_temp.corre($q$
    insert into ctx select 'leitura2', l.id from betonagens.registar_leitura_guia(
      '50000000-0000-4000-8000-000000000002',
      (select valor from ctx where chave='fich8'),
      'claude-opus-5',
      jsonb_build_object(
        'numero_guia',  jsonb_build_object('valor', '118602', 'confianca', 'ALTA'),
        'volume_m3',    jsonb_build_object('valor', 8,        'confianca', 'ALTA'),
        'classe_betao', jsonb_build_object('valor', 'C30/37', 'confianca', 'ALTA'),
        'data',         jsonb_build_object(
                          'valor', to_char((now() - interval '39 hours')
                                           at time zone 'Europe/Lisbon', 'YYYY-MM-DD'),
                          'confianca', 'ALTA')),
      5100, 360) l
  $q$, 'LG09a · leitura da segunda fotografia registada');

  r := r || pg_temp.corre($q$
    insert into ctx select 'guia_corrigida', g.id from betonagens.registar_guia(
      '20000000-0000-4000-8000-000000000021',
      (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118602', now() - interval '39 hours', 9.00, 'C30/37',
      (select valor from ctx where chave='fich8'),
      now() - interval '1 hour', 'DISP-EMPREIT-001', 2201,
      p_leitura_id => (select valor from ctx where chave='leitura2')) g
  $q$, 'LG09b · guia registada com 9,00 m3 onde o papel diz 8,00');

  r := r || pg_temp.vale($q$
    select g.proveniencia ->> 'volume_m3' from betonagens.guia_remessa g
     where g.id = (select valor from ctx where chave='guia_corrigida') $q$,
    'CORRIGIDO', 'LG09 · o volume alterado fica CORRIGIDO, não LIDO');

  r := r || pg_temp.vale($q$
    select g.conformidade::text from betonagens.guia_remessa g
     where g.id = (select valor from ctx where chave='guia_corrigida') $q$,
    'COM_ALERTA', 'LG10 · R9 · corrigir sobre leitura ALTA baixa a conformidade');

  r := r || pg_temp.vale($q$
    select g.proveniencia ->> 'numero_guia' from betonagens.guia_remessa g
     where g.id = (select valor from ctx where chave='guia_corrigida') $q$,
    'LIDO', 'LG11 · a correcção de um campo não contamina os outros');

  -- ── R10 · a classe do papel manda, mesmo escrevendo a do PAB ──────────────
  r := r || pg_temp.corre($q$
    insert into ctx select 'fich9', f.id from betonagens.registar_ficheiro(
      '30000000-0000-4000-8000-000000000009',
      (select valor from ctx where chave='obra1'),
      'GUIA', 'CAMARA', 'guias/2602/118603.jpg',
      sha256(convert_to('fotografia-da-guia-118603','UTF8')), 148700, 'image/jpeg') f
  $q$, 'LG12a · terceira fotografia registada');

  -- Classe lida com confiança ALTA e diferente da do PAB; a data ilegível, para
  -- provar de caminho que um campo por ler não entra na proveniência.
  r := r || pg_temp.corre($q$
    insert into ctx select 'leitura3', l.id from betonagens.registar_leitura_guia(
      '50000000-0000-4000-8000-000000000003',
      (select valor from ctx where chave='fich9'),
      'claude-opus-5',
      jsonb_build_object(
        'numero_guia',  jsonb_build_object('valor', '118603', 'confianca', 'ALTA'),
        'volume_m3',    jsonb_build_object('valor', 8,        'confianca', 'ALTA'),
        'classe_betao', jsonb_build_object('valor', 'C25/30', 'confianca', 'ALTA'),
        'data',         jsonb_build_object('valor', null::text, 'confianca', 'BAIXA')),
      5000, 350) l
  $q$, 'LG12b · leitura com classe divergente e data ilegível');

  r := r || pg_temp.corre($q$
    insert into ctx select 'guia_classe', g.id from betonagens.registar_guia(
      '20000000-0000-4000-8000-000000000022',
      (select valor from ctx where chave='pab1'),
      (select valor from ctx where chave='central'),
      '118603', now() - interval '38 hours', 8.00, 'C30/37',
      (select valor from ctx where chave='fich9'),
      now() - interval '1 hour', 'DISP-EMPREIT-001', 2202,
      p_leitura_id => (select valor from ctx where chave='leitura3')) g
  $q$, 'LG12c · guia registada com a classe do PAB, contra o que o papel diz');

  r := r || pg_temp.vale($q$
    select g.conformidade::text from betonagens.guia_remessa g
     where g.id = (select valor from ctx where chave='guia_classe') $q$,
    'NAO_CONFORME', 'LG12 · R10 · a classe lida manda, mesmo escrevendo a do PAB');

  r := r || pg_temp.vale($q$
    select (a.mensagem like 'R10 %')::text from betonagens.alerta a
     where a.tipo = 'CLASSE_DIVERGENTE'
       and a.guia_id = (select valor from ctx where chave='guia_classe') $q$,
    'true', 'LG13 · o alerta conta a história certa: a divergência veio da leitura');

  -- jsonb_exists() e não o operador ?: a suite é colada num editor, e um ponto
  -- de interrogação em SQL cru é um sítio onde clientes se enganam a fingir que
  -- é um parâmetro. A função faz exactamente o mesmo sem essa hipótese.
  r := r || pg_temp.vale($q$
    select jsonb_exists(g.proveniencia, 'data')::text from betonagens.guia_remessa g
     where g.id = (select valor from ctx where chave='guia_classe') $q$,
    'false', 'LG14 · campo que o modelo não leu não entra na proveniência');

  -- ── sem leitura, tudo manual ──────────────────────────────────────────────
  r := r || pg_temp.vale($q$
    select (g.leitura_id is null and g.proveniencia is null)::text
      from betonagens.guia_remessa g
     where g.id = (select valor from ctx where chave='guia2') $q$,
    'true', 'LG15 · uma guia sem leitura não afirma proveniência nenhuma');

  -- ── idempotência e recusas do registo da leitura ──────────────────────────
  r := r || pg_temp.corre($q$
    select betonagens.registar_leitura_guia(
      '50000000-0000-4000-8000-000000000003',
      (select valor from ctx where chave='fich9'),
      'claude-opus-5',
      jsonb_build_object(
        'numero_guia',  jsonb_build_object('valor', '118603', 'confianca', 'ALTA'),
        'volume_m3',    jsonb_build_object('valor', 8,        'confianca', 'ALTA'),
        'classe_betao', jsonb_build_object('valor', 'C25/30', 'confianca', 'ALTA'),
        'data',         jsonb_build_object('valor', null::text, 'confianca', 'BAIXA')),
      5000, 350)
  $q$, 'LG16 · a mesma leitura reenviada devolve o que já lá está');

  r := r || pg_temp.atira($q$
    select betonagens.registar_leitura_guia(
      '50000000-0000-4000-8000-000000000003',
      (select valor from ctx where chave='fich9'),
      'claude-opus-5',
      jsonb_build_object(
        'numero_guia', jsonb_build_object('valor', '999999', 'confianca', 'ALTA')),
      5000, 350)
  $q$, 'PT409', 'LG17 · a mesma chave com outro extraído é conflito, não sobreposição');

  r := r || pg_temp.corre($q$
    insert into ctx select 'fich_impresso', f.id from betonagens.registar_ficheiro(
      '30000000-0000-4000-8000-00000000000a',
      (select valor from ctx where chave='obra1'),
      'PAB_IMPRESSO', 'CAMARA', 'guias/2602/impresso.jpg',
      sha256(convert_to('impresso-assinado','UTF8')), 90000, 'image/jpeg') f
  $q$, 'LG18a · ficheiro que não é guia registado');

  r := r || pg_temp.atira($q$
    select betonagens.registar_leitura_guia(
      gen_random_uuid(),
      (select valor from ctx where chave='fich_impresso'),
      'claude-opus-5',
      jsonb_build_object('numero_guia', jsonb_build_object('valor','1','confianca','ALTA')),
      100, 100)
  $q$, 'PT422', 'LG18 · só se lê o que é fotografia de guia');

  r := r || pg_temp.atira($q$
    select betonagens.registar_leitura_guia(
      gen_random_uuid(),
      (select valor from ctx where chave='fich9'),
      'claude-opus-5', '[]'::jsonb, 100, 100)
  $q$, 'PT422', 'LG19 · o extraído tem de ser um objecto, não uma lista');

  -- ══════════════════════════════════════════════════════════════════════════
  -- Emissão da FCQ · o impresso preenchido passa a versão, e o PAB fecha
  --
  -- O PDF em si é feito pela Edge Function gerar-fcq, que não corre em SQL. O
  -- que aqui se prova é o que a base decide: quem emite, quando, com que
  -- documento, com que conformidade, e o que acontece ao PAB a seguir.
  --
  -- Dois caminhos, de propósito: a ficha do PAB 3, com os 20 critérios
  -- conformes, e a do PAB 1, que ficou com uma não conformidade por resolver
  -- desde a N14a. É a diferença entre CONFORME e NAO_CONFORME, e é derivada —
  -- não é declarada por quem emite.
  -- ══════════════════════════════════════════════════════════════════════════

  perform pg_temp.actor(k_empr);

  -- R8 · não se fecha uma betonagem sem guias, e sem fechar não se emite
  r := r || pg_temp.corre($q$
    select betonagens.registar_guia(
      '20000000-0000-4000-8000-000000000030',
      (select valor from ctx where chave='pab3'),
      (select valor from ctx where chave='central'),
      '118700', now() - interval '40 hours', 12.00, 'C30/37',
      (select valor from ctx where chave='fich4'),
      now() - interval '1 hour', 'DISP-EMPREIT-001', 2300)
  $q$, 'FQ00 · guia registada no PAB da segunda obra');

  r := r || pg_temp.corre($q$
    select betonagens.fechar_betonagem((select valor from ctx where chave='pab3'),
      now() - interval '20 minutes', 'DISP-EMPREIT-001', 2301)
  $q$, 'FQ01 · betonagem do PAB 3 fechada');

  perform pg_temp.actor(k_fiscal);

  r := r || pg_temp.corre($q$
    insert into ctx select 'pdf3', f.id from betonagens.registar_ficheiro(
      '31000000-0000-4000-8000-000000000003',
      (select valor from ctx where chave='obra2'),
      'FCQ_PDF', 'GERADO', 'fcq/2603/fcq3-v1.pdf',
      sha256(convert_to('pdf-da-fcq-3-v1','UTF8')), 73177, 'application/pdf') f
  $q$, 'FQ02 · PDF da ficha registado como GERADO');

  r := r || pg_temp.corre($q$
    insert into ctx select 'versao3', v.id from betonagens.emitir_fcq(
      (select valor from ctx where chave='fcq3'), 1,
      (select valor from ctx where chave='pdf3'),
      sha256(convert_to('pdf-da-fcq-3-v1','UTF8')),
      jsonb_build_object('n_obra','2603','numero','033 / 002')) v
  $q$, 'FQ03 · ficha do PAB 3 emitida');

  r := r || pg_temp.vale($q$
    select f.estado::text from betonagens.fcq f
     where f.id = (select valor from ctx where chave='fcq3') $q$,
    'EMITIDA', 'FQ04 · a ficha passa a EMITIDA');

  r := r || pg_temp.vale($q$
    select p.estado::text from betonagens.pab p
     where p.id = (select valor from ctx where chave='pab3') $q$,
    'FCQ_FECHADA', 'FQ05 · o PAB fecha quando a ficha dele sai');

  -- A conformidade não é parâmetro: os 20 critérios estão conformes, logo a
  -- ficha está conforme. Se um dia alguém a passar a parâmetro, esta linha cai.
  r := r || pg_temp.vale($q$
    select v.conformidade::text from betonagens.fcq_versao v
     where v.id = (select valor from ctx where chave='versao3') $q$,
    'CONFORME', 'FQ06 · conformidade derivada dos itens, não declarada');

  r := r || pg_temp.vale($q$
    select v.observacoes from betonagens.fcq_versao v
     where v.id = (select valor from ctx where chave='versao3') $q$,
    '', 'FQ07 · sem observações no PAB, a ficha sai com o campo vazio');

  -- Reenviar a mesma emissão depois de uma falha de rede não cria versão nova.
  r := r || pg_temp.vale($q$
    select (v.id = (select valor from ctx where chave='versao3'))::text
      from betonagens.emitir_fcq(
        (select valor from ctx where chave='fcq3'), 1,
        (select valor from ctx where chave='pdf3'),
        sha256(convert_to('pdf-da-fcq-3-v1','UTF8')),
        jsonb_build_object('n_obra','2603','numero','033 / 002')) v $q$,
    'true', 'FQ08 · a mesma versão reenviada devolve a que já existe');

  r := r || pg_temp.atira($q$
    select betonagens.emitir_fcq(
      (select valor from ctx where chave='fcq3'), 5,
      (select valor from ctx where chave='pdf3'),
      sha256(convert_to('pdf-da-fcq-3-v1','UTF8')),
      '{}'::jsonb, 'Motivo suficientemente longo para a regra D4 passar.')
  $q$, 'PT409', 'FQ09 · uma versão fora da sequência é recusada');

  r := r || pg_temp.corre($q$
    insert into ctx select 'pdf3b', f.id from betonagens.registar_ficheiro(
      '31000000-0000-4000-8000-000000000004',
      (select valor from ctx where chave='obra2'),
      'FCQ_PDF', 'GERADO', 'fcq/2603/fcq3-v2.pdf',
      sha256(convert_to('pdf-da-fcq-3-v2','UTF8')), 73180, 'application/pdf') f
  $q$, 'FQ10a · segundo PDF registado');

  r := r || pg_temp.atira($q$
    select betonagens.emitir_fcq(
      (select valor from ctx where chave='fcq3'), 2,
      (select valor from ctx where chave='pdf3b'),
      sha256(convert_to('pdf-da-fcq-3-v2','UTF8')), '{}'::jsonb)
  $q$, 'PT422', 'FQ10 · D4 · reemitir sem motivo escrito é recusado');

  r := r || pg_temp.corre($q$
    select betonagens.emitir_fcq(
      (select valor from ctx where chave='fcq3'), 2,
      (select valor from ctx where chave='pdf3b'),
      sha256(convert_to('pdf-da-fcq-3-v2','UTF8')), '{}'::jsonb,
      'Primeiro documento ilegivel no arquivo do dono de obra; reemitido igual.')
  $q$, 'FQ11 · D4 · com motivo escrito, a reemissão passa');

  r := r || pg_temp.vale($q$
    select count(*)::text from betonagens.fcq_versao v
     where v.fcq_id = (select valor from ctx where chave='fcq3') $q$,
    '2', 'FQ12 · a versão anterior não desaparece: ficam as duas');

  -- ── o PAB 1, com a não conformidade que a N14a deixou por resolver ────────
  perform pg_temp.actor(k_empr);

  r := r || pg_temp.corre($q$
    select betonagens.fechar_betonagem((select valor from ctx where chave='pab1'),
      now() - interval '10 minutes', 'DISP-EMPREIT-001', 2310)
  $q$, 'FQ13 · betonagem do PAB 1 fechada');

  r := r || pg_temp.atira($q$
    select betonagens.emitir_fcq(
      (select valor from ctx where chave='fcq1'), 1,
      (select valor from ctx where chave='fich1'),
      sha256(convert_to('seja-o-que-for','UTF8')), '{}'::jsonb)
  $q$, 'PT403', 'FQ14 · o empreiteiro não emite a ficha da fiscalização');

  perform pg_temp.actor(k_fiscal);

  -- A fotografia de uma guia não é uma FCQ, por muito que seja um ficheiro da
  -- mesma obra.
  r := r || pg_temp.atira($q$
    select betonagens.emitir_fcq(
      (select valor from ctx where chave='fcq1'), 1,
      (select valor from ctx where chave='fich1'),
      sha256(convert_to('fotografia-da-guia-118588','UTF8')), '{}'::jsonb)
  $q$, 'PT422', 'FQ15 · só um PDF de ficha serve de documento emitido');

  r := r || pg_temp.corre($q$
    insert into ctx select 'pdf1', f.id from betonagens.registar_ficheiro(
      '31000000-0000-4000-8000-000000000001',
      (select valor from ctx where chave='obra1'),
      'FCQ_PDF', 'GERADO', 'fcq/2602/fcq1-v1.pdf',
      sha256(convert_to('pdf-da-fcq-1-v1','UTF8')), 74000, 'application/pdf') f
  $q$, 'FQ16a · PDF da ficha do PAB 1 registado');

  r := r || pg_temp.corre($q$
    insert into ctx select 'versao1', v.id from betonagens.emitir_fcq(
      (select valor from ctx where chave='fcq1'), 1,
      (select valor from ctx where chave='pdf1'),
      sha256(convert_to('pdf-da-fcq-1-v1','UTF8')),
      jsonb_build_object('n_obra','2602','numero','033 / 001')) v
  $q$, 'FQ16 · ficha do PAB 1 emitida');

  -- A N14a deixou um item de armaduras em NC, sem reinspeção. O documento sai
  -- na mesma — o impresso é o registo do que aconteceu — mas sai a dizê-lo.
  r := r || pg_temp.vale($q$
    select v.conformidade::text from betonagens.fcq_versao v
     where v.id = (select valor from ctx where chave='versao1') $q$,
    'NAO_CONFORME', 'FQ17 · uma NC por resolver torna a ficha não conforme');

  r := r || pg_temp.vale($q$
    select (v.dados ->> 'numero') from betonagens.fcq_versao v
     where v.id = (select valor from ctx where chave='versao1') $q$,
    '033 / 001', 'FQ18 · o que foi impresso fica guardado com a versão');

  -- R7 · depois de emitida, a ficha é read-only. Já era verdade antes desta
  -- migração; o que muda é que agora existe quem a ponha em EMITIDA.
  r := r || pg_temp.atira($q$
    select betonagens.marcar_item_fcq(
      gen_random_uuid(), (select valor from ctx where chave='fcq1'), 'L01',
      'reinsp1', 'C', now() - interval '5 minutes', 'DISP-FISCAL-0001', 1700)
  $q$, 'PT409', 'FQ19 · emitida a ficha, não entram mais critérios');

  r := r || pg_temp.vale($q$
    select count(*)::text from betonagens.evento_saida e
     where e.tipo = 'FCQ_EMITIDA'
       and e.agregado_id = (select valor from ctx where chave='fcq1') $q$,
    '1', 'FQ20 · a emissão sai como evento para quem integrar');

  -- ══════════════════════════════════════════════════════════════════════════
  -- RLS · isolamento por obra ao nível da base de dados
  -- ══════════════════════════════════════════════════════════════════════════

  r := r || pg_temp.vale_como($q$
    select count(*)::text from betonagens.guia_remessa $q$,
    '0', 'L01 · empreiteiro de outra obra não vê guia nenhuma', k_empr2);

  -- Presa ao PAB 3, o da obra 2. Identificado pelo elemento e não pelo id
  -- porque esta consulta corre com o papel authenticated, que não tem
  -- privilégio nenhum sobre a tabela temporária ctx. O outro lado da moeda —
  -- que este empreiteiro não vê a obra 1 — está em L01 e em L05.
  r := r || pg_temp.vale_como($q$
    select count(*)::text from betonagens.pab p where p.elemento = 'Muro M4' $q$,
    '1', 'L02 · esse empreiteiro vê o PAB da obra dele', k_empr2);

  r := r || pg_temp.vale_como($q$
    select (count(*) >= 3)::text from betonagens.guia_remessa $q$,
    'true', 'L03 · o empreiteiro da obra vê as guias da obra dele', k_empr);

  -- as exceções foram todas registadas na obra 1; a excecao é de âmbito de obra
  r := r || pg_temp.vale_como($q$
    select count(*)::text from betonagens.excecao $q$,
    '0', 'L04 · empreiteiro de outra obra não vê as exceções da obra 1', k_empr2);

  -- empr2 tem acesso à obra 2, e só a ela: vê itens de uma obra, não de duas
  r := r || pg_temp.vale_como($q$
    select count(distinct i.obra_id)::text from betonagens.fcq_item i $q$,
    '1', 'L05 · esse empreiteiro só vê itens de uma obra', k_empr2);

  r := r || pg_temp.vale_como($q$
    select count(distinct i.obra_id)::text from betonagens.fcq_item i $q$,
    '2', 'L06 · o empreiteiro com duas obras atribuídas vê as duas', k_empr);

  -- ══════════════════════════════════════════════════════════════════════════
  -- atualizar_obra · o cabeçalho do impresso corrige-se, a identidade não
  --
  -- Fica no fim de propósito: altera a obra 1, e assim nada do que vem antes
  -- depende do que aqui se muda. O elo que este bloco escreve é depois
  -- recalculado por G01, junto com todos os outros.
  -- ══════════════════════════════════════════════════════════════════════════

  -- O código da obra não se muda, e o que o impede não é uma validação que
  -- alguém possa esquecer numa revisão futura: é um parâmetro que não existe.
  -- Uma validação prova-se com um teste que a exercite; uma ausência prova-se
  -- assim, contra o catálogo.
  r := r || pg_temp.vale($q$
    select (count(*) = 0)::text
      from pg_proc p
     cross join lateral unnest(coalesce(p.proargnames, '{}'::text[])) a(nome)
     where p.oid = 'betonagens.atualizar_obra(uuid,text,text,text,text)'::regprocedure
       and a.nome = 'p_codigo' $q$,
    'true', 'O01 · atualizar_obra não tem parâmetro p_codigo');

  perform pg_temp.actor(k_empr);

  r := r || pg_temp.atira($q$
    select betonagens.atualizar_obra(
      (select valor from ctx where chave='obra1'), 'Tentativa do empreiteiro')
  $q$, 'PT403', 'O02 · empreiteiro não corrige o cabeçalho da obra');

  perform pg_temp.actor(k_admin);

  r := r || pg_temp.atira($q$
    select betonagens.atualizar_obra(
      (select valor from ctx where chave='obra1'), '  ')
  $q$, 'PT422', 'O03 · designação em branco é recusada');

  -- A suite inteira vive numa organização só, e sem um «fora» não há como
  -- testar o isolamento entre organizações. Esta vizinha existe para isso e
  -- para mais nada: cria-se, cria-se-lhe uma obra com o administrador dela, e
  -- volta-se ao administrador de sempre.
  r := r || pg_temp.corre($q$
    select betonagens.criar_organizacao(
      'TESTE-VIZINHA', 'Organização vizinha', 'Sara Vizinha',
      'vizinha@teste.local', '10000000-0000-4000-8000-000000000009');
    select set_config('request.jwt.claims',
      json_build_object('sub', '10000000-0000-4000-8000-000000000009')::text, true);
    select set_config('request.jwt.claim.sub',
      '10000000-0000-4000-8000-000000000009', true);
    insert into ctx select 'obra_vizinha', o.id from betonagens.criar_obra(
      '9001', 'Obra da organização vizinha') o
  $q$, 'O04 · organização vizinha com obra própria');

  perform pg_temp.actor(k_admin);

  r := r || pg_temp.atira($q$
    select betonagens.atualizar_obra(
      (select valor from ctx where chave='obra_vizinha'), 'Não devia passar')
  $q$, 'PT403', 'O05 · obra de outra organização é recusada');

  r := r || pg_temp.corre($q$
    select betonagens.atualizar_obra(
      (select valor from ctx where chave='obra1'),
      'Marina Sul - Bloco B',
      'Palmares - Comp. Empreendimentos Turísticos, SA',
      'Ferreira Construção, S.A.',
      'DDN - Engenharia e Fiscalização')
  $q$, 'O06 · cabeçalho do impresso corrigido');

  -- Uma correcção de cabeçalho não desaparece. O gatilho obra_ledger grava
  -- {antes, depois}, e o que se verifica aqui é precisamente isso: o valor
  -- antigo continua legível ao lado do novo.
  r := r || pg_temp.vale($q$
    select format('%s -> %s',
             coalesce(l.dados -> 'antes' ->> 'dono_obra', 'nulo'),
             coalesce(l.dados -> 'depois' ->> 'dono_obra', 'nulo'))
      from betonagens.ledger l
     where l.entidade = 'obra'
       and l.acao = 'UPDATE'
       and l.entidade_id = (select valor from ctx where chave='obra1')::text
     order by l.seq desc
     limit 1 $q$,
    'nulo -> Palmares - Comp. Empreendimentos Turísticos, SA',
    'O07 · a correcção ficou no ledger, com o antes e o depois');

  -- ══════════════════════════════════════════════════════════════════════════
  -- Acessos · quem vê o quê, e como nasce um fiscal
  --
  -- A partir da 0020 a fiscalização vê a organização inteira, não só as obras
  -- que alguém se lembrou de lhe atribuir — é da empresa, não do contrato. O
  -- empreiteiro continua preso às obras atribuídas, e é isso que impede a
  -- empresa A de ver a obra da empresa B.
  -- ══════════════════════════════════════════════════════════════════════════

  perform pg_temp.actor(k_admin);

  -- Uma obra que NINGUÉM atribuiu a ninguém. É contra ela que se prova a
  -- diferença: se o fiscal a vir, vê por ser da organização, não por atribuição.
  r := r || pg_temp.corre($q$
    insert into ctx select 'obra3', o.id from betonagens.criar_obra(
      '2604', 'Obra sem ninguém atribuído') o
  $q$, 'P01 · obra sem atribuições criada');

  r := r || pg_temp.vale_como($q$
    select count(*)::text from betonagens.obra $q$,
    '3', 'P02 · o fiscal vê as três obras da organização, incluindo a não atribuída',
    k_fiscal);

  r := r || pg_temp.vale_como($q$
    select count(*)::text from betonagens.obra $q$,
    '1', 'P03 · o empreiteiro continua a ver só a obra que lhe foi atribuída', k_empr2);

  -- ── o código de registo ───────────────────────────────────────────────────

  r := r || pg_temp.atira_como($q$
    select betonagens.gerar_codigo_registo(30)
  $q$, 'PT403', 'P04 · a fiscalização não gera códigos de registo', k_fiscal);

  perform pg_temp.actor(k_admin);

  r := r || pg_temp.corre($q$
    insert into ctx select 'codigo1', c.id from betonagens.gerar_codigo_registo(30) c
  $q$, 'P05 · o ADMIN gerou um código');

  r := r || pg_temp.vale($q$
    select c.perfil::text from betonagens.codigo_registo c
     where c.id = (select valor from ctx where chave='codigo1') $q$,
    'FISCALIZACAO', 'P06 · o código só concede FISCALIZACAO');

  -- Renovar revoga o anterior: sem isto ficariam vários códigos válidos, e
  -- revogar um deixaria de significar alguma coisa.
  r := r || pg_temp.corre($q$
    insert into ctx select 'codigo2', c.id from betonagens.gerar_codigo_registo(15) c
  $q$, 'P07 · o ADMIN renovou o código');

  r := r || pg_temp.vale($q$
    select count(*)::text from betonagens.codigo_registo c
     where c.revogado_em is null $q$,
    '1', 'P08 · só há um código activo de cada vez');

  r := r || pg_temp.vale($q$
    select (c.revogado_por is not null)::text from betonagens.codigo_registo c
     where c.id = (select valor from ctx where chave='codigo1') $q$,
    'true', 'P09 · o código anterior ficou revogado com autor');

  -- Um código para EMPREITEIRO não se cria nem por INSERT directo: a constraint
  -- é o que impede alguém de fabricar um convite que promova.
  r := r || pg_temp.atira($q$
    insert into betonagens.codigo_registo
      (organizacao_id, codigo, perfil, criado_por, expira_em)
    values ((select valor from ctx where chave='org'), 'XXXX-XXXX-XXXX', 'EMPREITEIRO',
            (select valor from ctx where chave='fiscal'), now() + interval '1 day')
  $q$, '23514', 'P10 · não existe código de registo para EMPREITEIRO');

  -- ── registar-se com o código ──────────────────────────────────────────────
  -- Quem se regista ainda não tem utilizador de domínio, portanto não se usa
  -- pg_temp.actor: é preciso um JWT com sub E email, que é de onde a função
  -- tira o endereço. Aceitar o email por parâmetro deixaria alguém registar-se
  -- com o email de outra pessoa.

  perform set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-4000-8000-000000000010',
                      'email', 'novo.fiscal@teste.local')::text, true);
  perform set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000010', true);

  r := r || pg_temp.atira($q$
    select betonagens.registar_com_codigo('NAO-EXIS-TE00', 'Fiscal Novo')
  $q$, 'PT403', 'P11 · código inexistente é recusado');

  r := r || pg_temp.atira($q$
    select betonagens.registar_com_codigo(
      (select c.codigo from betonagens.codigo_registo c
        where c.id = (select valor from ctx where chave='codigo1')), 'Fiscal Novo')
  $q$, 'PT403', 'P12 · código revogado é recusado');

  r := r || pg_temp.corre($q$
    insert into ctx select 'fiscal_novo', u.id from betonagens.registar_com_codigo(
      (select c.codigo from betonagens.codigo_registo c
        where c.id = (select valor from ctx where chave='codigo2')), 'Fiscal Novo') u
  $q$, 'P13 · registo com o código em vigor é aceite');

  r := r || pg_temp.vale($q$
    select u.perfil::text || '|' || u.email from betonagens.utilizador u
     where u.id = (select valor from ctx where chave='fiscal_novo') $q$,
    'FISCALIZACAO|novo.fiscal@teste.local',
    'P14 · nasceu FISCALIZACAO, com o email lido do JWT e não de um parâmetro');

  r := r || pg_temp.atira($q$
    select betonagens.registar_com_codigo(
      (select c.codigo from betonagens.codigo_registo c
        where c.id = (select valor from ctx where chave='codigo2')), 'Outra Vez')
  $q$, 'PT409', 'P15 · a mesma conta não se regista duas vezes');

  perform pg_temp.actor(k_admin);

  -- ══════════════════════════════════════════════════════════════════════════
  -- Ledger · a cadeia tem de fechar
  -- ══════════════════════════════════════════════════════════════════════════

  r := r || pg_temp.vale($q$
    select count(*)::text from (
      select l.hash,
             sha256(convert_to(
               coalesce(encode(l.hash_anterior,'hex'),'') || '|' || l.seq::text || '|' ||
               l.entidade || '|' || l.entidade_id || '|' || l.acao || '|' ||
               l.dados::text || '|' || extract(epoch from l.momento)::text, 'UTF8')) as recalc
        from betonagens.ledger l) c
     where c.hash <> c.recalc $q$,
    '0', 'G01 · INV6 · todos os elos do ledger fecham quando recalculados');

  r := r || pg_temp.vale($q$
    select (count(*) > 0)::text from betonagens.ledger l
     where l.entidade = 'guia_remessa' and l.acao = 'INSERT' $q$,
    'true', 'G02 · D1 · o registo da guia passou pelo ledger');

  -- A cadeia tem de fechar em QUALQUER sessão, não só na que a escreveu. Aqui
  -- recalcula-se exactamente a mesma expressão, mudando apenas o fuso horário
  -- da sessão. Se falhar, a fórmula do encadeamento depende de uma definição
  -- de sessão, e INV6 acusaria adulteração onde não houve nenhuma.
  r := r || pg_temp.vale_com_fuso($q$
    select count(*)::text from (
      select l.hash,
             sha256(convert_to(
               coalesce(encode(l.hash_anterior,'hex'),'') || '|' || l.seq::text || '|' ||
               l.entidade || '|' || l.entidade_id || '|' || l.acao || '|' ||
               l.dados::text || '|' || extract(epoch from l.momento)::text,
               'UTF8')) as recalc
        from betonagens.ledger l) c
     where c.hash <> c.recalc $q$,
    '0', 'G03 · INV6 · a cadeia fecha em qualquer fuso horário de sessão',
    'America/New_York');

  -- fim: aborta a subtransação e desfaz tudo o que está acima
  raise exception 'FIM_DOS_TESTES';

  exception when others then
    if sqlerrm <> 'FIM_DOS_TESTES' then
      r := r || format('NAO OK  !! a suite abortou fora de um teste  ->  %s: %s', sqlstate, sqlerrm);
    end if;
  end;   -- <<<<<< aqui os dados de teste deixam de existir

  -- os resultados vivem numa variável, e variáveis de plpgsql não são
  -- transacionais: sobrevivem ao aborto acima
  insert into resultado_testes (n, estado, teste)
  select u.ord,
         case when u.linha like 'ok%'    then 'ok'
              when u.linha like '- - -%' then 'nota'
              else 'FALHA' end,
         u.linha
    from unnest(r) with ordinality as u(linha, ord);

  insert into resultado_testes (n, estado, teste)
  select 999999, 'RESUMO',
         format('%s verificações · %s ok · %s falhas · %s notas declaradas',
                (select count(*) from resultado_testes where estado <> 'nota'),
                (select count(*) from resultado_testes where estado = 'ok'),
                (select count(*) from resultado_testes where estado = 'FALHA'),
                (select count(*) from resultado_testes where estado = 'nota'));
end
$suite$;

select n, estado, teste from resultado_testes order by n;
