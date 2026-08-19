# Testes das brechas — como correr

## Pré-requisitos

Nenhum, além de acesso ao SQL Editor do projeto Supabase.

Sem pgTAP, sem extensões, sem CLI, sem Docker, sem `psql`. Verifiquei nesta
máquina: `psql` e `docker` não estão instalados, e o `supabase test db` do CLI
precisa dos dois. Por isso a suite foi escrita para correr onde já corres as
migrações.

## Comando

1. Supabase → **SQL Editor** → **New query**
2. Colar o conteúdo integral de `testes_brechas.sql`
3. **Run**

O resultado é uma tabela com uma linha por verificação e uma linha de resumo no
fim. Ordena-se por número, não por estado, para se poder ler como um percurso.

```
n    estado   teste
1    ok       E01 · esquema betonagens existe
...
999999 RESUMO  172 verificações · 172 ok · 0 falhas · 3 notas declaradas
```

`ok` passou · `FALHA` não passou · `nota` é uma omissão declarada, não uma falha.

A suite tem **172 verificações e 3 notas**. As notas não entram na contagem de
verificações porque não verificam nada: registam decisões, e estão explicadas
no fim deste documento.

## O que fica na base de dados

**Nada.** Todo o trabalho corre dentro de uma subtransação que é abortada de
propósito na última linha da suite. Isto não é uma comodidade: neste esquema
`DELETE` está revogado em todas as tabelas, portanto dados de teste que fossem
gravados **não se conseguiriam limpar depois**.

Os resultados sobrevivem ao aborto porque vivem numa variável de `plpgsql`, e as
variáveis de `plpgsql` não são transacionais. É o único truque do ficheiro e está
comentado no sítio onde acontece.

Podes correr a suite as vezes que quiseres, na mesma sessão ou em sessões
diferentes. Não deixa rasto e não precisa de limpeza.

## Resultado esperado, nos dois estados

### Base de dados vazia (migrações por aplicar)

**172 falhas e 3 notas.** Nenhuma verificação passa, e é a falha correta: cada
linha diz o que faltou.

- as verificações de estrutura devolvem `esperava [true], obteve [NULO]` ou
  `esperava [sem INSERT], obteve [tabela inexistente]`;
- as que esperam um erro concreto devolvem
  `esperava PT422, veio 42883: function betonagens.registar_guia(...) does not exist`
  — falhar com o erro errado conta como falha, e é isso que faz a suite valer;
- as fixtures falham primeiro e as restantes falham por arrasto, o que se lê
  bem porque a ordem é a do percurso.

As 3 notas aparecem na mesma, porque são texto fixo e não dependem do esquema.

Nenhuma verificação passa por acidente numa base vazia. Foi para isso que todas
as comparações são positivas (`= 'true'`, `= 'sem INSERT'`) em vez de negativas:
um `not exists` sobre uma tabela que não existe passaria pela razão errada.

### Migrações 0001 a 0022 aplicadas

**172 ok, 0 falhas, 3 notas.**

Qualquer `FALHA` aqui é um desvio entre o que está no repositório e o que está
vivo na base de dados, e deve ser tratada como tal antes de se avançar.

> Nota histórica: na primeira escrita destes testes, quatro linhas — `C6.1`,
> `N14a`, `N14` e `G03` — falhavam por dois defeitos das migrações que a suite
> apanhou: a correção de um item depois da aprovação estava bloqueada pela
> mesma condição que devia deixá-la passar, e a cadeia do ledger dependia do
> fuso horário da sessão. Ambos corrigidos em `0006`, `0008` e `0009` antes de
> qualquer aplicação. Fica aqui registado porque foi a suite a encontrá-los, e
> é essa a razão de ela existir.

## Cobertura

### Secção A — brechas de camada

| Brecha | Verificações |
|---|---|
| **A1** validação só no cliente | `E07` sem INSERT para `authenticated` · `E11` sem INSERT para `service_role` · `A1.1` serviço recusa guia sem PAB · `A1.2` INSERT direto viola `NOT NULL` · `A1.3` `authenticated` nem chega a tentar |
| **A2** API mais permissiva que o UI | `E12` 11 parâmetros obrigatórios sem defeito · `A2.1` sem data/hora não assume `now()` · `A2.2` sem número · `A2.3` sem fotografia |
| **A3** máquina de estados contornável | `E08` sem UPDATE em `pab` · `E15` nenhuma política de escrita · `A3.1` UPDATE do estado recusado · `A3.2` transição fora do grafo · `A3.3` fechar betonagem por aprovar |
| **A4** regra só num caminho | `E13` e `E14` os dois caminhos usam o mesmo núcleo · `A4.1` e `A4.2` a correção obedece às mesmas regras |
| **A5** offline isento de regras | `A5.1` relógio adiantado recusado à chegada · `A5.2` reenvio não duplica · `A5.3` mesmo id com outro conteúdo é 409 · `A5.4` sequência repetida é 409 |

### Secção B — brechas de modelo de dados

