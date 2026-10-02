-- TESTE — imutabilidade de agendamento_eventos e transacoes_financeiras.
-- Duas camadas: (1) papel authenticated: RLS só permite SELECT/INSERT, então UPDATE/DELETE
-- afetam 0 linhas; (2) papel dono (ignora RLS): o trigger levanta exceção.
\set ON_ERROR_STOP on
begin;

do $$
declare
  a constant uuid := '11111111-1111-1111-1111-111111111111';
  ua constant uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_ag uuid; v_ev uuid; v_tx uuid; v_rc int; v_bloqueou boolean; v_tipo text; v_val int;
begin
  insert into public.agendamentos (profissional_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id, servico_nome_snap,
    preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status, confirmado_em)
  values (a, 'X', '5577900000001', 'a1000000-0000-0000-0000-000000000002', 'Manutenção', 10000, 3000, 60,
    now() + interval '2 days', now() + interval '2 days 1 hour', 'confirmado', now()) returning id into v_ag;
  insert into public.agendamento_eventos (profissional_id, agendamento_id, tipo, ator, dados)
    values (a, v_ag, 'criado', 'sistema', '{"v":1}') returning id into v_ev;
  insert into public.transacoes_financeiras (profissional_id, tipo, origem, categoria, valor_centavos, metodo, data_local)
    values (a, 'entrada', 'manual', 'Teste', 1000, 'Manual', current_date) returning id into v_tx;

  -- ---- camada 1: como a própria profissional logada (authenticated) ----
  perform test.login_como(ua);
  update public.agendamento_eventos set tipo = 'cancelado' where id = v_ev;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: profissional logada alterou evento'; end if;
  delete from public.agendamento_eventos where id = v_ev;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: profissional logada apagou evento'; end if;
  update public.transacoes_financeiras set valor_centavos = 1 where id = v_tx;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: profissional logada alterou lançamento'; end if;
  delete from public.transacoes_financeiras where id = v_tx;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: profissional logada apagou lançamento'; end if;
  -- acrescentar continua permitido
  insert into public.agendamento_eventos (profissional_id, agendamento_id, tipo, ator) values (a, v_ag, 'pago', 'profissional');
  perform test.logout();
  raise notice 'OK: authenticated só consegue ler/acrescentar (UPDATE/DELETE = 0 linhas)';

  -- ---- camada 2: como dono (RLS ignorado) — o TRIGGER tem que barrar ----
  v_bloqueou := false;
  begin update public.agendamento_eventos set tipo = 'cancelado' where id = v_ev;
  exception when restrict_violation then v_bloqueou := true; end;
  if not v_bloqueou then raise exception 'FALHOU: UPDATE em agendamento_eventos não foi barrado pelo trigger'; end if;

  v_bloqueou := false;
  begin delete from public.agendamento_eventos where id = v_ev;
  exception when restrict_violation then v_bloqueou := true; end;
  if not v_bloqueou then raise exception 'FALHOU: DELETE em agendamento_eventos não foi barrado pelo trigger'; end if;

  v_bloqueou := false;
  begin truncate public.agendamento_eventos;
  exception when restrict_violation then v_bloqueou := true; end;
  if not v_bloqueou then raise exception 'FALHOU: TRUNCATE em agendamento_eventos não foi barrado'; end if;

  v_bloqueou := false;
  begin update public.transacoes_financeiras set valor_centavos = 1 where id = v_tx;
  exception when restrict_violation then v_bloqueou := true; end;
  if not v_bloqueou then raise exception 'FALHOU: UPDATE em transacoes_financeiras não foi barrado'; end if;

  v_bloqueou := false;
  begin delete from public.transacoes_financeiras where id = v_tx;
  exception when restrict_violation then v_bloqueou := true; end;
  if not v_bloqueou then raise exception 'FALHOU: DELETE em transacoes_financeiras não foi barrado'; end if;

  v_bloqueou := false;
  begin truncate public.transacoes_financeiras;
  exception when restrict_violation then v_bloqueou := true; end;
  if not v_bloqueou then raise exception 'FALHOU: TRUNCATE em transacoes_financeiras não foi barrado'; end if;

  -- nada mudou
  select tipo into v_tipo from public.agendamento_eventos where id = v_ev;
  select valor_centavos into v_val from public.transacoes_financeiras where id = v_tx;
  if v_tipo <> 'criado' or v_val <> 1000 then raise exception 'FALHOU: dados imutáveis foram alterados'; end if;
  raise notice 'OK: triggers barram UPDATE/DELETE/TRUNCATE mesmo para o dono das tabelas';
  raise notice '=== IMUTABILIDADE (eventos + livro-caixa): TODOS OS TESTES PASSARAM ===';
end $$;

rollback;
