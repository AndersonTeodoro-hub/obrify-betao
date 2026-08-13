-- =============================================================================
-- 0010_seed_modelo_icr033.sql · Obrify Betão
--
-- Regista o modelo I.CR.033 Rev. 9 e deriva dele as 34 linhas da ficha.
-- Depende de: 0009.
--
-- O mapa_campos abaixo é o conteúdo integral de docs/mapa_campos.json, apenas
-- sem espaços em branco. É a fonte única: fcq_linha é derivada dele por SQL,
-- não transcrita à mão, para não haver duas versões da verdade.
--
-- O sha256 é o do impresso oficial e é o mesmo que o motor de documento
-- verifica no arranque. O nome do ficheiro é irrelevante — a identidade do
-- modelo é o hash. O PDF tem de ser colocado no Storage em
-- templates/icr033_rev9.pdf antes de F3.
-- =============================================================================

do $$
begin
  if exists (select 1 from betonagens.migracao where ficheiro = '0010_seed_modelo_icr033.sql') then
    raise exception 'A migração 0010_seed_modelo_icr033.sql já foi aplicada.';
  end if;
end $$;

set role betonagens_servico;

insert into betonagens.modelo_impresso
  (codigo, revisao, data_revisao, caminho_storage, sha256, mapa_campos, ativo_desde)
