-- =============================================================================
-- 0007_rls.sql · Obrify Betão
--
-- Activa RLS em todas as tabelas e cria as políticas de LEITURA.
-- Depende de: 0006.
--
-- Não existe nenhuma política de INSERT, UPDATE ou DELETE, de propósito. Com a
-- RLS activa e sem política para um comando, o PostgreSQL recusa esse comando
-- mesmo que houvesse GRANT. Somado ao REVOKE de 0008 e aos gatilhos de 0006,
-- são três mecanismos distintos — privilégio, política e gatilho — e não uma
-- camada chamada três vezes.
--
-- Nota: FORCE ROW LEVEL SECURITY NÃO é usado. As funções SECURITY DEFINER
-- correm como betonagens_servico, que é dono das tabelas, e é precisamente a
-- isenção do dono que faz delas a camada de serviço. A autorização dessas
-- funções é explícita no corpo de cada uma.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0007_rls.sql') then
    raise exception 'A migração 0007_rls.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

alter table betonagens.organizacao            enable row level security;
alter table betonagens.utilizador             enable row level security;
alter table betonagens.utilizador_obra        enable row level security;
alter table betonagens.obra                   enable row level security;
alter table betonagens.frente                 enable row level security;
alter table betonagens.central_betonagem      enable row level security;
alter table betonagens.parametro              enable row level security;
alter table betonagens.ficheiro               enable row level security;
alter table betonagens.pab                    enable row level security;
alter table betonagens.sequencia_dispositivo  enable row level security;
alter table betonagens.guia_remessa           enable row level security;
alter table betonagens.modelo_impresso        enable row level security;
alter table betonagens.fcq_linha              enable row level security;
alter table betonagens.fcq                    enable row level security;
alter table betonagens.fcq_item               enable row level security;
alter table betonagens.fcq_seccao_assinatura  enable row level security;
alter table betonagens.fcq_versao             enable row level security;
alter table betonagens.alerta                 enable row level security;
alter table betonagens.excecao                enable row level security;
alter table betonagens.evento_saida           enable row level security;
alter table betonagens.ledger                 enable row level security;

-- ── âmbito da organização ───────────────────────────────────────────────────
-- O (select ...) é deliberado: sem ele a função seria chamada uma vez por
-- linha; assim é um InitPlan avaliado uma única vez por consulta.

create policy organizacao_leitura on betonagens.organizacao
  for select to authenticated
  using (id = (select betonagens_priv.organizacao_atual()));

create policy utilizador_leitura on betonagens.utilizador
  for select to authenticated
  using (organizacao_id = (select betonagens_priv.organizacao_atual()));

create policy utilizador_obra_leitura on betonagens.utilizador_obra
  for select to authenticated
  using (organizacao_id = (select betonagens_priv.organizacao_atual()));

create policy central_leitura on betonagens.central_betonagem
  for select to authenticated
  using (organizacao_id = (select betonagens_priv.organizacao_atual()));

create policy ledger_leitura on betonagens.ledger
  for select to authenticated
  using (organizacao_id = (select betonagens_priv.organizacao_atual()));

-- O valor por defeito da organização é visível a todos; um limiar específico de
-- uma obra só é visível a quem vê essa obra.
create policy parametro_leitura on betonagens.parametro
  for select to authenticated
  using (
    organizacao_id = (select betonagens_priv.organizacao_atual())
    and (obra_id is null or obra_id in (select betonagens_priv.obras_visiveis()))
  );

-- ── âmbito da obra ──────────────────────────────────────────────────────────
-- Um empreiteiro nunca vê dados de outra obra, mesmo com credenciais válidas e
-- chamadas directas à API.

create policy obra_leitura on betonagens.obra
  for select to authenticated
  using (id in (select betonagens_priv.obras_visiveis()));

create policy frente_leitura on betonagens.frente
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create policy ficheiro_leitura on betonagens.ficheiro
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create policy pab_leitura on betonagens.pab
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create policy guia_leitura on betonagens.guia_remessa
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create policy fcq_leitura on betonagens.fcq
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create policy fcq_item_leitura on betonagens.fcq_item
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create policy fcq_assinatura_leitura on betonagens.fcq_seccao_assinatura
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create policy fcq_versao_leitura on betonagens.fcq_versao
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create policy alerta_leitura on betonagens.alerta
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create policy excecao_leitura on betonagens.excecao
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

create policy evento_saida_leitura on betonagens.evento_saida
  for select to authenticated
  using (obra_id in (select betonagens_priv.obras_visiveis()));

-- ── dados de referência do impresso ─────────────────────────────────────────
-- Não têm conteúdo de obra: são o formulário e os seus 34 critérios.

create policy modelo_impresso_leitura on betonagens.modelo_impresso
  for select to authenticated
  using (true);

create policy fcq_linha_leitura on betonagens.fcq_linha
  for select to authenticated
  using (true);

-- ── sem política nenhuma, de propósito ──────────────────────────────────────
-- betonagens.migracao e betonagens.sequencia_dispositivo têm RLS activa e
-- nenhuma política: são invisíveis através da API. sequencia_dispositivo é um
-- artefacto anti-fraude cujo conteúdo já aparece na guia ou no item.

reset role;

insert into betonagens.migracao (ficheiro) values ('0007_rls.sql');
