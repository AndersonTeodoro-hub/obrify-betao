-- =============================================================================
-- 0002_organizacao_identidade.sql · Obrify Betão
--
-- Cria: organizacao, utilizador, obra, frente, utilizador_obra,
--       central_betonagem, parametro, e os auxiliares de identidade usados
--       pela RLS e pelo ledger.
-- Depende de: 0001.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0002_organizacao_identidade.sql') then
    raise exception 'A migração 0002_organizacao_identidade.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

-- ── organização ──────────────────────────────────────────────────────────────
create table betonagens.organizacao (
  id         uuid primary key default gen_random_uuid(),
  codigo     text not null unique,
  designacao text not null,
  ativa      boolean not null default true,
  criada_em  timestamptz not null default now()
);

-- ── utilizador ───────────────────────────────────────────────────────────────
-- auth_user_id é a ÚNICA referência ao Supabase Auth em todo o domínio. Trocar
-- por SSO mais tarde é mexer nesta coluna e em mais nada.
create table betonagens.utilizador (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid not null references betonagens.organizacao(id),
  auth_user_id   uuid unique,
  nome           text not null check (length(btrim(nome)) >= 3),
  email          text not null check (position('@' in email) > 1),
  perfil         betonagens.perfil_utilizador not null,
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  desativado_em  timestamptz,
  desativado_por uuid references betonagens.utilizador(id),
  constraint utilizador_email_unico unique (organizacao_id, email),
  constraint utilizador_id_organizacao unique (id, organizacao_id),
  constraint utilizador_desativacao_coerente check (ativo = (desativado_em is null)),
  constraint utilizador_desativacao_nominal check ((desativado_em is null) = (desativado_por is null))
);
create index utilizador_por_organizacao on betonagens.utilizador (organizacao_id);
create index utilizador_por_desativador on betonagens.utilizador (desativado_por);

comment on column betonagens.utilizador.ativo is
  'D7: desativado impede escrita mas preserva o histórico, que continua válido e atribuído.';

-- ── obra ─────────────────────────────────────────────────────────────────────
create table betonagens.obra (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid not null references betonagens.organizacao(id),
  codigo         text not null,
  designacao     text not null,
  dono_obra      text,
  empreiteiro    text,
  fiscalizacao   text,
  ativa          boolean not null default true,
  criada_em      timestamptz not null default now(),
  constraint obra_codigo_unico unique (organizacao_id, codigo),
  constraint obra_id_organizacao unique (id, organizacao_id)
);

-- ── frente ───────────────────────────────────────────────────────────────────
create table betonagens.frente (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid not null,
  obra_id        uuid not null,
  designacao     text not null,
  latitude       numeric(9,6) check (latitude between -90 and 90),
  longitude      numeric(9,6) check (longitude between -180 and 180),
  raio_m         integer check (raio_m > 0),
  ativa          boolean not null default true,
  criada_em      timestamptz not null default now(),
  constraint frente_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id),
  constraint frente_designacao_unica unique (obra_id, designacao),
  constraint frente_id_obra unique (id, obra_id),
  constraint frente_coordenadas_coerentes check ((latitude is null) = (longitude is null)),
  constraint frente_geofence_coerente check (raio_m is null or latitude is not null)
);
create index frente_por_obra on betonagens.frente (obra_id);

-- ── acesso do utilizador à obra (substitui o array utilizador.obras[]) ───────
create table betonagens.utilizador_obra (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid not null,
  utilizador_id  uuid not null,
  obra_id        uuid not null,
  atribuido_por  uuid not null references betonagens.utilizador(id),
  atribuido_em   timestamptz not null default now(),
  revogado_por   uuid references betonagens.utilizador(id),
  revogado_em    timestamptz,
  constraint utilizador_obra_utilizador_fk foreign key (utilizador_id, organizacao_id)
    references betonagens.utilizador (id, organizacao_id),
  constraint utilizador_obra_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id),
  constraint utilizador_obra_revogacao_nominal check ((revogado_em is null) = (revogado_por is null))
);
-- um acesso activo por par; revogar e voltar a atribuir cria linha nova
create unique index utilizador_obra_ativa
  on betonagens.utilizador_obra (utilizador_id, obra_id) where revogado_em is null;
-- índice que serve directamente a RLS
create index utilizador_obra_por_utilizador
  on betonagens.utilizador_obra (utilizador_id) include (obra_id) where revogado_em is null;
create index utilizador_obra_por_obra on betonagens.utilizador_obra (obra_id);
create index utilizador_obra_por_atribuidor on betonagens.utilizador_obra (atribuido_por);
create index utilizador_obra_por_revogador on betonagens.utilizador_obra (revogado_por);

-- ── central de betonagem ─────────────────────────────────────────────────────
-- A unicidade do número de guia é por central, global à organização (B5).
create table betonagens.central_betonagem (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid not null references betonagens.organizacao(id),
  designacao     text not null,
  prefixo_guias  text,
  ativa          boolean not null default true,
  criada_em      timestamptz not null default now(),
  constraint central_designacao_unica unique (organizacao_id, designacao),
  constraint central_id_organizacao unique (id, organizacao_id)
);