values (
  'I.CR.033',
  9,
  '2024-07-30',
  'templates/icr033_rev9.pdf',
  decode('5d9e61151dfed28cc2f676277ca8571bff19f1d54619ed18fab8e0b7631cef8a', 'hex'),
  $mapa${"documento":{"referencia":"I.CR.033","revisao":9,"data_revisao":"2024-07-30","paginas":1,"largura_pt":595.276,"altura_pt":841.89,"acroform":false,"sistema":"origem no canto superior esquerdo (y para baixo); converter para reportlab com y_rl = altura - y"},"cabecalho":{"n_obra":{"x":108.0,"x_max":132.0,"y_baseline":68.8},"designacao":{"x":162.0,"x_max":334.0,"y_baseline":68.8},"numero":{"x":423.0,"x_max":505.0,"y_baseline":56.0},"n_anexos":{"x":447.0,"x_max":505.0,"y_baseline":69.1},"local_inspecao":{"x":236.0,"x_max":505.0,"y_baseline":81.3}},"colunas_inspecao":{"insp":316.0,"reinsp1":343.0,"reinsp2":370.0,"reinsp3":397.0},"blocos_assinatura":{"x_por_coluna":{"insp":305.5,"reinsp1":334.6,"reinsp2":361.7,"reinsp3":388.8},"largura":{"insp":27.4,"reinsp":25.4},"blocos":[{"y_elaborado":116.2,"y_data":124.1,"seccao":"implantacao"},{"y_elaborado":158.4,"y_data":166.3,"seccao":"cofragem"},{"y_elaborado":247.2,"y_data":255.1,"seccao":"armaduras"},{"y_elaborado":427.7,"y_data":435.6,"seccao":"juntas"},{"y_elaborado":588.0,"y_data":595.9,"seccao":"betonagem"},{"y_elaborado":673.2,"y_data":681.1,"seccao":"pos_betonagem"}]},"observacoes":{"x":90.0,"x_max":505.0,"y_topo":762.0,"y_base":783.0},"linhas":[{"id":"L01","seccao":"implantacao","criterio":"Conforme definido em projeto","check":{"insp":{"x":320.2,"cy":136.32},"reinsp1":{"x":347.2,"cy":136.32},"reinsp2":{"x":374.2,"cy":136.32},"reinsp3":{"x":401.2,"cy":136.32}},"anotacao":{"x":416.4,"y_baseline":140.4,"largura":90}},{"id":"L02","seccao":"cofragem","criterio":"1 cm em relação ao definido em projeto","check":{"insp":{"x":320.2,"cy":178.44},"reinsp1":{"x":347.2,"cy":178.44},"reinsp2":{"x":374.2,"cy":178.44},"reinsp3":{"x":401.2,"cy":178.44}},"anotacao":{"x":416.4,"y_baseline":182.4,"largura":90}},{"id":"L03","seccao":"cofragem","criterio":"Devidamente escorada e travada, garantindo o desempeno e verticalidade de elementos verticais","check":{"insp":{"x":320.2,"cy":190.68},"reinsp1":{"x":347.2,"cy":190.68},"reinsp2":{"x":374.2,"cy":190.68},"reinsp3":{"x":401.2,"cy":190.68}},"anotacao":{"x":416.4,"y_baseline":194.64,"largura":90}},{"id":"L04","seccao":"cofragem","criterio":"Todos os elementos devem estar limpos e isentos de partículas soltas","check":{"insp":{"x":320.2,"cy":202.92},"reinsp1":{"x":347.2,"cy":202.92},"reinsp2":{"x":374.2,"cy":202.92},"reinsp3":{"x":401.2,"cy":202.92}},"anotacao":{"x":416.4,"y_baseline":206.88,"largura":90}},{"id":"L05","seccao":"cofragem","criterio":"Utilização de óleo descofrante","check":{"insp":{"x":320.2,"cy":213.0},"reinsp1":{"x":347.2,"cy":213.0},"reinsp2":{"x":374.2,"cy":213.0},"reinsp3":{"x":401.2,"cy":213.0}},"anotacao":{"x":416.4,"y_baseline":216.96,"largura":90}},{"id":"L06","seccao":"cofragem","criterio":"Não permitir fugas da calda de Betão","check":{"insp":{"x":320.2,"cy":223.2},"reinsp1":{"x":347.2,"cy":223.2},"reinsp2":{"x":374.2,"cy":223.2},"reinsp3":{"x":401.2,"cy":223.2}},"anotacao":{"x":416.4,"y_baseline":227.28,"largura":90}},{"id":"L07","seccao":"armaduras","criterio":"Geometria de acordo com o projeto","check":{"insp":{"x":320.2,"cy":267.24},"reinsp1":{"x":347.2,"cy":267.24},"reinsp2":{"x":374.2,"cy":267.24},"reinsp3":{"x":401.2,"cy":267.24}},"anotacao":{"x":416.4,"y_baseline":271.2,"largura":90}},{"id":"L08","seccao":"armaduras","criterio":"Diâmetros de acordo com o projeto","check":{"insp":{"x":320.2,"cy":277.32},"reinsp1":{"x":347.2,"cy":277.32},"reinsp2":{"x":374.2,"cy":277.32},"reinsp3":{"x":401.2,"cy":277.32}},"anotacao":{"x":416.4,"y_baseline":281.28,"largura":90}},{"id":"L09","seccao":"armaduras","criterio":"Classe de acordo com o projeto","check":{"insp":{"x":320.2,"cy":287.4},"reinsp1":{"x":347.2,"cy":287.4},"reinsp2":{"x":374.2,"cy":287.4},"reinsp3":{"x":401.2,"cy":287.4}},"anotacao":{"x":416.4,"y_baseline":291.36,"largura":90}},{"id":"L10","seccao":"armaduras","criterio":"Comprimentos de amarração de acordo com o projeto","check":{"insp":{"x":320.2,"cy":297.48},"reinsp1":{"x":347.2,"cy":297.48},"reinsp2":{"x":374.2,"cy":297.48},"reinsp3":{"x":401.2,"cy":297.48}},"anotacao":{"x":416.4,"y_baseline":301.44,"largura":90}},{"id":"L11","seccao":"armaduras","criterio":"Reforços de acordo com o projeto","check":{"insp":{"x":320.2,"cy":307.56},"reinsp1":{"x":347.2,"cy":307.56},"reinsp2":{"x":374.2,"cy":307.56},"reinsp3":{"x":401.2,"cy":307.56}},"anotacao":{"x":416.4,"y_baseline":311.52,"largura":90}},{"id":"L12","seccao":"armaduras","criterio":"Negativos de acordo com o projeto","check":{"insp":{"x":320.2,"cy":317.64},"reinsp1":{"x":347.2,"cy":317.64},"reinsp2":{"x":374.2,"cy":317.64},"reinsp3":{"x":401.2,"cy":317.64}},"anotacao":{"x":416.4,"y_baseline":321.6,"largura":90}},{"id":"L13","seccao":"armaduras","criterio":"Afastamentos de acordo com o projeto","check":{"insp":{"x":320.2,"cy":327.72},"reinsp1":{"x":347.2,"cy":327.72},"reinsp2":{"x":374.2,"cy":327.72},"reinsp3":{"x":401.2,"cy":327.72}},"anotacao":{"x":416.4,"y_baseline":331.68,"largura":90}},{"id":"L14","seccao":"armaduras","criterio":"Estribos/cintas de acordo com o projeto","check":{"insp":{"x":320.2,"cy":337.8},"reinsp1":{"x":347.2,"cy":337.8},"reinsp2":{"x":374.2,"cy":337.8},"reinsp3":{"x":401.2,"cy":337.8}},"anotacao":{"x":416.4,"y_baseline":341.76,"largura":90}},{"id":"L15","seccao":"armaduras","criterio":"Ausência de contaminação por óleo, gordura, tinta, ou outras substâncias prejudiciais","check":{"insp":{"x":320.2,"cy":350.52},"reinsp1":{"x":347.2,"cy":350.52},"reinsp2":{"x":374.2,"cy":350.52},"reinsp3":{"x":401.2,"cy":350.52}},"anotacao":{"x":416.4,"y_baseline":357.12,"largura":90}},{"id":"L16","seccao":"armaduras","criterio":"Confirmar que os varões de espera estão corretamente colocados","check":{"insp":{"x":320.2,"cy":363.24},"reinsp1":{"x":347.2,"cy":363.24},"reinsp2":{"x":374.2,"cy":363.24},"reinsp3":{"x":401.2,"cy":363.24}},"anotacao":{"x":416.4,"y_baseline":367.2,"largura":90}},{"id":"L17","seccao":"armaduras","criterio":"Aplicação de Betão de Limpeza de acordo com o Projeto de Execução","check":{"insp":{"x":320.2,"cy":373.32},"reinsp1":{"x":347.2,"cy":373.32},"reinsp2":{"x":374.2,"cy":373.32},"reinsp3":{"x":401.2,"cy":373.32}},"anotacao":{"x":416.4,"y_baseline":377.28,"largura":90}},{"id":"L18","seccao":"armaduras","criterio":"Em fundações, com ____cm de acordo com projeto de execução","check":{"insp":{"x":320.2,"cy":383.4},"reinsp1":{"x":347.2,"cy":383.4},"reinsp2":{"x":374.2,"cy":383.4},"reinsp3":{"x":401.2,"cy":383.4}},"anotacao":{"x":416.4,"y_baseline":387.36,"largura":90}},{"id":"L19","seccao":"armaduras","criterio":"Em elementos verticais e horizontais, com ____cm de acordo com o projeto de execução","check":{"insp":{"x":320.2,"cy":393.48},"reinsp1":{"x":347.2,"cy":393.48},"reinsp2":{"x":374.2,"cy":393.48},"reinsp3":{"x":401.2,"cy":393.48}},"anotacao":{"x":416.4,"y_baseline":397.44,"largura":90}},{"id":"L20","seccao":"armaduras","criterio":"projeto de execução Aplicação de fibras metálicas conforme projeto","check":{"insp":{"x":320.2,"cy":403.56},"reinsp1":{"x":347.2,"cy":403.56},"reinsp2":{"x":374.2,"cy":403.56},"reinsp3":{"x":401.2,"cy":403.56}},"anotacao":{"x":416.4,"y_baseline":407.52,"largura":90}},{"id":"L21","seccao":"juntas","criterio":"e Juntas localizadas e cortadas conforme indicado no projeto de Estruturas/Estabilidade","check":{"insp":{"x":320.2,"cy":451.08},"reinsp1":{"x":347.2,"cy":451.08},"reinsp2":{"x":374.2,"cy":451.08},"reinsp3":{"x":401.2,"cy":451.08}},"anotacao":{"x":416.4,"y_baseline":456.24,"largura":90}},{"id":"L22","seccao":"juntas","criterio":"Corte executado conforme projeto, sem fragilizar a armadura do elemento de betão","check":{"insp":{"x":320.2,"cy":465.24},"reinsp1":{"x":347.2,"cy":465.24},"reinsp2":{"x":374.2,"cy":465.24},"reinsp3":{"x":401.2,"cy":465.24}},"anotacao":{"x":416.4,"y_baseline":472.08,"largura":90}},{"id":"L23","seccao":"juntas","criterio":"Remoção de resíduos resultantes do corte executado","check":{"insp":{"x":320.2,"cy":478.2},"reinsp1":{"x":347.2,"cy":478.2},"reinsp2":{"x":374.2,"cy":478.2},"reinsp3":{"x":401.2,"cy":478.2}},"anotacao":{"x":416.4,"y_baseline":482.16,"largura":90}},{"id":"L24","seccao":"juntas","criterio":"Produto em conformidade com o projeto/material aprovado e aplicação conforme indicado pelo fornecedor","check":{"insp":{"x":320.2,"cy":490.68},"reinsp1":{"x":347.2,"cy":490.68},"reinsp2":{"x":374.2,"cy":490.68},"reinsp3":{"x":401.2,"cy":490.68}},"anotacao":{"x":416.4,"y_baseline":497.04,"largura":90}},{"id":"L25","seccao":"juntas","criterio":"Produto em conformidade com o projeto/material aprovado. O cordão deve possuir diâmetro igual à dimensão do corte e preencher todo o perímetro da junta de dilatação","check":{"insp":{"x":320.2,"cy":509.52},"reinsp1":{"x":347.2,"cy":509.52},"reinsp2":{"x":374.2,"cy":509.52},"reinsp3":{"x":401.2,"cy":509.52}},"anotacao":{"x":416.4,"y_baseline":519.84,"largura":90}},{"id":"L26","seccao":"juntas","criterio":"Material em conformidade com o aprovado na ficha de aprovação de material. A aplicação deve ser de acordo com o indicado pelo fornecedor e preencher totalmente a abertura da junta. O acabamento final deve ficar totalmente liso e faceado a elementos de remate, não sendo permitido irregularidades ou detritos","check":{"insp":{"x":320.2,"cy":540.84},"reinsp1":{"x":347.2,"cy":540.84},"reinsp2":{"x":374.2,"cy":540.84},"reinsp3":{"x":401.2,"cy":540.84}},"anotacao":{"x":416.4,"y_baseline":559.68,"largura":90}},{"id":"L27","seccao":"juntas","criterio":"Conforme projeto","check":{"insp":{"x":320.2,"cy":565.92},"reinsp1":{"x":347.2,"cy":565.92},"reinsp2":{"x":374.2,"cy":565.92},"reinsp3":{"x":401.2,"cy":565.92}},"anotacao":{"x":416.4,"y_baseline":570.0,"largura":90}},{"id":"L28","seccao":"betonagem","criterio":"A aplicação do betão deve ser efetuada em condições atmosféricas favoráveis, exceto em casos devidamente justificados e mediante","check":{"insp":{"x":320.2,"cy":614.52},"reinsp1":{"x":347.2,"cy":614.52},"reinsp2":{"x":374.2,"cy":614.52},"reinsp3":{"x":401.2,"cy":614.52}},"anotacao":{"x":416.4,"y_baseline":618.48,"largura":90}},{"id":"L29","seccao":"betonagem","criterio":"Altura de queda ≤ 1,5 m","check":{"insp":{"x":320.2,"cy":631.08},"reinsp1":{"x":347.2,"cy":631.08},"reinsp2":{"x":374.2,"cy":631.08},"reinsp3":{"x":401.2,"cy":631.08}},"anotacao":{"x":416.4,"y_baseline":635.04,"largura":90}},{"id":"L30","seccao":"betonagem","criterio":"De acordo com o projeto de execução","check":{"insp":{"x":320.2,"cy":641.16},"reinsp1":{"x":347.2,"cy":641.16},"reinsp2":{"x":374.2,"cy":641.16},"reinsp3":{"x":401.2,"cy":641.16}},"anotacao":{"x":416.4,"y_baseline":645.12,"largura":90}},{"id":"L31","seccao":"betonagem","criterio":"Uniforme","check":{"insp":{"x":320.2,"cy":651.36},"reinsp1":{"x":347.2,"cy":651.36},"reinsp2":{"x":374.2,"cy":651.36},"reinsp3":{"x":401.2,"cy":651.36}},"anotacao":{"x":416.4,"y_baseline":655.44,"largura":90}},{"id":"L32","seccao":"pos_betonagem","criterio":"Verificar se existem fissuras, chochos, descontinuidades ou falta de recobrimento das armaduras. Os elementos devem estar devidamente","check":{"insp":{"x":320.2,"cy":694.8},"reinsp1":{"x":347.2,"cy":694.8},"reinsp2":{"x":374.2,"cy":694.8},"reinsp3":{"x":401.2,"cy":694.8}},"anotacao":{"x":416.4,"y_baseline":700.32,"largura":90}},{"id":"L33","seccao":"pos_betonagem","criterio":"Verificar pendente da laje (se aplicável)","check":{"insp":{"x":320.2,"cy":714.36},"reinsp1":{"x":347.2,"cy":714.36},"reinsp2":{"x":374.2,"cy":714.36},"reinsp3":{"x":401.2,"cy":714.36}},"anotacao":{"x":416.4,"y_baseline":718.32,"largura":90}},{"id":"L34","seccao":"pos_betonagem","criterio":"Verificar juntas de betonagem (se aplicável)","check":{"insp":{"x":320.2,"cy":732.36},"reinsp1":{"x":347.2,"cy":732.36},"reinsp2":{"x":374.2,"cy":732.36},"reinsp3":{"x":401.2,"cy":732.36}},"anotacao":{"x":416.4,"y_baseline":736.32,"largura":90}}]}$mapa$::jsonb,
  '2024-07-30'
);

