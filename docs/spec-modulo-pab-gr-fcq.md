# Módulo PAB → GR → FCQ
## Especificação técnica fechada (para implementação em Claude Code)

**Versão:** 0.1 · **Estado:** fechada exceto §7 (mapeamento do modelo DDN, pendente do ficheiro)
**Contexto:** módulo da camada 2 da Obrify, mesmo padrão do PAM (pedido → aprovação → registo → documento oficial de 1 página).

---

## 1. Objetivo

Garantir que **nenhuma guia de remessa de betão entra no sistema sem estar vinculada a um PAB aprovado**, e que a FCQ é gerada automaticamente a partir dos dados já registados, no modelo oficial DDN, sem intervenção manual de formatação.

Problema que resolve: hoje as guias chegam soltas, sem rasto ao pedido que as originou, e a FCQ é montada à mão no fim.

---

## 2. Modelo de dados

Tipos: `uuid`, `text`, `int`, `dec(p,s)`, `date`, `timestamptz`, `bool`, `enum`, `file` (referência a blob storage).

### 2.1 `obra`
| Campo | Tipo | Notas |
|---|---|---|
| id | uuid PK | |
| codigo | text UNIQUE | ex.: `2602` |
| designacao | text | |
| dono_obra | text | |
| empreiteiro | text | |
| fiscalizacao | text | |
| tolerancia_volume_pct | dec(5,2) | default `10.00` |
| ativa | bool | |

### 2.2 `frente`
| Campo | Tipo | Notas |
|---|---|---|
| id | uuid PK | |
| obra_id | uuid FK → obra | |
| designacao | text | ex.: «Piso 0 – Núcleo A» |

> A frente é o que torna aplicável a regra de bloqueio R6. Se a obra não quiser este nível, cria-se uma frente única por defeito.

### 2.3 `utilizador`
| Campo | Tipo | Notas |
|---|---|---|
| id | uuid PK | |
| nome, email | text | |
| perfil | enum | `EMPREITEIRO` \| `FISCALIZACAO` \| `ADMIN` |
| obras[] | uuid[] | obras a que tem acesso |

### 2.4 `pab` — peça-mãe
| Campo | Tipo | Obrig. | Notas |
|---|---|---|---|
| id | uuid PK | | |
| obra_id | uuid FK | ✔ | |
| frente_id | uuid FK | ✔ | |
| numero | int | ✔ | sequencial **por obra**, UNIQUE(obra_id, numero) |
| elemento | text | ✔ | campo «Peças a Betonar» |
| data_pedido | date | ✔ | |
| data_prevista | date | ✔ | |
| volume_previsto_m3 | dec(10,2) | ✔ | |
| classe_betao | text | ✔ | ex.: `C30/37` |
| classe_exposicao | text | | ex.: `XC4(P)` |
| dmax_agregado | int | | mm |
| classe_consistencia | text | | ex.: `S3` |
| estado | enum | ✔ | ver §3 |
| ficheiro_original | file | | impresso QAS.150.04 assinado |
| submetido_por | uuid FK | ✔ | |
| aprovado_por | uuid FK | | |
| data_aprovacao | timestamptz | | |
| motivo_rejeicao | text | | obrigatório se rejeitado |
| observacoes | text | | |

### 2.5 `guia_remessa`
| Campo | Tipo | Obrig. | Notas |
|---|---|---|---|
| id | uuid PK | | |
| **pab_id** | uuid FK → pab | ✔ **NOT NULL** | **a coluna que resolve o problema todo** |
| numero_guia | text | ✔ | UNIQUE(pab_id, numero_guia) |
| central | text | ✔ | central de betonagem |
| data_hora_betonagem | timestamptz | ✔ | data **real** |
| volume_m3 | dec(10,2) | ✔ | |
| classe_betao | text | ✔ | |
| slump_mm | int | | |
| ficheiro | file | ✔ | foto ou PDF da guia |
| registado_por | uuid FK | ✔ | |
| data_registo | timestamptz | ✔ | |
| ocr_confianca | dec(4,3) | | preenchido na fase 3 |
| conformidade | enum | ✔ | `CONFORME` \| `COM_ALERTA` \| `NAO_CONFORME` |

