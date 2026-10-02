-- TESTE — isolamento multi-tenant (RLS) entre duas profissionais.
-- Pré-requisito: migrations + seed aplicados; 00_stub_auth_local.sql carregado.
-- Roda tudo dentro de uma transação e faz ROLLBACK no fim (não deixa lixo).
-- IMPORTANTE (correção da auditoria 7B): o RLS só vale para papéis que NÃO são dono da
-- tabela. Por isso aqui usamos test.login_como(), que troca para o papel "authenticated".
-- A versão anterior rodava como dono (RLS ignorado) e engolia falhas com "when others".
\set ON_ERROR_STOP on
begin;

do $$
declare
  v_a  constant uuid := '11111111-1111-1111-1111-111111111111';
  v_b  constant uuid := '22222222-2222-2222-2222-222222222222';
  v_ua constant uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_ub constant uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  v_ag_b uuid;
  v_n int;
  v_rc int;
  v_bloqueou boolean;
  v_tabela text;
begin
  -- ---------- preparação como dono (ignora RLS): um agendamento, cliente e evento da B ----------
  insert into public.clientes (profissional_id, nome, whatsapp) values (v_b, 'Cliente B', '5511977770000');
  insert into public.agendamentos (profissional_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id,
    servico_nome_snap, preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status, reserva_expira_em)
  values (v_b, 'Cliente B', '5511977770000', 'b2000000-0000-0000-0000-000000000001', 'Corte', 6000, 2000, 60,
    now() + interval '3 days', now() + interval '3 days 1 hour', 'aguardando_pagamento', now() + interval '10 minutes')
  returning id into v_ag_b;
  insert into public.agendamento_eventos (profissional_id, agendamento_id, tipo, ator) values (v_b, v_ag_b, 'criado', 'cliente');
  insert into public.pagamentos (profissional_id, agendamento_id, valor_centavos, provedor, chave_idempotencia)
    values (v_b, v_ag_b, 2000, 'simulado', 'teste-iso-b');
  insert into public.transacoes_financeiras (profissional_id, tipo, origem, categoria, valor_centavos, metodo, data_local)
    values (v_b, 'entrada', 'manual', 'Teste', 1000, 'Manual', current_date);

  -- ---------- logada como A (papel authenticated) ----------
  perform test.login_como(v_ua);
  if current_user <> 'authenticated' then
    raise exception 'FALHOU: login_como não trocou para o papel authenticated (RLS não seria testado)';
  end if;

  -- LEITURA: A só vê os próprios dados, em TODAS as tabelas com profissional_id
  foreach v_tabela in array array['servicos','clientes','agendamentos','agendamento_eventos','pagamentos',
                                  'transacoes_financeiras','configuracoes','horarios_funcionamento','intervalos','usuarios'] loop
    execute format('select count(*) from public.%I where profissional_id = %L', v_tabela, v_b) into v_n;
    if v_n <> 0 then
      raise exception 'FALHOU: A enxergou % linha(s) de B em %', v_n, v_tabela;
    end if;
  end loop;
  select count(*) into v_n from public.profissionais where id = v_b;
  if v_n <> 0 then raise exception 'FALHOU: A enxergou o cadastro da profissional B'; end if;
  select count(*) into v_n from public.servicos;
  if v_n <> 5 then raise exception 'FALHOU: A deveria ver 5 serviços, viu %', v_n; end if;
  raise notice 'OK: A só enxerga os próprios dados (11 tabelas conferidas)';

  -- ATUALIZAÇÃO cruzada: 0 linhas afetadas e nada mudou
  update public.servicos set nome = 'Invadido' where id = 'b2000000-0000-0000-0000-000000000001';
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: A alterou serviço de B'; end if;
  update public.clientes set nome = 'Invadido' where profissional_id = v_b;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: A alterou cliente de B'; end if;
  update public.agendamentos set status = 'cancelado' where id = v_ag_b;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: A alterou agendamento de B'; end if;
  update public.configuracoes set sinal_fixo_centavos = 1 where profissional_id = v_b;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: A alterou configuração de B'; end if;
  raise notice 'OK: A não consegue alterar dados de B';

  -- EXCLUSÃO cruzada: 0 linhas afetadas
  delete from public.servicos where profissional_id = v_b;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: A excluiu serviço de B'; end if;
  delete from public.clientes where profissional_id = v_b;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: A excluiu cliente de B'; end if;
  delete from public.horarios_funcionamento where profissional_id = v_b;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: A excluiu horário de B'; end if;
  raise notice 'OK: A não consegue excluir dados de B';

  -- INSERÇÃO cruzada: tem que dar erro (WITH CHECK da policy)
  v_bloqueou := false;
  begin
    insert into public.servicos (profissional_id, nome, preco_centavos, duracao_min, sinal_centavos)
    values (v_b, 'Fraude', 1000, 30, 0);
  exception when insufficient_privilege then v_bloqueou := true;
  end;
  if not v_bloqueou then raise exception 'FALHOU: A inseriu serviço em nome de B'; end if;

  v_bloqueou := false;
  begin
    insert into public.clientes (profissional_id, nome, whatsapp) values (v_b, 'Fraude', '5511900000099');
  exception when insufficient_privilege then v_bloqueou := true;
  end;
  if not v_bloqueou then raise exception 'FALHOU: A inseriu cliente em nome de B'; end if;

  v_bloqueou := false;
  begin
    insert into public.agendamento_eventos (profissional_id, agendamento_id, tipo, ator) values (v_b, v_ag_b, 'cancelado', 'profissional');
  exception when insufficient_privilege then v_bloqueou := true;
  end;
  if not v_bloqueou then raise exception 'FALHOU: A inseriu evento em nome de B'; end if;
  raise notice 'OK: A não consegue inserir dados em nome de B';

  -- Mover linha própria para o tenant de B também é bloqueado (WITH CHECK do UPDATE)
  v_bloqueou := false;
  begin
    update public.servicos set profissional_id = v_b where profissional_id = v_a and ordem = 1;
  exception when insufficient_privilege or foreign_key_violation then v_bloqueou := true;
  end;
  if not v_bloqueou then raise exception 'FALHOU: A moveu serviço próprio para o tenant de B'; end if;
  raise notice 'OK: A não consegue transferir linha para B (UPDATE ... SET profissional_id)';

  -- Restrições de escrita por tabela (decisões da auditoria 7B)
  v_bloqueou := false;
  begin
    insert into public.pagamentos (profissional_id, agendamento_id, valor_centavos, provedor, chave_idempotencia, status)
    values (v_a, (select id from public.agendamentos where profissional_id = v_a limit 1), 1000, 'simulado', 'fraude-aprovado', 'aprovado');
  exception when insufficient_privilege or not_null_violation or foreign_key_violation then v_bloqueou := true;
  end;
  if not v_bloqueou then raise exception 'FALHOU: A gravou pagamento direto pelo navegador (só o servidor deve gravar)'; end if;

  update public.usuarios set papel = 'dono', ativo = false where id = v_ua;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: A alterou o próprio vínculo em usuarios (só o servidor deve)'; end if;
  delete from public.usuarios where id = v_ua;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: A apagou o próprio vínculo em usuarios'; end if;
  delete from public.profissionais where id = v_a;
  get diagnostics v_rc = row_count;
  if v_rc <> 0 then raise exception 'FALHOU: A apagou o próprio cadastro de profissional'; end if;
  raise notice 'OK: pagamentos/usuarios/profissionais protegidos contra escrita indevida pelo navegador';

  -- Sem login (anon / sem sessão): nada visível
  perform test.logout();
  execute 'set role anon';
  select count(*) into v_n from public.servicos;
  if v_n <> 0 then raise exception 'FALHOU: papel anon enxergou % serviços', v_n; end if;
  execute 'reset role';
  raise notice 'OK: anon não enxerga nada';

  -- Sessão autenticada mas SEM vínculo em usuarios: nada visível
  perform test.login_como('cccccccc-cccc-cccc-cccc-cccccccccccc');
  select count(*) into v_n from public.servicos;
  if v_n <> 0 then raise exception 'FALHOU: usuário sem vínculo enxergou % serviços', v_n; end if;
  raise notice 'OK: usuário autenticado sem profissional vinculada não enxerga nada';

  -- ---------- troca de sessão: B ----------
  perform test.login_como(v_ub);
  select count(*) into v_n from public.servicos;
  if v_n <> 1 then raise exception 'FALHOU: B deveria ver 1 serviço, viu %', v_n; end if;
  select count(*) into v_n from public.servicos where profissional_id = v_a;
  if v_n <> 0 then raise exception 'FALHOU: B viu serviços de A'; end if;
  select count(*) into v_n from public.agendamentos where id = v_ag_b;
  if v_n <> 1 then raise exception 'FALHOU: B deveria ver o próprio agendamento'; end if;
  raise notice 'OK: B só enxerga o que é dela';

  perform test.logout();
  raise notice '=== ISOLAMENTO MULTI-TENANT (RLS): TODOS OS TESTES PASSARAM ===';
end $$;

rollback;
reset role;
