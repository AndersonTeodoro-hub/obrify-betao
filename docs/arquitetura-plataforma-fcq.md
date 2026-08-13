# Plataforma de Controlo de Betonagens — PAB · GR · FCQ
## Arquitetura completa · v1.0

**Âmbito:** ~500 obras ativas · fiscalização DDN · impresso oficial I.CR.033 Rev. 9
**Documento irmão:** `spec-modulo-pab-gr-fcq.md` (modelo de dados detalhado e mapa de campos do impresso)

---

## 1. Dimensionamento — e porque é que ele muda as prioridades

Com 500 obras, ~70% ativas em simultâneo e 3 betonagens/semana por obra:

| Métrica | Valor |
|---|---|
| PAB por dia útil | ~210 |
| Guias de remessa por dia | ~1.050 |
| Pico de carregamento (70% em 6 h de manhã) | **2 guias/minuto** |
| FCQ por ano | ~52.500 |
| Linhas `fcq_item` por ano | ~1,8 M |
| Fotografias por ano | ~385 GB |

**Conclusão que condiciona todo o desenho:** 2 pedidos por minuto não é um problema de escala. Uma única instância aplicacional e um Postgres modesto aguentam isto com folga durante anos.

O problema real é outro, e é onde deve ir o esforço de engenharia:

1. **Rede má.** O carregamento acontece em obra, ao telemóvel, muitas vezes sem cobertura. Se falhar, volta-se ao papel — e perde-se tudo.
2. **Integridade dos dados.** 52.500 documentos/ano em que um erro tem custo elevado. Não há espaço para *"quase certo"*.
3. **Governação de 500 obras.** Onboarding, permissões, revisões de impressos, utilizadores que entram e saem.
4. **Tempo do fiscal.** Estimativa atual: ~140 h/dia de trabalho de fiscalização em toda a carteira. O objetivo é chegar a **~2%** disso, através de revisão por exceção (§8).

Não sobredimensionar para tráfego. Sobredimensionar para **resiliência offline, integridade e auditabilidade**.

---

## 2. Princípios de desenho

1. **O impresso é lei.** O I.CR.033 nunca é recriado. É preenchido por sobreposição, com verificação de hash. Ver §7.
2. **Nada se apaga.** Todo o histórico é *append-only*. Correções geram versões, não substituições.
3. **A cronologia é validada, não confiada.** O sistema recusa sequências de eventos impossíveis, em vez de assumir boa-fé.
4. **Revisão por exceção.** O fiscal vê o que está sinalizado e uma amostra aleatória. O resto passa sozinho.
5. **Offline por defeito.** A app funciona sem rede e sincroniza depois. O relógio do servidor é sempre a autoridade.
6. **Fricção mínima do lado certo.** Carregar uma guia tem de custar menos esforço do que contorná-lo.

---

## 3. Arquitetura de sistema

```
┌─────────────────────────────────────────────────────────────────┐
│  APLICAÇÕES                                                     │
│  App móvel (empreiteiro + fiscal, offline-first)                │
│  Portal web (fiscal, direção de qualidade, admin)               │
└───────────────────────────┬─────────────────────────────────────┘
                            │  API REST/JSON · sincronização por fila
┌───────────────────────────┴─────────────────────────────────────┐
│  SERVIÇOS DE DOMÍNIO                                            │
│  obras · pab · guias · fcq · alertas · utilizadores             │
│  ── toda a validação crítica vive aqui, nunca só no cliente ──  │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────┬───────────┴─────────┬───────────────────────────┐
│  TRABALHADORES ASSÍNCRONOS                                      │
│  ocr-guia · docgen · reconciliacao-central · risco · digest     │
└───────────────┬─────────────────────┬───────────────────────────┘
                │                     │
┌───────────────┴──────┐  ┌───────────┴──────────┐  ┌────────────┐
│ PostgreSQL           │  │ Object storage       │  │ Ledger de  │
│ dados de domínio     │  │ fotos, PDF, anexos   │  │ auditoria  │
│ particionado por ano │  │ imutável, versionado │  │ append-only│
└──────────────────────┘  └──────────────────────┘  └────────────┘
```

