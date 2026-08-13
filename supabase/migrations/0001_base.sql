-- =============================================================================
-- 0001_base.sql · Obrify Betão
--
-- Cria: papel de serviço, schemas, tabela de controlo de migrações, tipos enum.
-- Depende de: nada.
--
-- APLICAÇÃO: manual, no SQL Editor do Supabase, por ordem numérica.
--            NUNCA por `supabase db push`.
--
-- Nota sobre extensões: não é precisa nenhuma. sha256(bytea) existe no núcleo
-- do PostgreSQL desde a 11 e gen_random_uuid() desde a 13, o que evita depender
-- do schema onde a pgcrypto esteja instalada.
-- =============================================================================

do $$
begin
  if to_regclass('betonagens.migracao') is not null then
    raise exception 'A migração 0001_base.sql já foi aplicada nesta base de dados.';
  end if;
end $$;

-- ── papel dono de todo o domínio ─────────────────────────────────────────────
-- Sem LOGIN, sem superuser. As funções SECURITY DEFINER correm como ele: é isso
-- que lhes dá escrita e as isenta da RLS. Um erro numa função não sai daqui.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'betonagens_servico') then
    create role betonagens_servico nologin;
  end if;
  execute format('grant betonagens_servico to %I', current_user);
end $$;

create schema betonagens      authorization betonagens_servico;
create schema betonagens_priv authorization betonagens_servico;

comment on schema betonagens is
  'Domínio do controlo de betonagens. Tem de ser exposto em Settings -> API -> Exposed schemas.';
comment on schema betonagens_priv is
  'Auxiliares de RLS, ledger e invariantes. NÃO deve ser exposto na API.';

revoke all on schema betonagens      from public;
revoke all on schema betonagens_priv from public;
grant usage on schema betonagens      to authenticated, service_role;
grant usage on schema betonagens_priv to authenticated;

set role betonagens_servico;

create table betonagens.migracao (
  ficheiro     text primary key,
  aplicada_em  timestamptz not null default now(),
  aplicada_por text not null default current_user
);
comment on table betonagens.migracao is
  'Registo das migrações aplicadas. Cada ficheiro guarda-se aqui na última linha.';
alter table betonagens.migracao enable row level security;

-- ── tipos ────────────────────────────────────────────────────────────────────

create type betonagens.perfil_utilizador as enum
  ('EMPREITEIRO','FISCALIZACAO','DIRETOR_QUALIDADE','ADMIN');

create type betonagens.pab_estado as enum
  ('SUBMETIDO','APROVADO','EM_BETONAGEM','BETONADO','FCQ_FECHADA','REJEITADO','ANULADO');

create type betonagens.guia_conformidade as enum
  ('CONFORME','COM_ALERTA','NAO_CONFORME');

create type betonagens.fcq_estado as enum ('RASCUNHO','EMITIDA');

create type betonagens.fcq_conformidade as enum
  ('CONFORME','CONFORME_COM_OBS','NAO_CONFORME');

-- Os valores destes dois tipos são exactamente as chaves de mapa_campos.json.
-- O motor de documento indexa o mapa por eles; qualquer tradução pelo meio é
-- uma oportunidade de erro silencioso.
create type betonagens.fcq_seccao as enum
  ('implantacao','cofragem','armaduras','juntas','betonagem','pos_betonagem');

create type betonagens.fcq_coluna as enum ('insp','reinsp1','reinsp2','reinsp3');

create type betonagens.fcq_valor as enum ('C','NC','NA');

create type betonagens.ficheiro_tipo as enum
  ('GUIA','PAB_IMPRESSO','FCQ_PDF','FCQ_ANEXO');

create type betonagens.ficheiro_origem as enum ('CAMARA','GALERIA');

create type betonagens.alerta_severidade as enum ('INFO','AVISO','CRITICO');

create type betonagens.alerta_tipo as enum
  ('CLASSE_DIVERGENTE',        -- R2
   'VOLUME_EXCEDIDO',          -- R3
   'SLUMP_FORA',               -- R4
   'LIMIAR_NAO_CONFIGURADO',   -- regra por avaliar por falta de parâmetro: visível, nunca silenciosa
   'ATRASO_SINCRONIZACAO',     -- C5, janelas de 4 h e 24 h
   'ORIGEM_GALERIA',           -- C1
   'GPS_FORA_FRENTE',          -- sinal, não trava
   'CRONOLOGIA_DISPOSITIVO',   -- relógio do dispositivo recuou entre registos
   'OVERRIDE_R6',              -- R6 levantada pela fiscalização
   'CORRECAO_APOS_ASSINATURA');

create type betonagens.excecao_tipo as enum
  ('FOTO_GALERIA','OVERRIDE_R6','REGISTO_POR_FISCALIZACAO',
   'CORRECAO_APOS_ASSINATURA','REABERTURA_FCQ');

reset role;

insert into betonagens.migracao (ficheiro) values ('0001_base.sql');
