-- =============================================================================
-- verificar_esquema.sql · Obrify Betão
--
-- Consulta de leitura. Não altera nada. Corre no SQL Editor depois de aplicar
-- as migrações, e sempre que quiseres confirmar que o que está vivo na base de
-- dados é o que está no repositório.
--
-- Devolve uma linha por verificação, com as falhas em primeiro lugar.
-- ok = false é incidente. ok = null é uma verificação que não se faz por SQL e
-- diz porquê.
-- =============================================================================

with
tabelas as (
  select c.oid, c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'betonagens' and c.relkind = 'r'
),
append_only as (
  select unnest(array[
    'ficheiro','sequencia_dispositivo','parametro','excecao',
    'fcq_seccao_assinatura','fcq_versao','ledger',
    'guia_remessa','fcq_item','alerta','evento_saida','utilizador_obra'
  ]) as relname
),
estado as (
  select unnest(array[
    'organizacao','utilizador','obra','frente','central_betonagem',
    'pab','fcq','modelo_impresso','fcq_linha'
  ]) as relname
),
com_ledger as (
  select unnest(array[
    'organizacao','utilizador','obra','frente','utilizador_obra',
    'central_betonagem','parametro','ficheiro','pab','guia_remessa',
    'fcq','fcq_item','fcq_seccao_assinatura','fcq_versao','alerta','excecao'
  ]) as relname
),
-- Chaves estrangeiras deliberadamente sem índice próprio, com a razão. Como as
-- funções puras, a exceção fica à vista em vez de escondida dentro do critério.
fk_excecao(conname, razao) as (values
  ('fcq_item_linha_fk',
   'fcq_item lê-se sempre por fcq_id, que está indexado. Um índice de três colunas sobre 2,1 M linhas/ano para uma consulta rara não se paga.'),
  ('fcq_item_sequencia_fk',
   'A investigação por dispositivo faz-se em sequencia_dispositivo, que já guarda entidade e entidade_id. O índice do lado filho não serve nada.'),
  ('guia_sequencia_fk',
   'Mesma razão da anterior.'),
  ('guia_ficheiro_fk',
   'A deteção de ficheiro reutilizado é pelo sha256 em ficheiro. A leitura normal é guia para ficheiro, pela chave primária.'),
  ('guia_remessa_substituida_por_id_fkey',
   'guia_substituicao_unica é parcial com predicado "is not null", implicado por qualquer procura por igualdade: serve na íntegra.'),
  ('fcq_item_substituido_por_id_fkey',
   'Mesma razão: fcq_item_substituicao_unica é parcial com predicado "is not null".'),
  ('parametro_obra_fk',
   'Dezenas de linhas por organização. O acesso quente é parametro_procura, que lidera com organizacao_id.'),
  ('utilizador_obra_utilizador_fk',
   'Os dois índices são parciais com "revogado_em is null", que é exactamente o filtro de obras_visiveis(). O histórico com revogados é raro e a tabela é pequena.')
),
fk_sem_indice as (
  select r.relname as tabela, c.conname
    from pg_constraint c
    join pg_class r on r.oid = c.conrelid
    join pg_namespace n on n.oid = r.relnamespace
   where n.nspname = 'betonagens' and c.contype = 'f'
     and not exists (
       select 1 from pg_index i
        where i.indrelid = c.conrelid
          and i.indpred is null
          and i.indkey[0] = c.conkey[1])
),
-- O conjunto de migrações que este ficheiro conhece. Acrescentar uma migração
-- nova obriga a acrescentar aqui a linha correspondente — é intencional: um
-- verificador que não sabe o que devia estar aplicado não verifica nada.
migracao_esperada(ficheiro, ordem) as (values
  ('0001_base.sql',                       1),
  ('0002_organizacao_identidade.sql',     2),
  ('0003_ficheiro_pab_guia.sql',          3),
  ('0004_fcq.sql',                        4),
  ('0005_alertas_excecoes_eventos.sql',   5),
  ('0006_ledger_append_only.sql',         6),
  ('0007_rls.sql',                        7),
  ('0008_servico.sql',                    8),
  ('0009_invariantes.sql',                9),
  ('0010_seed_modelo_icr033.sql',        10),
  ('0011_indices_chave_estrangeira.sql', 11),
  ('0012_excecao_momento_monotono.sql',  12),
  ('0013_privilegios_betonagens_priv.sql', 13),
  ('0014_agora.sql',                       14),
  ('0015_omissoes_execute.sql',            15),
  ('0016_pab_modelo_ddn.sql',              16),
  ('0017_atualizar_obra.sql',              17)
),
-- O que TEM de estar concedido. Sem estas listas o verificador só sabe ver
-- privilégios a mais e é cego a revogações: uma retirada silenciosa só se
-- descobriria quando o frontend deixasse de funcionar em obra.
tabela_legivel(relname) as (values
  ('organizacao'),('utilizador'),('utilizador_obra'),('obra'),('frente'),
  ('central_betonagem'),('parametro'),('ficheiro'),('pab'),('guia_remessa'),
  ('modelo_impresso'),('fcq_linha'),('fcq'),('fcq_item'),
  ('fcq_seccao_assinatura'),('fcq_versao'),('alerta'),('excecao'),
  ('evento_saida'),('ledger'),('fcq_seccao_estado')
),
funcao_de_servico(proname) as (values
  ('anular_pab'),('aprovar_pab'),('assinar_seccao_fcq'),('atribuir_obra'),
  ('atualizar_obra'),
  ('corrigir_guia'),('corrigir_item_fcq'),('criar_central'),('criar_frente'),
  ('criar_obra'),('definir_parametro'),('desativar_utilizador'),
  ('fechar_betonagem'),('marcar_item_fcq'),('registar_ficheiro'),
  ('registar_guia'),('registar_utilizador'),('rejeitar_pab'),
  ('resolver_alerta'),('revogar_obra'),('submeter_pab')
),
-- as que a RLS e a vista fcq_seccao_estado executam em nome de quem consulta
funcao_auxiliar_rls(proname) as (values
  ('utilizador_atual'),('organizacao_atual'),('obras_visiveis'),('itens_hash')
),
-- Não são serviço de domínio nem auxiliares da RLS, mas o cliente tem de as
-- poder chamar. agora() devolve o relógio do servidor para o dispositivo medir
-- a sua deriva antes de declarar um momento.
funcao_utilitaria(proname) as (values
  ('agora')
),
migracao_em_falta as (
  select e.ficheiro
    from migracao_esperada e
   where not exists (select 1 from betonagens.migracao m where m.ficheiro = e.ficheiro)
),
migracao_a_mais as (
  select m.ficheiro
    from betonagens.migracao m
   where not exists (select 1 from migracao_esperada e where e.ficheiro = m.ficheiro)
),
-- A ordem só se julga quando o conjunto está completo: com uma migração em
-- falta as posições deslocam-se todas e o relatório encheria-se de ruído.
migracao_fora_de_ordem as (
  select a.ficheiro
    from (select m.ficheiro,
                 row_number() over (order by m.aplicada_em, m.ficheiro) as posicao
            from betonagens.migracao m) a
    join migracao_esperada e on e.ficheiro = a.ficheiro
   where a.posicao <> e.ordem
     and not exists (select 1 from migracao_em_falta)
     and not exists (select 1 from migracao_a_mais)
),
v(verificacao, ok, detalhe) as (

  -- ── migrações ─────────────────────────────────────────────────────────────
  select 'migrações aplicadas',
         not exists (select 1 from migracao_em_falta)
         and not exists (select 1 from migracao_a_mais)
         and not exists (select 1 from migracao_fora_de_ordem),
         coalesce(
           nullif(concat_ws(' · ',
             (select 'FALTAM: ' || string_agg(f.ficheiro, ', ' order by f.ficheiro)
                from migracao_em_falta f),
             (select 'A MAIS: ' || string_agg(f.ficheiro, ', ' order by f.ficheiro)
                from migracao_a_mais f),
             (select 'FORA DE ORDEM: ' || string_agg(f.ficheiro, ', ' order by f.ficheiro)
                from migracao_fora_de_ordem f)
           ), ''),
           (select count(*)::text || ' aplicadas, pela ordem certa: '
                   || string_agg(m.ficheiro, ', ' order by m.aplicada_em, m.ficheiro)
              from betonagens.migracao m))

  -- ── RLS ───────────────────────────────────────────────────────────────────
  union all
  select 'RLS activa em todas as tabelas',
         not exists (select 1 from tabelas t join pg_class c on c.oid = t.oid where not c.relrowsecurity),
         coalesce((select string_agg(t.relname, ', ')
                     from tabelas t join pg_class c on c.oid = t.oid
                    where not c.relrowsecurity),
                  'todas')

  union all
  select 'nenhuma política de escrita',
         not exists (
           select 1 from pg_policy p join tabelas t on t.oid = p.polrelid
            where p.polcmd <> 'r'),
         coalesce((select string_agg(p.polname, ', ')
                     from pg_policy p join tabelas t on t.oid = p.polrelid
                    where p.polcmd <> 'r'),
                  'só SELECT, como esperado')

  -- ── privilégios ───────────────────────────────────────────────────────────
  union all
  select 'authenticated não escreve tabelas',
         not exists (
           select 1 from tabelas t
            where has_table_privilege('authenticated', t.oid, 'INSERT')
               or has_table_privilege('authenticated', t.oid, 'UPDATE')
               or has_table_privilege('authenticated', t.oid, 'DELETE')),
         coalesce((select string_agg(t.relname, ', ') from tabelas t
                    where has_table_privilege('authenticated', t.oid, 'INSERT')
                       or has_table_privilege('authenticated', t.oid, 'UPDATE')
                       or has_table_privilege('authenticated', t.oid, 'DELETE')),
                  'nenhuma')

  union all
  select 'service_role não toca em tabelas',
         not exists (
           select 1 from tabelas t
            where has_table_privilege('service_role', t.oid, 'SELECT')
               or has_table_privilege('service_role', t.oid, 'INSERT')
               or has_table_privilege('service_role', t.oid, 'UPDATE')
               or has_table_privilege('service_role', t.oid, 'DELETE')),
         coalesce((select string_agg(t.relname, ', ') from tabelas t
                    where has_table_privilege('service_role', t.oid, 'SELECT')
                       or has_table_privilege('service_role', t.oid, 'INSERT')
                       or has_table_privilege('service_role', t.oid, 'UPDATE')
                       or has_table_privilege('service_role', t.oid, 'DELETE')),
                  'nenhuma; só EXECUTE nas funções de serviço')

  -- ── o positivo: quem TEM de poder ─────────────────────────────────────────
  -- As quatro linhas seguintes comparam nos dois sentidos, "a mais" e "em
  -- falta". Sem elas, uma revogação vinda do painel da Data API — ou de onde
  -- quer que seja — passava despercebida, porque tudo o que está acima só sabe
  -- ver privilégios a mais.

  union all
  select 'authenticated lê exactamente as tabelas de leitura',
         not exists (
           select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'betonagens' and c.relkind in ('r','v')
              and has_table_privilege('authenticated', c.oid, 'SELECT')
                  <> (c.relname in (select l.relname from tabela_legivel l))),
         coalesce((select string_agg(c.relname ||
                          case when has_table_privilege('authenticated', c.oid, 'SELECT')
                               then ' (A MAIS)' else ' (EM FALTA)' end, ', ')
                     from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'betonagens' and c.relkind in ('r','v')
                      and has_table_privilege('authenticated', c.oid, 'SELECT')
                          <> (c.relname in (select l.relname from tabela_legivel l))),
                  '21 legíveis; migracao e sequencia_dispositivo invisíveis')

  union all
  select 'authenticated executa exactamente as funções de serviço, auxiliares e utilitárias',
         not exists (
           select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('betonagens','betonagens_priv') and p.prokind = 'f'
              and has_function_privilege('authenticated', p.oid, 'EXECUTE')
                  <> (p.proname in (select f.proname from funcao_de_servico f)
                   or p.proname in (select f.proname from funcao_auxiliar_rls f)
                   or p.proname in (select f.proname from funcao_utilitaria f))),
         coalesce((select string_agg(n.nspname || '.' || p.proname ||
                          case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
                               then ' (A MAIS)' else ' (EM FALTA)' end, ', ')
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname in ('betonagens','betonagens_priv') and p.prokind = 'f'
                      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
                          <> (p.proname in (select f.proname from funcao_de_servico f)
                           or p.proname in (select f.proname from funcao_auxiliar_rls f)
                           or p.proname in (select f.proname from funcao_utilitaria f))),
                  '21 de serviço + 4 auxiliares + 1 utilitária')

  union all
  select 'service_role executa exactamente o que as Edge Functions chamam',
         not exists (
           select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('betonagens','betonagens_priv') and p.prokind = 'f'
              and has_function_privilege('service_role', p.oid, 'EXECUTE')
                  <> (p.proname in ('registar_guia','registar_ficheiro'))),
         coalesce((select string_agg(n.nspname || '.' || p.proname ||
                          case when has_function_privilege('service_role', p.oid, 'EXECUTE')
                               then ' (A MAIS)' else ' (EM FALTA)' end, ', ')
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname in ('betonagens','betonagens_priv') and p.prokind = 'f'
                      and has_function_privilege('service_role', p.oid, 'EXECUTE')
                          <> (p.proname in ('registar_guia','registar_ficheiro'))),
                  'registar_guia e registar_ficheiro, mais nenhuma')

  union all
  -- A peça central da defesa contra o EXECUTE a PUBLIC, e não uma verificação
  -- entre outras. As omissões de pg_default_acl não funcionam nesta base — ver
  -- o cabeçalho da 0015 —, portanto a garantia é convenção mais esta linha:
  -- toda a migração que cria funções termina com o revoke ao public, e se
  -- alguém esquecer, é aqui que aparece, com o nome da função.
  -- O anon herda tudo o que for concedido a PUBLIC, por isso testá-lo cobre os
  -- dois casos: a concessão explícita e a de fábrica.
  select 'nenhuma função é executável por anon',
         not exists (
           select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('betonagens','betonagens_priv') and p.prokind = 'f'
              and has_function_privilege('anon', p.oid, 'EXECUTE')),
         coalesce((select string_agg(n.nspname || '.' || p.proname, ', ')
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname in ('betonagens','betonagens_priv') and p.prokind = 'f'
                      and has_function_privilege('anon', p.oid, 'EXECUTE')),
                  'nenhuma')

  union all
  select 'anon não tem acesso nenhum',
         not exists (select 1 from tabelas t where has_table_privilege('anon', t.oid, 'SELECT'))
         and not has_schema_privilege('anon', 'betonagens', 'USAGE'),
         'a aplicação exige sessão autenticada'

  union all
  select 'objectos pertencem a betonagens_servico',
         not exists (
           select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname in ('betonagens','betonagens_priv')
              and c.relkind in ('r','v','S')
              and c.relowner <> 'betonagens_servico'::regrole),
         coalesce((select string_agg(c.relname, ', ')
                     from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname in ('betonagens','betonagens_priv')
                      and c.relkind in ('r','v','S')
                      and c.relowner <> 'betonagens_servico'::regrole),
                  'todos')

  -- ── camada de serviço ─────────────────────────────────────────────────────
  union all
  select 'todas as funções têm search_path vazio',
         not exists (
           select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('betonagens','betonagens_priv')
              and p.prokind = 'f'
              and not exists (
                select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) e
                 where e like 'search_path=%'
                   and btrim(split_part(e, '=', 2), '"') = '')),
         coalesce((select string_agg(p.proname, ', ')
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname in ('betonagens','betonagens_priv')
                      and p.prokind = 'f'
                      and not exists (
                select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) e
                 where e like 'search_path=%'
                   and btrim(split_part(e, '=', 2), '"') = '')),
                  'todas')

  union all
  -- exigir_perfil, distancia_m, nome_impresso, identidade_externa,
  -- derivar_ano_civil e agora são puras: não lêem tabela nenhuma — a quinta só
  -- mexe no tuplo que está a ser inserido e a última só devolve now() — por
  -- isso não são SECURITY DEFINER. A lista está aqui à vista em vez de se pôr
  -- SECURITY DEFINER onde não faz falta.
  select 'funções que acedem a tabelas são SECURITY DEFINER',
         not exists (
           select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('betonagens','betonagens_priv')
              and p.prokind = 'f'
              and not p.prosecdef
              and p.proname not in ('exigir_perfil','distancia_m','nome_impresso',
                                    'identidade_externa','derivar_ano_civil','agora')),
         coalesce((select string_agg(p.proname, ', ')
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname in ('betonagens','betonagens_priv')
                      and p.prokind = 'f'
                      and not p.prosecdef
                      and p.proname not in ('exigir_perfil','distancia_m','nome_impresso',
                                    'identidade_externa','derivar_ano_civil','agora')),
                  'todas')

  union all
  -- A irmã desta linha para tabelas existe desde a primeira escrita do
  -- verificador. Para funções nunca existiu, e foi essa ausência que tornou
  -- invisível, durante catorze migrações, a hipótese de haver SECURITY DEFINER
  -- a correr com um dono que não era o previsto. Não havia — mas não havia
  -- forma de o saber.
  select 'todas as funções pertencem a betonagens_servico',
         not exists (
           select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('betonagens','betonagens_priv') and p.prokind = 'f'
              and p.proowner <> 'betonagens_servico'::regrole),
         coalesce((select string_agg(n.nspname || '.' || p.proname ||
                          ' (dono: ' || p.proowner::regrole::text || ')', ', ')
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname in ('betonagens','betonagens_priv') and p.prokind = 'f'
                      and p.proowner <> 'betonagens_servico'::regrole),
                  -- Contado, não escrito à mão. O número que aqui estava foi
                  -- fixado quando eram 45 e ficou a dizer 45 enquanto as
                  -- migrações acrescentavam funções — dava a impressão de ser
                  -- prova quando era legenda. O universo é o mesmo do not
                  -- exists acima, para o número dizer respeito exactamente ao
                  -- que foi verificado.
                  (select count(*) || ' funções, todas do papel de serviço'
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname in ('betonagens','betonagens_priv')
                      and p.prokind = 'f'))

  union all
  select 'criar_organizacao não é executável por ninguém',
         not has_function_privilege('authenticated',
           'betonagens.criar_organizacao(text,text,text,text,uuid)', 'EXECUTE')
         and not has_function_privilege('service_role',
           'betonagens.criar_organizacao(text,text,text,text,uuid)', 'EXECUTE'),
         'é o arranque e corre no SQL Editor'

  union all
  select 'vista fcq_seccao_estado respeita a RLS',
         exists (
           select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'betonagens' and c.relname = 'fcq_seccao_estado'
              and c.reloptions @> array['security_invoker=true']),
         'sem security_invoker a vista passaria por cima da RLS'

  -- ── INV1 a INV3, estruturais ──────────────────────────────────────────────
  union all
  select 'INV1 · guia_remessa.pab_id é NOT NULL com FK',
         (select a.attnotnull from pg_attribute a
           where a.attrelid = 'betonagens.guia_remessa'::regclass and a.attname = 'pab_id')
         and exists (select 1 from pg_constraint c
                      where c.conrelid = 'betonagens.guia_remessa'::regclass
                        and c.conname = 'guia_pab_fk' and c.contype = 'f'),
         'B1 · uma migração que torne a coluna anulável faz esta linha ficar a false'

  union all
  select 'INV2 · índice único da guia por central e ano',
         to_regclass('betonagens.guia_unica_por_central') is not null,
         'B5 · a mesma guia nunca serve dois PAB'

  union all
  select 'INV3 · índice único do sha256 do ficheiro de guia',
         to_regclass('betonagens.ficheiro_guia_sha256_unico') is not null,
         'B6 · a mesma fotografia não entra duas vezes'

  -- ── gatilhos ──────────────────────────────────────────────────────────────
  union all
  select 'gatilho de imutabilidade nas tabelas append-only',
         not exists (
           select 1 from append_only a
            where not exists (
              select 1 from pg_trigger tg
                join pg_class c on c.oid = tg.tgrelid
                join pg_namespace n on n.oid = c.relnamespace
                join pg_proc p on p.oid = tg.tgfoid
               where n.nspname = 'betonagens' and c.relname = a.relname
                 and p.proname = 'impedir_alteracao' and not tg.tgisinternal)),
         coalesce((select string_agg(a.relname, ', ') from append_only a
                    where not exists (
                      select 1 from pg_trigger tg
                        join pg_class c on c.oid = tg.tgrelid
                        join pg_namespace n on n.oid = c.relnamespace
                        join pg_proc p on p.oid = tg.tgfoid
                       where n.nspname = 'betonagens' and c.relname = a.relname
                         and p.proname = 'impedir_alteracao' and not tg.tgisinternal)),
                  'todas')

  union all
  select 'DELETE revogado nas tabelas de estado',
         not exists (
           select 1 from estado e
            where not exists (
              select 1 from pg_trigger tg
                join pg_class c on c.oid = tg.tgrelid
                join pg_namespace n on n.oid = c.relnamespace
                join pg_proc p on p.oid = tg.tgfoid
               where n.nspname = 'betonagens' and c.relname = e.relname
                 and p.proname = 'impedir_remocao' and not tg.tgisinternal)),
         coalesce((select string_agg(e.relname, ', ') from estado e
                    where not exists (
                      select 1 from pg_trigger tg
                        join pg_class c on c.oid = tg.tgrelid
                        join pg_namespace n on n.oid = c.relnamespace
                        join pg_proc p on p.oid = tg.tgfoid
                       where n.nspname = 'betonagens' and c.relname = e.relname
                         and p.proname = 'impedir_remocao' and not tg.tgisinternal)),
                  'todas')

  union all
  select 'gatilho de ledger nas tabelas de domínio',
         not exists (
           select 1 from com_ledger cl
            where not exists (
              select 1 from pg_trigger tg
                join pg_class c on c.oid = tg.tgrelid
                join pg_namespace n on n.oid = c.relnamespace
                join pg_proc p on p.oid = tg.tgfoid
               where n.nspname = 'betonagens' and c.relname = cl.relname
                 and p.proname = 'registar_no_ledger' and not tg.tgisinternal)),
         coalesce((select string_agg(cl.relname, ', ') from com_ledger cl
                    where not exists (
                      select 1 from pg_trigger tg
                        join pg_class c on c.oid = tg.tgrelid
                        join pg_namespace n on n.oid = c.relnamespace
                        join pg_proc p on p.oid = tg.tgfoid
                       where n.nspname = 'betonagens' and c.relname = cl.relname
                         and p.proname = 'registar_no_ledger' and not tg.tgisinternal)),
                  'todas')

  -- ── índices ───────────────────────────────────────────────────────────────
  union all
  -- Critério: existe um índice NÃO-PARCIAL cuja primeira coluna é a primeira
  -- coluna da chave estrangeira. É o que prevê desempenho de junção. Exigir que
  -- um único índice cobrisse todas as colunas era estrito de mais: neste
  -- esquema quase todas as FK são compostas por causa do isolamento
  -- multi-tenant (§1.5), e os índices lideram com a coluna por que se consulta.
  select 'colunas de chave estrangeira indexadas',
         not exists (select 1 from fk_sem_indice f
                      where f.conname not in (select e.conname from fk_excecao e)),
         coalesce((select string_agg(f.tabela || '.' || f.conname, ', ')
                     from fk_sem_indice f
                    where f.conname not in (select e.conname from fk_excecao e)),
                  'todas')

  union all
  -- As exceções não desaparecem do relatório: ficam numa linha informativa, com
  -- a razão, e é preciso lê-las para lhes poder chamar exceções.
  select 'chaves estrangeiras sem índice, por decisão',
         null,
         (select string_agg(e.conname || ' — ' || e.razao, ' · ' order by e.conname)
            from fk_excecao e)

  union all
  -- E3 · uma exceção que já não é precisa é uma exceção que ninguém reviu.
  select 'nenhuma exceção de índice já desnecessária',
         not exists (select 1 from fk_excecao e
                      where e.conname not in (select f.conname from fk_sem_indice f)),
         coalesce((select string_agg(e.conname, ', ') from fk_excecao e
                    where e.conname not in (select f.conname from fk_sem_indice f)),
                  'nenhuma')

  -- ── modelo do impresso ────────────────────────────────────────────────────
  union all
  select 'modelo I.CR.033 Rev. 9 registado com o hash oficial',
         exists (
           select 1 from betonagens.modelo_impresso m
            where m.codigo = 'I.CR.033' and m.revisao = 9
              and encode(m.sha256, 'hex') =
                  '5d9e61151dfed28cc2f676277ca8571bff19f1d54619ed18fab8e0b7631cef8a'),
         'a identidade do modelo é o hash, não o nome do ficheiro'

  union all
  select '34 linhas derivadas do mapa de campos',
         (select count(*) from betonagens.fcq_linha f
           join betonagens.modelo_impresso m on m.id = f.modelo_impresso_id
          where m.codigo = 'I.CR.033' and m.revisao = 9) = 34,
         (select string_agg(x.seccao::text || '=' || x.n::text, ' ' order by x.seccao::text)
            from (select f.seccao, count(*) as n
                    from betonagens.fcq_linha f
                    join betonagens.modelo_impresso m on m.id = f.modelo_impresso_id
                   where m.codigo = 'I.CR.033' and m.revisao = 9
                   group by f.seccao) x)

  -- ── o que não se verifica por SQL ─────────────────────────────────────────
  union all
  select 'schema betonagens exposto na API',
         null,
         'Settings -> API -> Exposed schemas. Passo manual no painel do Supabase, não é SQL.'

  union all
  select 'schema betonagens_priv NÃO exposto na API',
         null,
         'Confirmar no mesmo sítio que betonagens_priv não consta da lista.'
)
select v.verificacao, v.ok, v.detalhe
  from v
 order by (v.ok is null), coalesce(v.ok, true), v.verificacao;