**Notas de implementação**

- **Postgres único** com *row-level security* por obra. Não fazer sharding nem base por obra — a 1,8 M linhas/ano, partições anuais em `fcq_item` e `guia_remessa` chegam durante uma década.
- **Object storage imutável** (S3 com *object lock*). Uma fotografia de guia carregada nunca pode ser substituída; uma correção é um novo objeto.
- **Filas** para OCR, geração de documento e reconciliação. Nada disto é síncrono ao carregamento — o empreiteiro não espera.
- **Ledger de auditoria** com encadeamento de hash: cada registo inclui o hash do anterior. Torna detetável qualquer adulteração retroativa da base de dados, incluindo por quem tenha acesso administrativo.

---

## 4. O problema central: ligar o PAB à guia de remessa

É aqui que a ferramenta ganha ou perde. A ligação tem de ser **automática por defeito e obrigatória sempre**.

### 4.1 Fluxo alvo — orçamento de 45 segundos, 4 toques e 1 fotografia

```
Camião chega à frente
   │
   ├─ 1. Abrir app  →  a app já sabe onde está (GPS) e que dia é
   │                   Mostra os PAB aprovados dessa frente para hoje.
   │                   Um só PAB ativo → já vem pré-selecionado.
   │
   ├─ 2. Fotografar a guia (câmara da app, não galeria)
   │
   ├─ 3. OCR preenche nº da guia, central, volume, classe, slump
   │
   ├─ 4. Confirmar
   │
   └─ Gravado localmente. Sincroniza quando houver rede.
```

**Sem PAB selecionado não existe ecrã de gravação.** Não é uma validação que se possa contornar — o botão não existe até haver PAB.

### 4.2 As três camadas de ligação, por ordem de preferência

| # | Mecanismo | Quando se aplica | Fiabilidade |
|---|---|---|---|
| **A** | **Integração com a central de betonagem** — a central envia os dados da guia por API/ficheiro no momento da expedição, já com o PAB indicado na encomenda | Centrais com sistema de dosagem integrável | **Máxima.** Elimina fotografia e OCR do caminho crítico |
| **B** | **Autosseleção por GPS + data** — a app propõe o PAB da frente onde o utilizador está | Caso normal | Alta. Um toque |
| **C** | **QR do PAB** — código gerado na aprovação, afixado na frente ou no impresso do PAB | Frentes múltiplas em simultâneo, GPS impreciso | Alta. Digitalização |

O mecanismo A é o objetivo estratégico: **a guia deixa de ser um documento que alguém carrega e passa a ser um dado que chega da origem.** Com isso, a fraude documental deixa de ser possível. Começar por B e C, negociar A com as centrais principais em paralelo (§12, F5).

### 4.3 Porque é que isto resolve o problema de hoje

Hoje a guia chega em papel, solta, e alguém tem de a associar mentalmente a um pedido feito dias antes. A associação acontece **depois**, por memória, e é aí que se perde. No fluxo acima a associação acontece **antes** — o PAB é a porta de entrada, não uma etiqueta posta a posteriori.

---

## 5. Modelo de dados — evolução para multi-obra

Entidades detalhadas em `spec-modulo-pab-gr-fcq.md`. Acrescentos exigidos pela escala:

### 5.1 Novas entidades

**`organizacao`** — DDN ENG, DDN G e futuras. Isolamento de dados no topo.

**`empresa_externa`** — empreiteiros e centrais de betonagem. Um empreiteiro trabalha em várias obras; o histórico de conformidade é dele, não da obra (alimenta o *risk score*, §8.2).

**`central_betonagem`** — id, empresa_id, designacao, prefixo_guias, integracao_api (bool). A unicidade do número de guia é **por central**, globalmente, não por obra.

**`geofence`** — obra_id, polígono, raio de tolerância. Base do controlo de localização.

**`modelo_impresso`** — codigo (`I.CR.033`), revisao, data_revisao, ficheiro, sha256, mapa_campos (jsonb), ativo_desde, ativo_ate. Ver §7.

