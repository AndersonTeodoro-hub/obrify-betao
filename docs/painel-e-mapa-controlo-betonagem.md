# Painel de controlo e Mapa de Controlo de Betonagem
## Especificação · v1.0

**Documentos irmãos:** `arquitetura-plataforma-fcq.md` · `spec-modulo-pab-gr-fcq.md` · `brechas-e-testes-de-aceitacao.md`
**Exemplo funcional:** `mapa-controlo-betonagem.xlsx` — estrutura completa com dados de demonstração e acumuladores em fórmula.

---

## 1. O volume acumulado não é um número

Pedir «o volume acumulado» parece uma pergunta só. São sete perguntas diferentes, e cada uma responde a um interlocutor distinto. Confundi-las é a origem da maior parte dos mapas de betonagem que não servem para nada.

| # | Acumulador | Responde a | Serve para |
|---|---|---|---|
| **A1** | Volume por **betonagem** (guias vs. previsto no PAB) | Fiscal, em tempo real | Detetar sobreconsumo enquanto o camião ainda está na obra |
| **A2** | Volume por **elemento/peça** | Diretor de obra | Confrontar com o mapa de quantidades do projeto |
| **A3** | Volume por **frente/piso** | Diretor de obra | Avanço físico real |
| **A4** | Volume por **obra** | Direção | Consumo global vs. orçamentado |
| **A5** | Volume por **classe de betão** | Qualidade | Base da conformidade e da amostragem |
| **A6** | Volume por **central/fornecedor** | Compras e qualidade | Reconciliação e conferência de faturação |
| **A7** | Volume por **lote de controlo** | Qualidade | **Determina quando é obrigatório moldar provetes** |

**A7 é o que transforma o mapa de registo em ferramenta.** Todos os outros dizem o que já aconteceu. Este diz o que tem de acontecer a seguir: quantos metros cúbicos daquela classe foram colocados desde a última amostra e quanto falta até a próxima ser exigível. Se o sistema avisar **antes** da betonagem seguinte, o provete é moldado. Se só souber depois, o lote fica sem representação e o problema é irreversível — não se volta atrás para amostrar betão que já endureceu.

**A1 é o mais subtil.** O sobreconsumo raramente é desperdício: em fundações costuma indicar perdas no terreno; em elementos verticais, deformação ou fuga de cofragem. É um indicador de qualidade disfarçado de indicador de custo, e por isso o desvio tem de ser lido pelo fiscal, não pelo departamento financeiro.

> **Regra de leitura:** o desvio de volume só é conclusivo com a betonagem fechada. Num PAB em curso, negativo é o estado normal. O painel tem de distinguir as duas situações ou gera alarme falso todos os dias — e alarme falso diário é a forma mais rápida de fazer com que ninguém olhe para o painel.

---

## 2. Parâmetros de controlo da betonagem

Tudo o que a plataforma acompanha por guia, e a origem de cada dado:

| Parâmetro | Origem | Controlo automático |
|---|---|---|
| Volume (m³) | Guia | Acumuladores A1-A7; tolerâncias de desvio |
| Classe de resistência | Guia vs. PAB | Divergência → alerta crítico |
| Classe de exposição | PAB | Coerência com o projeto |
| Dmáx do agregado | PAB / guia | Divergência → alerta |
| Classe de consistência / slump | Guia vs. PAB | Fora do intervalo → alerta |
| **Hora de amassadura → hora de descarga** | Guia | Excedido o limite → alerta crítico |
| Temperatura do betão | Medição em obra | Fora do intervalo → alerta |
| Central de betonagem | Guia | Reconciliação; unicidade do n.º de guia |
| N.º da guia | Guia | Unicidade global; deteção de saltos na sequência |
| Data e hora reais | Servidor | Coerência cronológica; desvio face ao previsto |
| Provetes moldados | Registo em obra | Cumprimento da amostragem (A7) |
| Resultados aos 7 e 28 dias | Laboratório | Conformidade face ao fck exigido |
| Condições atmosféricas | FCQ, secção Betonagem | Ligação à checklist I.CR.033 |

**O tempo entre amassadura e descarga** é o parâmetro mais esquecido e um dos mais consequentes. A guia traz a hora de carga; a plataforma regista a hora real de descarga. A diferença calcula-se sozinha e ninguém a tem de anotar — hoje, na prática, ninguém a anota.

> **A confirmar contra a NP EN 206, a NP EN 13670 e o caderno de encargos de cada obra:** limite de tempo carga-descarga, intervalos de temperatura, frequência de amostragem e definição de lote. No ficheiro de exemplo estão como parâmetros editáveis e marcados para confirmação — **não são valores normativos verificados**, são marcadores de posição.

---

## 3. O painel — quatro níveis

O mesmo dado visto a quatro distâncias. Cada nível responde a uma pergunta e só a essa.

### Nível 1 · Carteira (direção de qualidade) — «onde é que há problema?»
Grelha das 500 obras em semáforo. Ordenação por risco, não alfabética. Métricas: alertas críticos abertos, FCQ pendentes há mais de 5 dias, amostras em falta, desvio de volume acumulado, obras sem registo apesar de betonagens previstas. **O sinal mais importante é a ausência de atividade**, não os números vermelhos: uma obra que betona e não regista é mais grave do que uma obra com desvios registados.

### Nível 2 · Obra (fiscal) — «como está a minha obra?»
Volume acumulado por classe, por frente e por mês. Betonagens em curso com acumulado em tempo real. Lotes de controlo com a amostragem em dia ou em falta. Fila de exceções ordenada por risco. Ensaios a aguardar 28 dias.

### Nível 3 · Frente / elemento — «este elemento está fechado?»
Betonagens do elemento, volume acumulado vs. projeto, FCQ associadas, ensaios e conformidade. É a vista que serve para responder a uma reclamação ou a uma auditoria dois anos depois.

