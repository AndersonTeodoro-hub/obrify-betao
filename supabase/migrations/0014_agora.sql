-- =============================================================================
-- 0014_agora.sql · Obrify Betão
--
-- betonagens.agora() — o relógio do servidor, legível pelo cliente.
--
-- PORQUÊ. Todas as funções que recebem p_momento_declarado recusam com PT422
-- quando esse valor está à frente de now(). O relógio de um dispositivo não
-- coincide com o do servidor: medido nesta máquina, estava 339 ms adiantado, o
-- que bastou para a primeira submissão de PAB ser recusada. Em obra, com
-- telemóveis, a deriva vai ser maior e ninguém a vai acertar à mão.
--
-- O cliente não consegue ler o relógio do servidor por outra via. O cabeçalho
-- Date do HTTP existe em todas as respostas, mas NÃO é um cabeçalho da lista
-- segura do CORS e o Supabase não o declara em Access-Control-Expose-Headers —
-- verificado em quatro endpoints, incluindo dois que devolvem 200. Do browser,
-- headers.get('date') devolve null.
--
-- Esta função resolve isso melhor do que o cabeçalho resolveria: devolve o
-- relógio da PRÓPRIA BASE DE DADOS, que é o que faz a verificação, com
-- resolução de microssegundo em vez do segundo truncado do cabeçalho.
--
-- Não é SECURITY DEFINER: não lê tabela nenhuma, portanto não há privilégio
-- para elevar. Segue as funções puras já existentes — distancia_m,
-- nome_impresso, identidade_externa, derivar_ano_civil, exigir_perfil.
--
-- Não precisa de revoke a PUBLIC: a 0013 pôs alter default privileges nos dois
-- schemas, portanto uma função nova criada por betonagens_servico já nasce sem
-- EXECUTE para PUBLIC. A verificação "nenhuma função é executável por anon"
-- confirma-o depois de aplicares.
--
-- Depende de: 0013.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0014_agora.sql') then
    raise exception 'A migração 0014_agora.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

create function betonagens.agora()
returns timestamptz
language sql
stable
set search_path = ''
as $fn$
  select now()
$fn$;

comment on function betonagens.agora() is
  'Relógio do servidor, para o cliente medir a sua própria deriva. now() é o instante de início da transação, que é o mesmo que as funções de serviço comparam com p_momento_declarado.';

reset role;

grant execute on function betonagens.agora() to authenticated;

insert into betonagens.migracao (ficheiro) values ('0014_agora.sql');