**`fcq_versao`** — cada emissão de PDF gera uma versão, com o `modelo_impresso_id` fixado. Uma FCQ de 2026 regenera-se sempre com a Rev. 9, mesmo que exista Rev. 12 em 2029.

**`revisao_periodica`** — o registo das verificações do fiscal (§8).

### 5.2 Índices que importam à escala

```sql
UNIQUE (central_id, numero_guia)                    -- unicidade global da guia
UNIQUE (ficheiro_sha256) WHERE tipo='guia'          -- ficheiro reutilizado
INDEX  (obra_id, estado, data_prevista)             -- painéis do fiscal
INDEX  (pab_id)                            ON guia_remessa
INDEX  (fcq_id, seccao)                    ON fcq_item
INDEX  (obra_id, risco DESC) WHERE estado='PENDENTE_REVISAO'
PARTITION BY RANGE (created_at)            ON fcq_item, guia_remessa, log_auditoria
```

---

## 6. Anti-burla — catálogo de vetores e controlos

Esta secção existe porque a ferramenta só vale o que valer a sua resistência a quem tem incentivo para a contornar.

### 6.1 Princípio orientador

**Não é possível tornar a fraude impossível apenas com controlos do lado do cliente.** Quem controla o telemóvel controla a fotografia, o GPS e o relógio. Prometer o contrário seria vender uma ilusão cara.

O que é possível, e é o que esta arquitetura faz:
- tornar a fraude **mais trabalhosa** do que o procedimento correto;
- garantir que qualquer tentativa **deixa rasto** e fica atribuída a uma pessoa identificada;
- confrontar o que o empreiteiro declara com uma **fonte independente** — a central de betonagem. É o único controlo que não depende de confiar no dispositivo.

### 6.2 Catálogo

| # | Vetor | Como se faz | Controlo | O que o deteta |
|---|---|---|---|---|
| V1 | **Guia reutilizada** noutro PAB ou obra | Carregar a mesma foto duas vezes | `UNIQUE(central, numero_guia)` global + SHA-256 do ficheiro | Rejeição imediata |
| V2 | **Guia recortada/refotografada** para escapar ao hash | Nova foto do mesmo papel | *Perceptual hash* (pHash) com limiar de semelhança | Alerta crítico, mesmo com hash diferente |
| V3 | **Guia adulterada** (volume ou classe editados) | Edição de imagem | Captura só pela câmara da app (galeria bloqueada para a foto primária) · análise EXIF · reconciliação com a central | EXIF ausente ou com software de edição; divergência face à central |
| V4 | **Carregamento retroativo** com data manipulada | Carregar dias depois, declarando data antiga | Timestamp do **servidor** é o único válido. Janela: ≤4 h após a hora declarada | Fora da janela → justificação obrigatória + fila do fiscal |
| V5 | **PAB errado de propósito** para esconder excesso de betão | Imputar a outro elemento | R2 (classe) + R3 (volume) + geofence da frente | Alerta cruzado de volume e localização |
| V6 | **Betonar primeiro, pedir depois** | PAB submetido após a betonagem | Coerência cronológica obrigatória (§6.3) | Sequência recusada pelo sistema |
| V7 | **Fechar betonagem com guias em falta** | Declarar concluído com 3 de 6 guias | Volume acumulado vs. previsto + reconciliação com a central | Delta de volume; R6 bloqueia o PAB seguinte da frente |
| V8 | **Checklist preenchida em bloco no fim** | Ticar tudo à pressa no gabinete | Cada `fcq_item` guarda timestamp e GPS próprios. Secções pré-betonagem têm de estar assinadas **antes** da aprovação do PAB | Itens com timestamps agrupados fora de obra → *flag* de risco |
| V9 | **Conta partilhada** | Encarregado usa a conta do diretor | Contas nominais, sessão ligada ao dispositivo, um dispositivo ativo, troca exige reautenticação | Mudanças de dispositivo frequentes |
| V10 | **Alteração após emissão** | Editar a FCQ fechada | *Append-only* + ledger encadeado por hash + object lock | Qualquer alteração quebra a cadeia |
| V11 | **Foto de ecrã ou fotocópia** | Fotografar um monitor | Deteção de moiré/reflexo na análise de imagem + EXIF | Alerta de qualidade, envia para revisão |
| V12 | **Correção manual do OCR** para mascarar valores | Sobrepor o valor lido | Campo lido com confiança alta e depois editado fica marcado `corrigido_manualmente` e vai sempre para a fila | Visível ao fiscal, com o valor original preservado |

