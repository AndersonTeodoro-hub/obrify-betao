# Brechas conhecidas e testes de aceitação
## Critérios de fecho para o módulo PAB · GR · FCQ

**Como usar:** cada brecha tem uma regra de fecho e um teste. Nenhuma fase é dada como concluída sem os testes da sua secção a passar. Estes testes vão para a suite automática, não para uma folha de verificação manual.

---

## Regra geral

> **Uma exceção só é aceitável se custar alguma coisa e for visível.**

Toda a saída da via normal tem de cumprir, sem exceção, as quatro condições:

1. **Nominal** — fica registada a pessoa, nunca "o sistema" ou "o administrador".
2. **Justificada** — texto obrigatório, com mínimo de caracteres, e nunca reaproveitável de um registo anterior.
3. **Visível** — aparece no resumo semanal da obra e na fila do fiscal.
4. **Contada** — entra no índice de risco do empreiteiro e da obra.

Uma exceção que cumpra as quatro é um mecanismo saudável. Se falhar uma delas, é uma brecha.

---

## A. Brechas de camada — validação no sítio errado

| # | Brecha | Como aparece na prática | Regra de fecho | Teste de aceitação |
|---|---|---|---|---|
| A1 | **Validação só no cliente** | O botão está inativo na app, mas o endpoint aceita tudo | Toda a regra crítica em três camadas: UI, serviço e constraint de BD | `POST /guias` sem `pab_id` → 422. `INSERT` direto na BD → violação de FK/NOT NULL |
| A2 | **API mais permissiva que o UI** | A app envia sempre `data_hora`; o endpoint aceita ausente e assume `now()` | Nenhum campo obrigatório tem valor por defeito no servidor | Fuzzing do endpoint com todos os subconjuntos de campos → nenhum passa sem os obrigatórios |
| A3 | **Máquina de estados contornável** | Existe `PATCH /pab/{id}` que aceita `estado` | Estado só muda por endpoints de transição (`/aprovar`, `/fechar`) | `PATCH` com `estado` no corpo → 403 e campo ignorado. Transições fora do grafo → 409 |
| A4 | **Regra implementada só num caminho** | Validação no upload individual, mas não na importação em lote | Todos os caminhos de escrita passam pelo mesmo serviço de domínio | Importação em lote com guia sem PAB → rejeita a linha, não o lote inteiro, e regista |
| A5 | **Modo offline isento de regras** | Registos offline entram sem passar pelas validações ao sincronizar | Offline é **fila**, não isenção. A validação corre no servidor à chegada | Registo offline inválido → rejeitado na sincronização, devolvido ao dispositivo com motivo visível |

---

## B. Brechas de modelo de dados

| # | Brecha | Como aparece | Regra de fecho | Teste |
|---|---|---|---|---|
| B1 | **`pab_id` anulável "por agora"** | Nasce `NULL` "para não bloquear o piloto" e nunca mais deixa de ser | `NOT NULL` desde a primeira migração. Sem exceções de arranque | Migração que torne a coluna anulável → falha na revisão de esquema |
| B2 | **PAB genérico / "diversos"** | Cria-se um PAB de saco onde cabe tudo o que não se sabe imputar | Proibido por construção: PAB exige elemento, frente, volume e classe preenchidos | Tentativa de criar PAB sem elemento ou com volume 0 → 422 |
| B3 | **Edição silenciosa da guia** | `UPDATE guia_remessa SET volume = ...` | Tabela *append-only*. Correção cria registo novo com `substitui_id` | `UPDATE` na tabela → bloqueado por trigger. Correção → dois registos visíveis, o original preservado |
| B4 | **Apagar em vez de anular** | `DELETE` para "limpar enganos" | `DELETE` revogado ao utilizador da aplicação. Só anulação com motivo | `DELETE` → erro de permissão. Contagem de registos nunca decresce |
| B5 | **Unicidade da guia só por PAB** | A mesma guia serve dois PAB em obras diferentes | `UNIQUE(central_id, numero_guia)` global à organização | Mesma guia em obras diferentes → 409 com indicação do PAB que já a usa |
| B6 | **Ficheiro reutilizado** | A mesma fotografia carregada duas vezes | `UNIQUE(sha256)` + comparação percetual | Mesma foto → rejeição. Foto recortada da mesma guia → alerta crítico |
| B7 | **Timestamp do cliente aceite como verdade** | `data_registo` vem do telemóvel | Servidor grava o seu próprio timestamp; o do dispositivo é metadado | Pedido com timestamp adulterado → gravado o do servidor; divergência >15 min gera sinal de risco |
| B8 | **Sequência de guias não verificada** | Guias 118432 e 118441 da mesma central e dia, sem as do meio | Deteção de saltos na sequência por central e dia | Falha na sequência → alerta informativo na fila (não bloqueia: pode haver outra obra) |