### 2.6 `provete` *(opcional — fase 4)*
`id`, `pab_id`, `guia_id?`, `identificacao`, `data_moldagem`, `idade_dias`, `resultado_mpa`, `laboratorio`.

### 2.7 `fcq` — 1:1 com PAB
| Campo | Tipo | Notas |
|---|---|---|
| id | uuid PK | |
| pab_id | uuid FK UNIQUE | relação 1:1 estrita |
| numero | text | ver §8, questão Q1 |
| data_emissao | date | |
| volume_total_m3 | dec(10,2) | soma das GR — calculado, não introduzido |
| desvio_volume_pct | dec(6,2) | calculado |
| data_real_betonagem | date | derivada da 1.ª GR |
| desvio_dias | int | real − prevista |
| conformidade | enum | `CONFORME` \| `CONFORME_COM_OBS` \| `NAO_CONFORME` |
| observacoes | text | |
| assinatura_empreiteiro | file/json | ver Q3 |
| assinatura_fiscalizacao | file/json | |
| ficheiro_xlsx | file | saída do motor |
| ficheiro_pdf | file | saída do motor |
| estado | enum | `RASCUNHO` \| `EMITIDA` |

### 2.8 `alerta`
`id`, `pab_id`, `guia_id?`, `tipo` (enum das regras R2–R5), `severidade` (`INFO`\|`AVISO`\|`CRITICO`), `mensagem`, `resolvido` bool, `resolvido_por`, `data_resolucao`.

### 2.9 `log_auditoria`
`id`, `entidade`, `entidade_id`, `acao`, `utilizador_id`, `timestamptz`, `valores_antes` jsonb, `valores_depois` jsonb.
Escrita obrigatória em **todas** as transições de estado e em qualquer alteração de GR ou FCQ.

---

## 3. Máquina de estados do PAB

```
SUBMETIDO ──aprovar──▶ APROVADO ──1.ª guia──▶ EM_BETONAGEM ──fechar──▶ BETONADO ──validar──▶ FCQ_FECHADA
    │                      │
    └──rejeitar──▶ REJEITADO
                           └──anular──▶ ANULADO
```

| Estado | Quem transita | Aceita guias? | Notas |
|---|---|---|---|
| `SUBMETIDO` | — | ✖ | aguarda validação da fiscalização |
| `APROVADO` | FISCALIZACAO | ✔ | aparece no dropdown do empreiteiro |
| `EM_BETONAGEM` | automático | ✔ | disparado ao gravar a 1.ª GR |
| `BETONADO` | EMPREITEIRO | ✖ | declaração de betonagem concluída |
| `FCQ_FECHADA` | FISCALIZACAO | ✖ | FCQ emitida; PAB e GR passam a **read-only** |
| `REJEITADO` | FISCALIZACAO | ✖ | exige `motivo_rejeicao` |
| `ANULADO` | FISCALIZACAO | ✖ | só a partir de `APROVADO` sem guias |

Transições fora deste grafo devem falhar ao nível do serviço, não só do UI.

---

## 4. Regras de negócio

| # | Regra | Comportamento |
|---|---|---|
| **R1** | Guia sem PAB | **Rejeição.** `pab_id NOT NULL` + FK na BD, validação no serviço e no formulário. Três camadas, sem exceções. |
| **R2** | `guia.classe_betao ≠ pab.classe_betao` | Guia gravada com `conformidade = NAO_CONFORME`, alerta `CRITICO`, notificação imediata à fiscalização. Não se apaga a guia — o desvio tem de ficar registado. |
| **R3** | `Σ volume_guias > volume_previsto × (1 + tolerancia_volume_pct)` | Alerta `AVISO` no ato do upload. Tolerância por obra, default 10%. |
| **R4** | Slump fora do intervalo da classe de consistência do PAB | Alerta `AVISO`. Tabela de intervalos (S1–S5) em configuração. |
| **R5** | `data_hora_betonagem` ≠ `data_prevista` | **Não bloqueia.** Grava `desvio_dias`, que sai na FCQ. |
| **R6** | Novo PAB na mesma frente | Bloqueado se existir na frente um PAB em `EM_BETONAGEM`, ou em `APROVADO` com `data_prevista` ultrapassada e zero guias. **Não bloqueia** por PAB em `BETONADO` à espera de FCQ — esse atraso é da fiscalização, não do empreiteiro. Fiscalização pode fazer override justificado (fica no log). |
| **R7** | Imutabilidade | Após `FCQ_FECHADA`, PAB e GR são read-only. Correção só por reabertura explícita da fiscalização, que gera nova versão da FCQ e mantém a anterior em arquivo. |
| **R8** | Fecho de betonagem | O empreiteiro só passa a `BETONADO` com ≥1 guia associada. |