### 6.3 Coerência cronológica — a regra que apanha a maioria dos casos

O sistema recusa qualquer sequência que viole esta ordem:

```
assinatura secções pré-betonagem
        <  aprovação do PAB
        <  1.ª guia de remessa
        <  restantes guias
        <  fecho da betonagem
        <  secção pós-betonagem
        <  emissão da FCQ
```

Não é um alerta. É uma **recusa**. Grande parte da fraude prática não é sofisticada — é preencher tudo no fim. Esta regra torna isso impossível sem cumplicidade ativa de quem assina, e nesse caso a responsabilidade fica nominalmente atribuída.

### 6.4 A alavanca que faz o resto funcionar

Nenhum controlo técnico substitui uma consequência. **Ligar o fecho da FCQ ao auto de medição mensal:** betonagem sem FCQ fechada não entra a pagamento. É a única regra que garante que o empreiteiro carrega as guias no próprio dia, porque passa a ser do interesse dele.

Recomendação: prever esta ligação já na arquitetura (exportação de FCQ fechadas por período e por obra, para o processo de medição), mesmo que a decisão contratual seja tomada mais tarde.

---

## 7. Motor de documentos — desenhado para mais do que uma ficha

O I.CR.033 é a primeira de muitas fichas DDN. O motor não pode ser específico do betão armado.

### 7.1 Registo de modelos

Cada impresso é uma linha em `modelo_impresso`:

```
codigo        I.CR.033
revisao       9
ficheiro      s3://templates/I.CR.033_rev9.pdf   (imutável, object lock)
sha256        5d9e61151dfed28cc2f676277ca8571bff19f1d54619ed18fab8e0b7631cef8a
mapa_campos   { ... }   ← jsonb, o mapa gerado por análise geométrica
ativo_desde   2024-07-30
```

Adicionar uma ficha nova é **configuração**, não código: carregar o PDF, correr o extrator de geometria, rever o mapa, ativar.

### 7.2 Regras invioláveis do `docgen`

1. Carrega o modelo do registo; **verifica o SHA-256 e aborta se divergir**.
2. Escreve apenas nas coordenadas do `mapa_campos`. Nada mais.
3. **Proibido** redesenhar, converter, recriar em HTML/Word, ou alterar margens, fontes, logótipo, cabeçalho ou rodapé.
4. Uma FCQ regenera-se sempre com a revisão do modelo com que foi criada (`fcq_versao.modelo_impresso_id`).
5. O PDF emitido é selado: hash registado no ledger e carimbo temporal.

> **Para o agente de código:** este módulo não desenha nada. Carrega, escreve nas coordenadas, funde, grava. Propostas de gerar o formulário programaticamente devem ser recusadas.

### 7.3 Extrator de geometria

Ferramenta interna que, dado um PDF de impresso DDN, deteta caixas de verificação, linhas de preenchimento e âncoras de texto, e propõe o `mapa_campos` para revisão humana. Foi o que produziu o mapa do I.CR.033 (136 caixas, 34 critérios × 4 colunas). **Sempre com revisão humana antes de ativar** — a deteção automática acerta em quase tudo, e "quase" não chega para 52.500 documentos/ano.

---

## 8. Verificação periódica pelo fiscal

O requisito: um mecanismo **simples**, que reduza carga em vez de a acrescentar.

### 8.1 Princípio — revisão por exceção, não por volume

