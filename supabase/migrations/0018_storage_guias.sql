-- =============================================================================
-- 0018_storage_guias.sql · Obrify Betão
--
-- O balde onde vivem as fotografias das guias, e quem lhes pode chegar.
--
-- ── PORQUÊ PRIVADO E SEM ESCRITA PARA NINGUÉM ───────────────────────────────
-- A fotografia da guia é prova. O que lhe dá valor é o sha256 gravado em
-- betonagens.ficheiro, e o INV3 — a mesma fotografia não entra duas vezes — só
-- significa alguma coisa se esse hash tiver sido calculado sobre os bytes que
-- realmente ficaram guardados.
--
-- Se o cliente pudesse escrever no balde, podia carregar a fotografia A e
-- declarar o hash da B. Por isso não há política de INSERT, UPDATE nem DELETE:
-- nenhuma. O único escritor é a Edge Function carregar-guia, que corre com
-- service_role — que contorna a RLS — e que calcula o hash ela própria, sobre
-- os bytes que acabou de receber. A ausência de política não é esquecimento: é
-- a política.
--
-- ── O CAMINHO ───────────────────────────────────────────────────────────────
-- A chave do objecto dentro do balde é
--     {obra_id}/{sha256 em hexadecimal}.{extensão}
-- e betonagens.ficheiro.caminho_storage guarda o mesmo precedido do balde:
--     guias/{obra_id}/{sha256}.{extensão}
-- para quem lê a linha saber onde ir sem ter de saber a convenção.
--
-- O caminho ser derivado do conteúdo é o que torna o carregamento idempotente:
-- os mesmos bytes caem sempre no mesmo sítio, e o balde nunca acumula cópias.
-- A obra vem primeiro porque é por ela que a leitura é filtrada, abaixo.
--
-- ── QUEM LÊ ─────────────────────────────────────────────────────────────────
-- Quem vê a obra. A política extrai o obra_id da primeira pasta do caminho e
-- confronta-o com betonagens_priv.obras_visiveis(), que é o mesmo auxiliar que
-- a RLS do domínio usa — para não haver duas respostas diferentes à pergunta
-- «que obras é que este utilizador vê».
--
-- ── DUAS QUEBRAS DE CONVENÇÃO, DECLARADAS ───────────────────────────────────
-- 1. Esta migração NÃO corre sob `set role betonagens_servico`. Esse papel não
--    é dono do esquema storage e não pode criar lá políticas. Corre como
--    postgres. É a primeira migração que o faz.
-- 2. Não cria funções, portanto não termina com o revoke da convenção 0015.
--
-- Se o `create policy` for recusado por falta de privilégio sobre
-- storage.objects, para e diz — não contornar com o painel sem o registar aqui.
--
-- Depende de: 0017.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0018_storage_guias.sql') then
    raise exception 'A migração 0018_storage_guias.sql já foi aplicada.';
  end if;
end $$;

-- ── o balde ─────────────────────────────────────────────────────────────────
-- Sem `on conflict do nothing`: se já existir um balde com este nome, quero
-- saber, não quero que a migração finja que o criou.
--
-- O tecto de 10 MB e a lista de tipos são a primeira linha de defesa, do lado
-- do Storage. A Edge Function repete os dois antes de escrever seja o que for —
-- não por desconfiança, mas porque quem recusa mais cedo dá melhor mensagem.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('guias', 'guias', false, 10485760,
        array['image/jpeg','image/png','image/webp']);

-- ── quem lê ─────────────────────────────────────────────────────────────────
create policy guias_leitura_por_obra on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'guias'
    and (storage.foldername(name))[1]::uuid in (
      select betonagens_priv.obras_visiveis()
    )
  );

-- ── a prova de que ninguém escreve ──────────────────────────────────────────
-- Verifica o RESULTADO, não a intenção. Se alguém acrescentar uma política de
-- escrita a este balde por engano — pelo painel, numa migração futura — esta
-- asserção não a apanha (só corre uma vez), mas deixa escrito o que era
-- verdade no dia em que se aplicou.
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
     and pg_get_expr(coalesce(p.polqual, p.polwithcheck), p.polrelid) like '%guias%';

  if v_escrita <> 0 then
    raise exception
      'Há % políticas de escrita a mencionar o balde guias. O único escritor tem de ser a Edge Function.',
      v_escrita;
  end if;
end $$;

insert into betonagens.migracao (ficheiro) values ('0018_storage_guias.sql');