-- ── parâmetros versionados (D3) ──────────────────────────────────────────────
-- Nunca colunas da obra: um limiar tem autor, data, justificação e histórico, e
-- a FCQ regista o que estava em vigor no momento. Sem vigente_ate: o valor em
-- vigor num instante é a linha mais recente que já tenha começado, com
-- precedência da obra sobre o valor por defeito da organização.
create table betonagens.parametro (
  id                   uuid primary key default gen_random_uuid(),
  organizacao_id       uuid not null references betonagens.organizacao(id),
  obra_id              uuid,
  chave                text not null check (length(btrim(chave)) >= 3),
  valor_num            numeric,
  valor_txt            text,
  unidade              text,
  vigente_desde        timestamptz not null,
  definido_por         uuid not null references betonagens.utilizador(id),
  definido_em          timestamptz not null default now(),
  justificacao         text not null check (length(btrim(justificacao)) >= 20),
  normativo_confirmado boolean not null default false,
  fonte                text,
  constraint parametro_obra_fk foreign key (obra_id, organizacao_id)
    references betonagens.obra (id, organizacao_id),
  constraint parametro_valor_unico check (num_nonnulls(valor_num, valor_txt) = 1)
);
create unique index parametro_versao_unica on betonagens.parametro
  (organizacao_id,
   coalesce(obra_id, '00000000-0000-0000-0000-000000000000'::uuid),
   chave,
   vigente_desde);
create index parametro_procura on betonagens.parametro
  (organizacao_id, chave, vigente_desde desc);
create index parametro_por_definidor on betonagens.parametro (definido_por);

comment on column betonagens.parametro.normativo_confirmado is
  'false = marcador de posição, não verificado contra NP EN 206 / NP EN 13670 nem contra o caderno de encargos.';

-- =============================================================================
-- Auxiliares de identidade
--
-- Vivem em betonagens_priv (não exposto na API). São SECURITY DEFINER porque
-- têm de ler betonagens.utilizador sem passar pela RLS dessa mesma tabela — sem
-- isso a política de utilizador chamar-se-ia a si própria. Todas verificam a
-- identidade de quem chama a partir de identidade_externa(); nenhuma aceita um
-- id vindo de fora.
-- =============================================================================

-- O ÚNICO sítio de todo o domínio que sabe como a identidade chega. Trocar o
-- Supabase Auth por SSO mais tarde é mexer aqui e em mais nada.
--
-- Não chama auth.uid() de propósito, por duas razões. A primeira é de desenho:
-- essa função vive num schema que pertence a outro sistema, e o domínio não
-- deve nomeá-lo. A segunda é operacional: uma função SQL é validada no momento
-- em que é criada, com os privilégios de quem a cria — que aqui é
-- betonagens_servico, que não tem acesso ao schema auth e não o deve ter.
--
-- Ler o claim é exactamente o que o auth.uid() faz por dentro. O PostgREST só
-- define request.jwt.claims depois de verificar a assinatura do token, portanto
-- a confiança é a mesma. Sem sessão autenticada devolve nulo, e quem chama
-- recusa a escrita.
create function betonagens_priv.identidade_externa()
returns uuid
language sql
stable
set search_path = ''
as $fn$
  select nullif(
           coalesce(
             nullif(current_setting('request.jwt.claim.sub', true), ''),
             nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
           ), '')::uuid
$fn$;

create function betonagens_priv.utilizador_atual()
returns uuid
language sql
stable
security definer
set search_path = ''
as $fn$
  select u.id
    from betonagens.utilizador u
   where u.auth_user_id = (select betonagens_priv.identidade_externa())
     and u.ativo
$fn$;

create function betonagens_priv.organizacao_atual()
returns uuid
language sql
stable
security definer
set search_path = ''
as $fn$
  select u.organizacao_id
    from betonagens.utilizador u
   where u.auth_user_id = (select betonagens_priv.identidade_externa())
     and u.ativo
$fn$;

-- Conjunto de obras que o utilizador da sessão pode ler.
-- EMPREITEIRO e FISCALIZACAO: as que lhe foram atribuídas e não revogadas.
-- DIRETOR_QUALIDADE e ADMIN: todas as da sua organização.
create function betonagens_priv.obras_visiveis()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $fn$
  select uo.obra_id
    from betonagens.utilizador u
    join betonagens.utilizador_obra uo on uo.utilizador_id = u.id
   where u.auth_user_id = (select betonagens_priv.identidade_externa())
     and u.ativo
     and u.perfil in ('EMPREITEIRO','FISCALIZACAO')
     and uo.revogado_em is null
  union
  select o.id
    from betonagens.utilizador u
    join betonagens.obra o on o.organizacao_id = u.organizacao_id
   where u.auth_user_id = (select betonagens_priv.identidade_externa())
     and u.ativo
     and u.perfil in ('DIRETOR_QUALIDADE','ADMIN')