O fiscal não revê 210 betonagens por dia. Revê:
- **tudo o que estiver sinalizado** (~10-15% do volume);
- **uma amostra aleatória cega** do que passou limpo (5%, ajustável).

A amostra aleatória é o que impede o empreiteiro de aprender onde é que o sistema não olha. Se só se revisse o sinalizado, bastaria descobrir os limiares.

### 8.2 Índice de risco

Cada betonagem recebe uma pontuação 0-100, calculada pelo trabalhador `risco`:

| Sinal | Peso |
|---|---|
| Alerta crítico ativo (classe divergente, guia duplicada) | muito alto |
| Divergência face aos dados da central | muito alto |
| Carregamento fora da janela de 4 h | alto |
| GPS fora do geofence da obra | alto |
| Campo do OCR corrigido manualmente | médio |
| Desvio de volume acima da tolerância | médio |
| Confiança do OCR baixa | médio |
| Itens da checklist com timestamps agrupados fora de obra | médio |
| Histórico de não conformidades do empreiteiro (12 meses) | modulador |

A fila do fiscal é ordenada por risco. Ele começa sempre pelo topo e para quando quiser — o que fica por ver é sempre o menos arriscado.

### 8.3 Os quatro instrumentos

**1. Fila de exceções** — ecrã único, ordenado por risco. Cada item mostra a fotografia da guia ao lado dos dados extraídos e do que o PAB previa. Três ações: *validar*, *devolver com motivo*, *escalar*.

**2. Revisão em lote** — as FCQ limpas apresentam-se em lote, com os indicadores essenciais numa linha cada. O fiscal valida o lote com uma assinatura. **O ledger regista explicitamente que foi validação em lote** — é honesto sobre o que essa assinatura significa e protege o fiscal.

**3. Resumo semanal por obra** — uma página, automática, na segunda-feira: betonagens da semana, FCQ fechadas, pendentes, alertas por resolver, desvios de volume acumulados. Serve de registo de acompanhamento e de prova de supervisão.

**4. Painel de carteira** — as 500 obras numa grelha de semáforos para a direção de qualidade: obras com pendências antigas, empreiteiros com risco acima da média, obras sem atividade registada apesar de betonagens previstas. É aqui que se veem os problemas sistémicos, não obra a obra.

### 8.4 SLA e escalamento

| Situação | Prazo | Escalamento |
|---|---|---|
| Alerta crítico | 24 h | Diretor de qualidade |
| FCQ pendente de fecho | 5 dias úteis | Diretor de obra |
| Guia por carregar após betonagem | 48 h | Bloqueio do PAB seguinte na frente (R6) |

---

## 9. Offline e sincronização

O ponto que decide se a ferramenta é usada ou abandonada.

- **Escrita local primeiro.** Tudo o que o utilizador faz em obra grava no dispositivo e fica visível de imediato. A sincronização é assunto do sistema, não dele.
- **Fila persistente** com retentativas e retrocesso exponencial. Sobrevive a fecho da app e a reinício do telemóvel.
- **Fotografias em segundo plano**, comprimidas para ~1,5 MB, com o original preservado até confirmação de receção.
- **Relógio:** grava-se o timestamp do dispositivo *e* o do servidor no momento da receção. **O do servidor é o válido.** A divergência entre os dois é, por si só, um sinal de risco.
- **Conflitos:** não existem por construção — cada guia é um registo novo, imutável. Não há edição concorrente.
- **Indicador visível** de quantos registos estão por sincronizar. O utilizador tem de saber que ainda não chegou.

---

## 10. Segurança, contas e auditoria

- **Perfis:** empreiteiro (por obra) · fiscal (por carteira de obras) · diretor de qualidade (organização) · administrador. *Row-level security* no Postgres, não só na aplicação.
- **Contas nominais obrigatórias.** Sem contas partilhadas — a assinatura da FCQ não vale nada se não se souber quem assinou.
- **Autenticação em dois passos** para perfis de fiscalização e superiores.
- **Ledger encadeado por hash** com carimbo temporal periódico. Torna detetável a adulteração retroativa mesmo por quem tenha acesso à base de dados.
- **Retenção:** 10 anos para FCQ e guias, alinhado com a responsabilidade decenal da construção. Object storage com *lifecycle* para armazenamento frio a partir de 2 anos.
- **RGPD:** fotografias de obra podem captar pessoas. Definir base legal, prazo de conservação e procedimento de acesso.