### Nível 4 · Betonagem em curso — «o que está a acontecer agora?»
A única vista em tempo real. Volume descarregado vs. previsto com barra de progresso, guias recebidas, tempo desde a primeira descarga, alertas do dia, provetes moldados. Atualiza a cada guia registada.

**Nível 4 é o que muda o comportamento.** Os outros três descrevem o passado. Este permite intervir enquanto ainda há betão para corrigir — e é por isso que tem de funcionar no telemóvel, em obra, com rede fraca.

---

## 4. O Mapa de Controlo de Betonagem

### 4.1 O que é
O registo consolidado e contínuo das betonagens de uma obra: para cada betonagem, o que foi pedido, o que foi entregue, por quem, com que características, com que provetes e com que resultados. É o documento que se apresenta em auditoria, em receção provisória ou em litígio.

Hoje é compilado à mão a partir de guias em papel, dias ou semanas depois. Na plataforma **não se compila — existe sempre**, porque cada guia registada já o atualiza. Gerar o mapa passa a ser exportar um estado, não construir um documento.

### 4.2 Estrutura — cinco folhas
Implementada no ficheiro de exemplo:

| Folha | Conteúdo | Chave |
|---|---|---|
| **Resumo** | Indicadores da obra e volume por classe | Tudo calculado, nada introduzido |
| **Betonagens** | Uma linha por PAB: previsto vs. real, desvio, n.º de guias, data real, estado da FCQ | Acumulador A1 |
| **Guias** | Uma linha por guia — o registo atómico. Volume acumulado no PAB e no lote, tempo carga-descarga, slump, temperatura, alertas | Acumuladores A1 e A7 |
| **Lotes de controlo** | Volume por lote, amostras moldadas vs. exigidas, défice | Acumulador A7 |
| **Ensaios** | Provetes, resultados aos 7 e 28 dias, conformidade face ao fck | Fecho da cadeia |
| **Parâmetros** | Limites e tolerâncias, editáveis, com origem documentada | Governação |

A folha **Guias** é a fonte única. Tudo o resto agrega a partir dela por `SUMIFS`. Nenhum valor é escrito duas vezes — é o que garante que o mapa nunca se contradiz a si próprio.

### 4.3 Como se gera

```
Consulta ao estado da obra
        │
        ├─ Renderização em ecrã (o painel)
        │
        ├─ Exportação XLSX — trabalho analítico, filtros, conferência com faturação
        │
        └─ Exportação PDF selada — auditoria, receção, entrega contratual
                 └─ hash registado no ledger + carimbo temporal
```

**Periodicidade:** contínuo em ecrã · exportação automática mensal por obra · exportação a pedido a qualquer momento.

**Selagem:** cada exportação em PDF gera hash registado no ledger. Duas exportações da mesma data com hash diferente denunciam alteração de dados históricos — o que não deve acontecer, dado que os registos são imutáveis.

> **Verificar antes de implementar:** se existir um impresso oficial DDN para o mapa de controlo de betonagem, aplica-se exatamente a mesma regra do I.CR.033 — o modelo é carregado e preenchido por sobreposição, com verificação de hash. Nunca recriado. O ficheiro de exemplo é uma estrutura de trabalho, não uma proposta de substituição de um impresso existente.

---

## 5. Alertas do painel

| Alerta | Condição | Severidade | Quando dispara |
|---|---|---|---|
| Classe divergente | Classe da guia ≠ classe do PAB | Crítico | No registo da guia |
| Tempo excedido | Carga → descarga acima do limite | Crítico | No registo da guia |
| Sobreconsumo | Acumulado > previsto × (1 + tolerância) | Aviso | Durante a betonagem |
| Volume em falta | Betonagem fechada com acumulado < previsto × (1 − tolerância) | Aviso | No fecho |
| Slump fora do intervalo | Face à classe de consistência do PAB | Aviso | No registo da guia |
| Temperatura fora do intervalo | Face aos limites da obra | Aviso | No registo da guia |
| **Amostra em falta** | Volume do lote desde a última amostra > limite | **Crítico** | **Antes da betonagem seguinte** |
| Salto na sequência de guias | Números não consecutivos na mesma central e dia | Informativo | Consolidação diária |
| Ensaio não conforme | fc aos 28 dias < fck exigido | Crítico | À receção do resultado |
| Betonagem sem registo | Betonagem prevista sem guias após 48 h | Aviso | Consolidação diária |

**A ordem de disparo importa mais do que a lista.** Os alertas que só servem para registar a história disparam na consolidação diária. Os que permitem corrigir disparam no ato. E o de amostragem tem de disparar *antes* — é o único que previne em vez de constatar.

---

## 6. Notas de implementação

- **Acumuladores calculados a pedido, não guardados.** A totais desta ordem de grandeza, um `SUM` sobre índice é instantâneo, e um contador guardado é uma oportunidade de dessincronização. Guardar só o que for provadamente lento, com recálculo periódico de verificação.
- **Vistas materializadas** para o painel de carteira (500 obras), atualizadas de 5 em 5 minutos. Nenhum painel precisa de ser mais recente do que isso, exceto o nível 4, que lê direto.
- **O nível 4 é tempo real; os outros não.** Não gastar esforço a tornar reativo o que ninguém vê mudar.
- **Definição de lote de controlo configurável por obra** — por classe e mês, por classe e elemento, ou por classe e volume fixo. Varia com o caderno de encargos e não pode estar em código.
- **Exportação XLSX com os mesmos acumuladores em fórmula**, não em valor. Quem recebe o mapa precisa de o poder auditar e refazer contas, e um ficheiro só com números é um ficheiro em que é preciso confiar cegamente.