| Brecha | Verificações |
|---|---|
| **B1** `pab_id` anulável | `E03` `NOT NULL` · `E04` chave estrangeira |
| **B2** PAB genérico | `B2.1` sem elemento · `B2.2` volume zero · `B2.3` INSERT direto viola a constraint |
| **B3** edição silenciosa | `E16` gatilho · `B3.1` UPDATE do volume recusado · `D02` a correção deixa dois registos, o original preservado · `D05` o valor original não mudou |
| **B4** apagar em vez de anular | `E09` sem DELETE · `E10` sem TRUNCATE · `E17` gatilho · `B4.1` a `B4.3` DELETE recusado · `B4.4` contagem não decresce |
| **B5** unicidade só por PAB | `E05` índice · `B5.1` mesma guia noutro PAB · `B5.2` mesma guia noutra obra |
| **B6** ficheiro reutilizado | `E06` índice · `B6.1` mesma fotografia é 409 · `B6.2` *nota: pHash fora de F1* |
| **B7** timestamp do cliente | `B7.1` o servidor grava o seu relógio · `B7.2` atraso >4 h é AVISO · `B7.3` atraso >24 h é CRÍTICO · `B7.4` *nota: divergência deliberada face aos 15 min do documento* |
| **B8** sequência não verificada | `B8.1` índice de suporte existe · `B8.2` *nota: deteção de saltos fora de F1* |

### Cenários novos desta sessão

| Cenário | Verificações |
|---|---|
| Correção com o mesmo número de guia | `D01` é aceite · `D03` só uma em vigor · `D04` a original aponta para a que a substituiu · `D06` reutiliza a fotografia sem a recarregar |
| Correção após assinatura | `N01` é permitida · `N02` gera exceção nominal · `N03` gera alerta · `N14` com PAB aprovado o alerta é CRÍTICO · `N15` o PAB não é desaprovado |
| Assinatura fora de vigor | `N04` deixa de estar em vigor por aritmética · `N05` trava a aprovação · `N06` reassinar sem motivo é recusado · `N07` a `N09` a reassinatura repõe o vigor e a anterior fica no registo |
| Regras de assinatura | `N11` secção incompleta · `N12` reinspeção sem NC · `N13` reinspeção legítima |
| R6 e exceções | `R6.1` bloqueio na frente · `R6.2` override justificado · `R6.3` fica registado · `C6.1` justificação repetida recusada |
| Alertas | `N16` "ok" não chega · `N17` decisão com motivo é aceite · `F19` regra sem limiar avisa em vez de calar |
| RLS | `L01` a `L06` isolamento por obra observado com o papel `authenticated` |
| Leitura da guia (0022) | `LG01` a leitura regista-se · `LG02` diz que modelo a fez · `LG03` é append-only · `LG04` isolada por obra · `LG04b` observá-la não troca quem escreve a seguir · `LG16` reenvio devolve o que lá está · `LG17` outro extraído é 409 · `LG18` só se lê fotografia de guia · `LG19` o extraído tem de ser objecto |
| Proveniência derivada | `LG05` leitura de outra fotografia é recusada · `LG06` e `LG07` os quatro campos ficam `LIDO` · `LG08` registo igual ao lido é conforme · `LG11` corrigir um campo não contamina os outros · `LG14` campo por ler não entra · `LG15` guia sem leitura não afirma proveniência |
| R9 · correcção sobre leitura ALTA | `LG09` o campo fica `CORRIGIDO` · `LG10` a guia desce a `COM_ALERTA` |
| R10 · a classe do papel manda | `LG12` classe lida divergente torna a guia `NAO_CONFORME` mesmo com a classe do PAB escrita · `LG13` o alerta conta que a divergência veio da leitura |
| Ledger | `G01` a cadeia fecha · `G02` a guia passou pelo ledger · `G03` a cadeia fecha em qualquer fuso |

## As 3 notas declaradas

Não são falhas nem omissões esquecidas: são decisões, postas onde alguém as vai
ler quando correr a suite.

**`B6.2` — comparação percetual de imagem (pHash).** A brecha B6 pede hash
exacto *e* comparação percetual, para apanhar a guia refotografada. O
`UNIQUE(sha256)` está feito e é verificado em `E06` e `B6.1`; o pHash ficou fora
de F1 por decisão. A nota existe para que a cobertura parcial de B6 seja visível
em vez de passar por completa.

**`B7.4` — divergência deliberada de limiar.** O documento de brechas diz que uma
divergência de relógio acima de 15 minutos é sinal de risco. A decisão desta fase
fixou 4 h para entrar na fila do fiscal e 24 h para risco elevado, e nunca recusa
por atraso. `B7.2` e `B7.3` verificam os valores decididos; a nota regista que o
documento diz outra coisa, para que a diferença seja uma escolha e não um
esquecimento.

**`B8.2` — deteção de saltos na sequência de guias.** O índice que a suporta
existe e é verificado em `B8.1`, mas a deteção em si é consolidação diária e
pertence à fase do índice de risco. Fora de F1.

## Como está construída

Três auxiliares em `pg_temp`, criados no início do ficheiro e desaparecidos com
a sessão:

- `atira(sql, sqlstate, nome)` — a operação **tem de** falhar com aquele código.
  Falhar com outro código dá `FALHA`, com o código que veio: é isso que impede
  um teste de passar por acidente numa base vazia.
- `corre(sql, nome)` — a operação tem de passar.
- `vale(sql, esperado, nome)` — a consulta tem de devolver aquele valor.

Mais `vale_como` e `atira_como`, que trocam o papel para `authenticated` com um
JWT concreto — a única forma de observar a RLS, que não se aplica ao dono das
tabelas — e `vale_com_fuso`, que muda o fuso horário da sessão.

Todos recebem SQL em texto. É deliberado: uma tabela que não existe dá `FALHA`
naquela linha em vez de rebentar a suite ao segundo teste.

Os blocos de exceção existem para **classificar** o erro e mostrá-lo na linha do
teste. Nenhum é silencioso: tudo o que apanham aparece no resultado.