---

## 11. Escala operacional

O que efetivamente custa a 500 obras:

**Onboarding.** Criar uma obra tem de custar minutos, não dias. Modelo de obra pré-configurado (frentes-tipo, categorias, perfis) + importação em massa a partir do sistema atual. Sem isto, a plataforma nunca chega às 500.

**Gestão de utilizadores.** Rotação alta nos empreiteiros. Convite por SMS/email com autoinscrição validada pelo diretor de obra, e desativação automática ao fim de X dias sem atividade.

**Revisão de impressos.** Quando sair a Rev. 10 do I.CR.033: carregar, extrair mapa, rever, ativar com data. As FCQ antigas continuam a regenerar-se na Rev. 9. Nenhuma migração de dados.

**Suporte.** Prever que o encarregado de obra não vai ler manuais. A app tem de ser autoexplicativa ou não é usada.

**Custos de infraestrutura.** A estes volumes, a infraestrutura é irrelevante face ao custo de desenvolvimento. O OCR (~30.000 guias/mês) é a única rubrica variável com peso — avaliar processamento próprio quando compensar.

---

## 12. Faseamento

| Fase | Âmbito | Critério de aceitação |
|---|---|---|
| **F1** | Obras, frentes, utilizadores, PAB, guias, estados, R1-R8, offline | É impossível gravar uma guia sem PAB por qualquer via (UI, API, BD) |
| **F2** | Checklist FCQ em obra, R9, gate de aprovação pré-betonagem | O fiscal preenche o I.CR.033 no telemóvel, em obra |
| **F3** | `docgen` + registo de modelos + emissão selada | O PDF emitido tem o conteúdo do modelo intacto; diferença visual só nas marcas |
| **F4** | OCR, índice de risco, fila de exceções, resumo semanal, painel de carteira | O fiscal toca em ≤15% das betonagens |
| **F5** | **Integração com centrais de betonagem** | Reconciliação automática; a guia chega da origem |
| **F6** | Provetes e ensaios; extensão a outros impressos I.CR | Adicionar uma ficha nova é configuração, não código |

**Piloto antes de escalar:** 3 a 5 obras, com empreiteiros de perfis diferentes, durante 8 a 12 semanas. Métricas de decisão: percentagem de guias carregadas no próprio dia, tempo médio por guia, taxa de alertas falsos, tempo de fiscalização por betonagem. Escalar só depois de a taxa de falsos alertas estar controlada — um sistema que grita sem razão é desligado mentalmente em duas semanas.

---

## 13. Riscos e decisões em aberto

| Risco | Mitigação |
|---|---|
| Empreiteiro resiste e volta ao papel | Fluxo de 45 s + ligação ao auto de medição (§6.4) |
| Falsos alertas afogam o fiscal | Limiares configuráveis por obra; calibração no piloto antes de escalar |
| OCR falha em guias amarrotadas ou molhadas | Confirmação humana sempre obrigatória; OCR reduz digitação, não substitui leitura |
| Centrais recusam integração | B e C funcionam sem elas; A é ganho incremental por central |
| Revisão de impresso quebra mapas | Hash + versionamento; a FCQ regenera-se sempre na revisão de origem |

**Decisões que dependem da DDN:**
1. Preenchimento a azul ou obrigatoriamente a preto?
2. Sequencial do «033 / n.º» — por obra ou global à organização?
3. O fecho da FCQ pode condicionar o auto de medição? *(É a decisão com maior impacto no sucesso da ferramenta.)*
4. Que centrais de betonagem concentram mais volume, para priorizar a integração da fase F5?
5. Assinatura: nome + data com validação na plataforma é aceite pelo sistema de qualidade, ou é exigida assinatura qualificada?