---

## C. Brechas de fluxo e interface

| # | Brecha | Como aparece | Regra de fecho | Teste |
|---|---|---|---|---|
| C1 | **Upload da galeria "por exceção"** | Aberto para o caso de a câmara falhar; passa a ser o caminho de todos | Câmara da app é o único caminho normal. Galeria só via fluxo de exceção nominal e justificado, marcado no registo e no PDF | Foto de galeria → registo marcado `origem=galeria`, entra sempre na fila do fiscal |
| C2 | **Duplicar FCQ anterior** | Funcionalidade "copiar da betonagem anterior" — cómoda e devastadora | Não existe. Cada FCQ nasce vazia | Nenhum endpoint aceita FCQ de origem como parâmetro |
| C3 | **Preencher a checklist toda com um toque** | Botão "marcar tudo conforme" | Não existe ao nível da ficha. No máximo por secção, e cada item guarda o seu timestamp e GPS | Itens marcados em bloco fora de obra → sinal de risco, visível ao fiscal |
| C4 | **Datar no futuro ou no passado** | Campo de data livre | Datas de inspeção não editáveis: são o momento do registo | Tentativa de definir data de inspeção → campo ignorado |
| C5 | **Alerta dispensável** | Botão "ignorar" no alerta | Alerta não se ignora: resolve-se com ação e motivo, ou fica aberto | Alerta crítico aberto → impede fecho da FCQ |
| C6 | **Justificação de texto livre aceite sem revisão** | Escreve-se "ok" e passa | Mínimo de caracteres, sem repetição da justificação anterior, e sempre encaminhada para a fila | Justificação com <20 caracteres ou igual à última do utilizador → 422 |
| C7 | **Confirmação automática do OCR** | O utilizador carrega em confirmar sem ler | Os campos críticos (nº da guia, volume, classe) exigem interação explícita; valor corrigido fica marcado com o valor original preservado | Campo alterado após leitura de alta confiança → marcado `corrigido_manualmente`, vai para a fila |

---

## D. Brechas de permissões e exceções

| # | Brecha | Como aparece | Regra de fecho | Teste |
|---|---|---|---|---|
| D1 | **Administrador faz tudo sem rasto** | Perfil técnico com acesso direto para "resolver problemas" | Não existe perfil que escreva fora do ledger. Intervenções de suporte são nominais, justificadas e aparecem no resumo da obra | Escrita por perfil admin sem justificação → recusada. Toda a escrita admin surge no digest semanal |
| D2 | **Fiscal cria a guia pelo empreiteiro** | Necessário às vezes; se for silencioso, anula o rasto | Permitido, mas marcado `registado_por_fiscalizacao` e visível no PDF e no digest | Guia criada por fiscal → campo preenchido, não removível |
| D3 | **Limiares alterados por quem é avaliado** | Tolerância de volume subida para 30% na véspera | Limiares só editáveis pelo diretor de qualidade, com histórico versionado. A FCQ regista o limiar em vigor no momento | Alteração de limiar → nova versão com autor e data; FCQ antigas mantêm o limiar original |
| D4 | **Reabertura ilimitada** | Reabre-se, corrige-se, fecha-se, sem contagem | Reabertura é nominal, justificada, versionada e contada. A partir da segunda, escala para o diretor de qualidade | 2.ª reabertura da mesma FCQ → exige aprovação de nível superior |
| D5 | **Contas partilhadas na prática** | Toda a obra usa o login do encarregado | Sessão ligada ao dispositivo; um dispositivo ativo por conta; troca exige reautenticação | Segundo dispositivo → primeira sessão termina e o evento fica registado |
| D6 | **Contas de teste em produção** | "empreiteiro_teste" que ninguém desativou | Contas de teste tecnicamente impossíveis em produção; ambientes separados | Verificação no arranque: nenhuma conta marcada como teste no ambiente de produção |
| D7 | **Utilizador desativado mantém dados válidos** | Sai da empresa, as assinaturas dele continuam a passar | Desativação impede escrita mas preserva o histórico, que permanece válido e atribuído | Utilizador desativado → 403 em qualquer escrita; FCQ antigas mantêm a assinatura |