-- as 34 linhas derivadas do mapa, não transcritas
insert into betonagens.fcq_linha (modelo_impresso_id, codigo, seccao, criterio, ordem)
select m.id,
       l.valor ->> 'id',
       (l.valor ->> 'seccao')::betonagens.fcq_seccao,
       l.valor ->> 'criterio',
       l.ordinalidade::integer
  from betonagens.modelo_impresso m
 cross join lateral jsonb_array_elements(m.mapa_campos -> 'linhas')
              with ordinality as l(valor, ordinalidade)
 where m.codigo = 'I.CR.033' and m.revisao = 9;

-- ── verificações do próprio seed ────────────────────────────────────────────
-- Se alguma falhar, a migração aborta e não fica meio aplicada.
do $$
declare
  v_m betonagens.modelo_impresso;
  v_n bigint;
begin
  select * into v_m from betonagens.modelo_impresso
   where codigo = 'I.CR.033' and revisao = 9;

  if octet_length(v_m.sha256) <> 32 then
    raise exception 'O sha256 do modelo não tem 32 bytes.';
  end if;

  if (v_m.mapa_campos -> 'documento' ->> 'largura_pt')::numeric <> 595.276
     or (v_m.mapa_campos -> 'documento' ->> 'altura_pt')::numeric <> 841.89 then
    raise exception 'As dimensões do documento no mapa não correspondem ao impresso A4 esperado.';
  end if;

  if jsonb_array_length(v_m.mapa_campos -> 'linhas') <> 34 then
    raise exception 'O mapa não tem 34 linhas.';
  end if;

  if jsonb_array_length(v_m.mapa_campos -> 'blocos_assinatura' -> 'blocos') <> 6 then
    raise exception 'O mapa não tem 6 blocos de assinatura.';
  end if;

  select count(*) into v_n from jsonb_object_keys(v_m.mapa_campos -> 'colunas_inspecao');
  if v_n <> 4 then
    raise exception 'O mapa não tem 4 colunas de inspeção.';
  end if;

  select count(*) into v_n from betonagens.fcq_linha f where f.modelo_impresso_id = v_m.id;
  if v_n <> 34 then
    raise exception 'Foram derivadas % linhas em vez de 34.', v_n;
  end if;

  -- contagem por secção, conferida contra o impresso
  if not exists (
    select 1 from (
      select f.seccao, count(*) as n
        from betonagens.fcq_linha f
       where f.modelo_impresso_id = v_m.id
       group by f.seccao
    ) c
    where (c.seccao, c.n) in (
      ('implantacao'::betonagens.fcq_seccao, 1),
      ('cofragem'::betonagens.fcq_seccao, 5),
      ('armaduras'::betonagens.fcq_seccao, 14),
      ('juntas'::betonagens.fcq_seccao, 7),
      ('betonagem'::betonagens.fcq_seccao, 4),
      ('pos_betonagem'::betonagens.fcq_seccao, 3))
    having count(*) = 6
  ) then
    raise exception 'A distribuição de linhas por secção não é 1/5/14/7/4/3.';
  end if;
end $$;

reset role;

insert into betonagens.migracao (ficheiro) values ('0010_seed_modelo_icr033.sql');