$fn$;

-- Devolve o utilizador da sessão ou recusa. Nenhuma escrita é anónima (D1).
create function betonagens_priv.exigir_actor()
returns betonagens.utilizador
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_u betonagens.utilizador;
begin
  select * into v_u
    from betonagens.utilizador u
   where u.auth_user_id = (select betonagens_priv.identidade_externa());

  if not found then
    raise exception
      'Não há utilizador de domínio associado a esta sessão. Nenhuma escrita é anónima.'
      using errcode = 'PT403';
  end if;

  if not v_u.ativo then
    raise exception
      'O utilizador % está desativado e não pode escrever. O histórico dele mantém-se válido.',
      v_u.nome
      using errcode = 'PT403';
  end if;

  return v_u;
end
$fn$;

create function betonagens_priv.exigir_perfil(
  p_actor  betonagens.utilizador,
  variadic p_perfis betonagens.perfil_utilizador[]
)
returns void
language plpgsql
immutable
set search_path = ''
as $fn$
begin
  if not (p_actor.perfil = any (p_perfis)) then
    raise exception
      'O perfil % não pode executar esta operação. Perfis aceites: %.',
      p_actor.perfil, array_to_string(p_perfis, ', ')
      using errcode = 'PT403';
  end if;
end
$fn$;

create function betonagens_priv.exigir_acesso_obra(
  p_actor   betonagens.utilizador,
  p_obra_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if p_actor.perfil in ('DIRETOR_QUALIDADE','ADMIN') then
    if not exists (
      select 1 from betonagens.obra o
       where o.id = p_obra_id and o.organizacao_id = p_actor.organizacao_id
    ) then
      raise exception 'A obra % não pertence à organização do utilizador.', p_obra_id
        using errcode = 'PT403';
    end if;
    return;
  end if;

  if not exists (
    select 1 from betonagens.utilizador_obra uo
     where uo.utilizador_id = p_actor.id
       and uo.obra_id = p_obra_id
       and uo.revogado_em is null
  ) then
    raise exception 'O utilizador % não tem acesso à obra %.', p_actor.nome, p_obra_id
      using errcode = 'PT403';
  end if;
end
$fn$;

-- Valor em vigor de um parâmetro num instante. Devolve a linha inteira porque
-- quem cria um alerta tem de guardar qual foi o limiar aplicado (D3).
create function betonagens_priv.parametro_em(
  p_organizacao_id uuid,
  p_obra_id        uuid,
  p_chave          text,
  p_momento        timestamptz
)
returns betonagens.parametro
language sql
stable
security definer
set search_path = ''
as $fn$
  select p.*
    from betonagens.parametro p
   where p.organizacao_id = p_organizacao_id
     and p.chave = p_chave
     and (p.obra_id = p_obra_id or p.obra_id is null)
     and p.vigente_desde <= p_momento
   order by (p.obra_id is not null) desc, p.vigente_desde desc
   limit 1
$fn$;

-- Haversine em SQL. Sem PostGIS: enquanto forem pontos e raios, não compensa a
-- dependência. Polígonos de geofence, se vierem, mudam esta decisão.
create function betonagens_priv.distancia_m(
  p_lat1 numeric, p_lon1 numeric, p_lat2 numeric, p_lon2 numeric
)
returns numeric
language sql
immutable
set search_path = ''
as $fn$
  select (2 * 6371000.0 * asin(sqrt(
            power(sin(radians((p_lat2 - p_lat1)::double precision) / 2), 2)
          + cos(radians(p_lat1::double precision)) * cos(radians(p_lat2::double precision))
          * power(sin(radians((p_lon2 - p_lon1)::double precision) / 2), 2)
         )))::numeric
$fn$;

-- D2 · abreviatura determinística para o bloco "Elaborado por" do impresso:
-- primeira inicial + último apelido. O nome completo fica sempre no registo.
-- A largura real do bloco (27,4 pt / 25,4 pt) é medida pelo motor de documento
-- com as métricas da fonte; se não couber, a emissão é recusada. Aqui não se
-- trunca nada.
create function betonagens_priv.nome_impresso(p_nome text)
returns text
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  v_partes text[] := regexp_split_to_array(btrim(p_nome), '\s+');
  v_n      integer := array_length(v_partes, 1);
begin
  if v_n is null or v_partes[1] = '' then
    raise exception 'Nome vazio: não é possível derivar a abreviatura para o impresso.'
      using errcode = 'PT422';
  end if;
  if v_n = 1 then
    return v_partes[1];
  end if;
  return upper(left(v_partes[1], 1)) || '. ' || v_partes[v_n];
end
$fn$;

reset role;

grant execute on function betonagens_priv.utilizador_atual()   to authenticated;
grant execute on function betonagens_priv.organizacao_atual()  to authenticated;
grant execute on function betonagens_priv.obras_visiveis()     to authenticated;

insert into betonagens.migracao (ficheiro) values ('0002_organizacao_identidade.sql');