---

## E. Brechas organizacionais — as que não são de software

| # | Brecha | Como aparece | Regra de fecho |
|---|---|---|---|
| E1 | **Papel como recurso permanente** | "Hoje não havia rede, fez-se em papel" — e fica assim | O papel continua a existir para emergência real, mas cada uso é uma exceção nominal registada na plataforma em 24 h, e conta para o risco da obra. Sem registo, a betonagem fica em aberto |
| E2 | **Obras fora do sistema** | Obras antigas ou pequenas ficam de fora "por enquanto" | Regra de âmbito explícita e datada pela direção de qualidade. Uma obra fora do sistema é uma decisão registada, não um esquecimento |
| E3 | **Exceções de piloto que nunca terminam** | Regras relaxadas para arrancar, sem data de fim | Toda a exceção de arranque tem data de validade no código. Passada a data, a regra ativa-se sozinha |
| E4 | **Fecho da FCQ sem consequência** | Não pagar não depende da FCQ, logo ninguém tem pressa | Ligar o fecho da FCQ ao auto de medição. É a decisão de maior impacto e é contratual, não técnica |
| E5 | **Fiscal valida em lote sem olhar** | 40 FCQ aprovadas em dois minutos | A validação em lote é legítima e fica registada **como tal** no ledger. O que se mede é a percentagem de lote vs. individual por fiscal, e a amostragem aleatória cega mantém-se ativa sobre o lote |

---

## F. Invariantes — o que nunca pode ser verdade

Verificações contínuas em produção. Qualquer uma que falhe é incidente, não bug.

```
INV1  Não existe guia_remessa com pab_id nulo.
INV2  Não existem duas guias com o mesmo (central_id, numero_guia).
INV3  Não existem dois registos de ficheiro com o mesmo sha256 e tipo 'guia'.
INV4  Para toda a FCQ fechada: assinatura pré-betonagem < aprovação do PAB
      < 1.ª guia < fecho da betonagem < secção pós-betonagem < emissão.
INV5  Toda a FCQ emitida tem hash do modelo igual ao registado na sua versão.
INV6  Nenhum registo do ledger tem hash anterior que não corresponda ao seu antecessor.
INV7  A contagem de guias, FCQ e itens nunca decresce entre snapshots diários.
INV8  Nenhuma FCQ fechada tem alerta crítico por resolver.
INV9  Toda a exceção registada tem utilizador identificado e justificação com >20 caracteres.
```

Correr de hora a hora. Falha de invariante → alerta ao diretor de qualidade e bloqueio de emissão até esclarecimento.

---

## G. Verificação adversarial antes de cada lançamento

Antes de cada fase entrar em produção, alguém da equipa tenta **deliberadamente** contornar o sistema durante meio dia, com acesso à API e a um telemóvel com root. Documenta o que conseguiu.

Guião mínimo:
1. Gravar uma guia sem PAB, por qualquer via.
2. Usar a mesma guia em dois PAB.
3. Carregar uma guia de ontem como sendo de hoje.
4. Fechar uma betonagem com metade das guias.
5. Preencher a checklist inteira depois da betonagem.
6. Alterar uma FCQ já emitida.
7. Aprovar um PAB sem as secções pré-betonagem feitas.
8. Fazer tudo o acima a partir de um perfil de administrador.

Cada tentativa bem-sucedida é uma brecha por fechar, com teste correspondente adicionado a este documento. **Nenhuma fase entra em produção com uma tentativa por fechar.**
