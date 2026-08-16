-- =============================================================================
-- 0021_impressos_e_origem_gerado.sql · Obrify Betão
--
-- As duas coisas que faltam à base para o motor de documento poder existir:
-- um sítio para o impresso oficial viver, e uma origem para os ficheiros que
-- a plataforma gera.
--
-- ── O BALDE DOS IMPRESSOS ───────────────────────────────────────────────────
-- A 0010 semeou o modelo I.CR.033 com caminho_storage = 'templates/icr033_rev9.pdf'
-- e o sha256 do impresso oficial, mas o ficheiro nunca foi carregado — e o
-- balde nem existia. Verificado hoje contra o projecto:
--     GET /storage/v1/object/info/templates/icr033_rev9.pdf → NoSuchBucket
-- O motor não arranca sem isto: a primeira coisa que faz é carregar o impresso
-- e comparar o hash com o da 0010, e abortar se divergir.
--
-- Balde PRIVADO e sem escrita para ninguém, pela mesma razão do balde das
-- guias: o impresso é um documento controlado da DDN. Quem lê é qualquer
-- utilizador autenticado — o impresso em branco não tem nada de reservado e o
-- motor precisa dele — mas escrever só com a chave de serviço, fora da
-- aplicação. Trocar o impresso é um acto de gestão documental, não um botão.
--
-- ── A ORIGEM «GERADO» ───────────────────────────────────────────────────────
-- betonagens.ficheiro_origem tinha 'CAMARA' e 'GALERIA': as duas maneiras de
-- uma FOTOGRAFIA entrar. Um PDF que a plataforma produz não é nenhuma das
-- duas, e registar_ficheiro exige a origem. Sem este valor, a FCQ gerada não
-- se consegue registar.
--
-- ── PORQUE É QUE ISTO NÃO TRAZ A FUNÇÃO DE EMISSÃO ──────────────────────────
-- ALTER TYPE ... ADD VALUE acrescenta o valor, mas o PostgreSQL não permite
-- USÁ-LO na mesma transação em que foi acrescentado. Uma função que escrevesse
-- 'GERADO' aqui rebentaria ao ser criada — ou pior, só ao ser chamada.
-- A emissão em betonagens.fcq_versao vem numa migração à parte, depois desta
-- ter feito commit. A tabela já existe desde a 0004, com ficheiro_pdf_id,
-- sha256_pdf, dados e as regras D4 da reemissão.
--
-- ── DUAS QUEBRAS DE CONVENÇÃO, AS MESMAS DA 0018 ────────────────────────────
-- A parte do storage não corre sob `set role betonagens_servico` — esse papel
-- não é dono do esquema storage. E não se cria função nenhuma, portanto não há
-- revoke final.
--
-- Depende de: 0020.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao
              where ficheiro = '0021_impressos_e_origem_gerado.sql') then
    raise exception 'A migração 0021_impressos_e_origem_gerado.sql já foi aplicada.';
  end if;
end $$;

-- ── a origem dos ficheiros que a plataforma produz ──────────────────────────
-- Sem IF NOT EXISTS: se já lá estiver, quero saber.
alter type betonagens.ficheiro_origem add value 'GERADO';

-- ── o balde dos impressos oficiais ──────────────────────────────────────────
-- 5 MB chega e sobra para um impresso de uma página; o I.CR.033 tem 74 810
-- bytes. Só PDF: o que aqui entra é um documento controlado, não uma imagem.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('templates', 'templates', false, 5242880, array['application/pdf']);

-- Qualquer utilizador autenticado lê. O impresso em branco não tem nada de
-- reservado, e o motor tem de o poder carregar em nome de quem pede o
-- documento. O que não existe é política de escrita — nenhuma.
create policy templates_leitura on storage.objects
  for select
  to authenticated
  using (bucket_id = 'templates');

-- ── a prova de que ninguém escreve ──────────────────────────────────────────
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
     and pg_get_expr(coalesce(p.polqual, p.polwithcheck), p.polrelid) like '%templates%';

  if v_escrita <> 0 then
    raise exception
      'Há % políticas de escrita a mencionar o balde templates. O impresso não se troca pela aplicação.',
      v_escrita;
  end if;
end $$;

insert into betonagens.migracao (ficheiro)
values ('0021_impressos_e_origem_gerado.sql');
