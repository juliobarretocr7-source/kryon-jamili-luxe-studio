-- TESTE — FKs compostas: nenhum dado da profissional A referencia dado da profissional B.
-- Roda como dono (ignora RLS) de propósito: prova que a INTEGRIDADE do banco protege
-- mesmo se RLS/código tiverem um bug. Transação com ROLLBACK no fim.
\set ON_ERROR_STOP on
begin;

create function pg_temp.viola_fk(p_sql text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when foreign_key_violation then
  return true;
end $$;

do $$
declare
  a constant uuid := '11111111-1111-1111-1111-111111111111';
  b constant uuid := '22222222-2222-2222-2222-222222222222';
  v_ag_a uuid; v_ag_b uuid; v_pg_a uuid; v_pg_b uuid; v_tx_a uuid; v_tx_b uuid; v_cli_b uuid;
begin
  insert into public.clientes (profissional_id, nome, whatsapp) values (b, 'Cliente B', '5511977770001') returning id into v_cli_b;

  insert into public.agendamentos (profissional_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id, servico_nome_snap,
    preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status, confirmado_em, numero)
  values (a, 'X', '5577900000001', 'a1000000-0000-0000-0000-000000000002', 'Manutenção', 10000, 3000, 60,
    now() + interval '2 days', now() + interval '2 days 1 hour', 'confirmado', now(), 1) returning id into v_ag_a;
  insert into public.agendamentos (profissional_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id, servico_nome_snap,
    preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status, confirmado_em, numero)
  values (b, 'Y', '5511900000001', 'b2000000-0000-0000-0000-000000000001', 'Corte', 6000, 2000, 60,
    now() + interval '2 days', now() + interval '2 days 1 hour', 'confirmado', now(), 1) returning id into v_ag_b;

  insert into public.pagamentos (profissional_id, agendamento_id, valor_centavos, provedor, chave_idempotencia)
    values (a, v_ag_a, 3000, 'simulado', 'fk-a') returning id into v_pg_a;
  insert into public.pagamentos (profissional_id, agendamento_id, valor_centavos, provedor, chave_idempotencia)
    values (b, v_ag_b, 2000, 'simulado', 'fk-b') returning id into v_pg_b;
  raise notice 'OK: pagamento de cada profissional aponta para agendamento da PRÓPRIA profissional';

  -- agendamentos -> serviço / cliente de outra profissional
  if not pg_temp.viola_fk(format($f$
    insert into public.agendamentos (profissional_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id, servico_nome_snap,
      preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status, reserva_expira_em)
    values (%L, 'X', '5577900000002', 'b2000000-0000-0000-0000-000000000001', 'Corte', 6000, 2000, 60,
      now() + interval '9 days', now() + interval '9 days 1 hour', 'aguardando_pagamento', now() + interval '10 minutes')$f$, a)) then
    raise exception 'FALHOU: agendamento de A aceitou serviço de B';
  end if;
  if not pg_temp.viola_fk(format($f$
    insert into public.agendamentos (profissional_id, cliente_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id, servico_nome_snap,
      preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status, reserva_expira_em)
    values (%L, %L, 'X', '5577900000002', 'a1000000-0000-0000-0000-000000000002', 'Manutenção', 10000, 3000, 60,
      now() + interval '9 days', now() + interval '9 days 1 hour', 'aguardando_pagamento', now() + interval '10 minutes')$f$, a, v_cli_b)) then
    raise exception 'FALHOU: agendamento de A aceitou cliente de B';
  end if;
  raise notice 'OK: agendamento -> serviço/cliente de outra profissional recusado (FK composta)';

  -- PAGAMENTO de A apontando para agendamento de B -> DEVE falhar
  if not pg_temp.viola_fk(format($f$insert into public.pagamentos (profissional_id, agendamento_id, valor_centavos, provedor, chave_idempotencia)
    values (%L, %L, 1000, 'simulado', 'fk-cruzado-1')$f$, a, v_ag_b)) then
    raise exception 'FALHOU: pagamento de A aceitou agendamento de B';
  end if;
  if not pg_temp.viola_fk(format($f$insert into public.pagamentos (profissional_id, agendamento_id, valor_centavos, provedor, chave_idempotencia)
    values (%L, %L, 1000, 'simulado', 'fk-cruzado-2')$f$, b, v_ag_a)) then
    raise exception 'FALHOU: pagamento de B aceitou agendamento de A';
  end if;
  -- UPDATE também: religar pagamento existente de A ao agendamento de B
  if not pg_temp.viola_fk(format($f$update public.pagamentos set agendamento_id = %L where id = %L$f$, v_ag_b, v_pg_a)) then
    raise exception 'FALHOU: UPDATE religou pagamento de A ao agendamento de B';
  end if;
  raise notice 'OK: pagamentos -> agendamento de outra profissional recusado (INSERT e UPDATE)';

  -- EVENTO de A apontando para agendamento de B -> DEVE falhar
  if not pg_temp.viola_fk(format($f$insert into public.agendamento_eventos (profissional_id, agendamento_id, tipo, ator)
    values (%L, %L, 'criado', 'sistema')$f$, a, v_ag_b)) then
    raise exception 'FALHOU: evento de A aceitou agendamento de B';
  end if;
  insert into public.agendamento_eventos (profissional_id, agendamento_id, tipo, ator) values (a, v_ag_a, 'criado', 'sistema');
  raise notice 'OK: eventos -> agendamento de outra profissional recusado; o da própria aceito';

  -- TRANSAÇÕES: agendamento / pagamento / estorno de outra profissional
  insert into public.transacoes_financeiras (profissional_id, tipo, origem, categoria, valor_centavos, metodo, data_local, agendamento_id, pagamento_id)
    values (a, 'entrada', 'sinal', 'Sinal', 3000, 'PIX', current_date, v_ag_a, v_pg_a) returning id into v_tx_a;
  insert into public.transacoes_financeiras (profissional_id, tipo, origem, categoria, valor_centavos, metodo, data_local)
    values (b, 'entrada', 'manual', 'Teste', 500, 'Manual', current_date) returning id into v_tx_b;

  if not pg_temp.viola_fk(format($f$insert into public.transacoes_financeiras (profissional_id, tipo, origem, categoria, valor_centavos, metodo, data_local, agendamento_id)
    values (%L, 'entrada', 'manual', 'X', 100, 'Manual', current_date, %L)$f$, a, v_ag_b)) then
    raise exception 'FALHOU: transação de A aceitou agendamento de B';
  end if;
  if not pg_temp.viola_fk(format($f$insert into public.transacoes_financeiras (profissional_id, tipo, origem, categoria, valor_centavos, metodo, data_local, pagamento_id)
    values (%L, 'entrada', 'sinal', 'X', 100, 'PIX', current_date, %L)$f$, a, v_pg_b)) then
    raise exception 'FALHOU: transação de A aceitou pagamento de B';
  end if;
  if not pg_temp.viola_fk(format($f$insert into public.transacoes_financeiras (profissional_id, tipo, origem, categoria, valor_centavos, metodo, data_local, estorna_transacao_id)
    values (%L, 'saida', 'estorno', 'X', 100, 'Manual', current_date, %L)$f$, a, v_tx_b)) then
    raise exception 'FALHOU: estorno de A aceitou lançamento de B';
  end if;
  insert into public.transacoes_financeiras (profissional_id, tipo, origem, categoria, valor_centavos, metodo, data_local, estorna_transacao_id)
    values (a, 'saida', 'estorno', 'Estorno', 3000, 'PIX', current_date, v_tx_a);
  raise notice 'OK: transações -> agendamento/pagamento/estorno de outra profissional recusados; estorno próprio aceito';

  raise notice '=== FKs COMPOSTAS / INTEGRIDADE ENTRE PROFISSIONAIS: TODOS OS TESTES PASSARAM ===';
end $$;

rollback;