---

## 5. Ecrãs

### 5.1 Perfil EMPREITEIRO
1. **Submeter PAB** — formulário com os campos de §2.4 + upload do impresso assinado.
2. **Carregar guia** — o ecrã central. Dropdown de PAB (filtrado a `APROVADO`/`EM_BETONAGEM` da frente do utilizador, com nº + elemento + volume já betonado / previsto), upload do ficheiro, campos da guia. **Sem PAB selecionado o botão de gravar está inativo.**
3. **Fechar betonagem** — resumo das guias associadas + confirmação.
4. **Os meus PAB** — lista com estado e nº de guias.

### 5.2 Perfil FISCALIZAÇÃO
1. **Aprovar/rejeitar PAB** — fila de `SUBMETIDO`.
2. **Painel de betonagens em curso** — PAB em `EM_BETONAGEM`, com volume acumulado vs. previsto e alertas por resolver em destaque.
3. **Validar e emitir FCQ** — pré-visualização dos dados compilados, campo de observações, conformidade, assinatura, botão *Emitir*.
4. **Registo geral** — a lista dos 124 PAB, mas viva: filtros por frente, estado, classe, período; exportação CSV.

---

## 6. Motor de documento (módulo isolado)

Módulo `docgen`, sem qualquer dependência do resto da aplicação. Interface única:

```
gerar_fcq(pab_id) -> { xlsx: file, pdf: file }
```

### Regras invioláveis
1. O template **nunca é gerado**. É carregado de `templates/FCQ_DDN_v1.xlsx`, em diretório read-only.
2. O módulo **só escreve nas células listadas em `MAPA_CAMPOS`** (§7). Qualquer outra célula é intocável.
3. **Proibido** criar/remover linhas, colunas ou folhas; alterar estilos, larguras, alturas, cabeçalhos, rodapés, logótipos, áreas de impressão ou definições de página.
4. No arranque, o módulo verifica o **SHA-256** do template contra o hash registado em configuração. Se não corresponder, **aborta com erro** — o template foi alterado e o mapeamento pode já não ser válido.
5. Se o template for revisto pela DDN: novo ficheiro `FCQ_DDN_v2.xlsx`, novo hash, novo mapeamento. **Nunca** se edita a versão em uso.
6. PDF gerado por `libreoffice --headless --convert-to pdf` a partir do XLSX preenchido, para garantir que o PDF é o próprio modelo.
7. Escrita com `openpyxl` em modo que preserve formatação (`keep_vba` se aplicável); nunca reconstruir o workbook.

### Instrução explícita para o agente de código
> Este módulo não desenha, não formata e não melhora nada. Abre o ficheiro, escreve valores nas células indicadas, grava e converte. Qualquer sugestão de "gerar o layout programaticamente" ou "recriar o modelo" está fora de âmbito e deve ser recusada.

### Bloco repetitivo das guias
O modelo tem um número finito de linhas para as guias (`N`, a apurar em §7). Comportamento:
- `n_guias ≤ N` → preenche as linhas disponíveis, deixa as restantes em branco.
- `n_guias > N` → gera **múltiplas cópias da folha** a partir do template original (uma por página), nunca inserindo linhas. Alternativa a decidir com a DDN: anexo em folha própria referenciado na FCQ.

---

## 7. Mapeamento de campos DDN — **PENDENTE**

A preencher assim que o modelo editável (XLSX) chegar.

| Campo lógico | Origem | Célula | Formato |
|---|---|---|---|
| Obra – código | `obra.codigo` | `?` | |
| Obra – designação | `obra.designacao` | `?` | |
| PAB nº | `pab.numero` | `?` | |
| Elemento / peças a betonar | `pab.elemento` | `?` | |
| Data prevista | `pab.data_prevista` | `?` | `dd/mm/aaaa` |
| Data real de betonagem | `fcq.data_real_betonagem` | `?` | `dd/mm/aaaa` |
| Classe de betão aprovada | `pab.classe_betao` | `?` | |
| Volume previsto (m³) | `pab.volume_previsto_m3` | `?` | 2 decimais |
| Volume total betonado (m³) | `fcq.volume_total_m3` | `?` | 2 decimais |
| Desvio de volume (%) | `fcq.desvio_volume_pct` | `?` | |
| Guia nº *(linha i)* | `guia[i].numero_guia` | `?` | bloco de N linhas |
| Guia – volume *(linha i)* | `guia[i].volume_m3` | `?` | |
| Guia – classe *(linha i)* | `guia[i].classe_betao` | `?` | |
| Guia – slump *(linha i)* | `guia[i].slump_mm` | `?` | |
| Guia – central *(linha i)* | `guia[i].central` | `?` | |
| Guia – data/hora *(linha i)* | `guia[i].data_hora_betonagem` | `?` | |
| Conformidade | `fcq.conformidade` | `?` | |
| Observações | `fcq.observacoes` | `?` | texto, sem quebra de layout |
| Assinatura empreiteiro | `fcq.assinatura_empreiteiro` | `?` | |
| Assinatura fiscalização | `fcq.assinatura_fiscalizacao` | `?` | |
| Data de emissão | `fcq.data_emissao` | `?` | |

---

## 8. Questões a fechar

- **Q1** — Numeração da FCQ: acompanha o nº do PAB (`FCQ-2602-047`) ou tem série própria?
- **Q2** — Máximo de linhas de guia no modelo DDN (`N` em §6).
- **Q3** — Assinaturas: imagem carregada, assinatura desenhada no ecrã, ou apenas nome + timestamp + hash de validação? Há exigência de assinatura qualificada?
- **Q4** — Provetes e ensaios entram na FCQ ou ficam em documento separado?
- **Q5** — Tolerância de volume: 10% serve para todas as obras ou varia por classe/elemento?
- **Q6** — Um PAB pode abranger mais do que um elemento/frente, ou é sempre 1:1?

---

## 9. Faseamento

| Fase | Âmbito | Critério de aceitação |
|---|---|---|
| **F1 – Núcleo** | Obra, frente, utilizadores, PAB, GR, máquina de estados, R1–R8, ecrãs §5 | É impossível gravar uma guia sem PAB, por qualquer via (UI, API, BD) |
| **F2 – Motor FCQ** | Módulo `docgen`, mapeamento §7, emissão XLSX+PDF | Documento emitido é byte-a-byte idêntico ao modelo exceto nas células mapeadas |
| **F3 – OCR** | Leitura automática da guia no upload (nº, volume, classe, slump), empreiteiro apenas confirma | Redução da fricção; confiança do OCR registada, confirmação humana sempre obrigatória |
| **F4 – Ensaios** | Provetes, resultados aos 7/28 dias, integração na FCQ | — |

---

## 10. Notas de implementação

- Toda a validação crítica (R1, R2, R6, transições de estado) vive na **camada de serviço**, com espelho na BD (constraints) e no UI. Validação só no formulário não é validação.
- Ficheiros (guias, impressos, FCQ) em blob storage com URL assinado e retenção definida; a BD guarda apenas a referência.
- Timestamps sempre `timestamptz`; apresentação em `Europe/Lisbon`.
- Uploads de guia a partir de telemóvel são o caso normal — o formulário tem de funcionar bem em ecrã pequeno, com câmara direta.
