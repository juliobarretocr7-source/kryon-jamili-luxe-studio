-- TESTE — fn_criar_reserva: idempotência, reservas expiradas, isolamento via função,
-- janela e numeração por profissional. Transação com ROLLBACK no fim.
-- (Concorrência REAL entre duas conexões não é possível num único script: ver doc, seção de pendências.)
\set ON_ERROR_STOP on
begin;

do $$
declare
  a  constant uuid := '11111111-1111-1111-1111-111111111111';
  b  constant uuid := '22222222-2222-2222-2222-222222222222';
  ua constant uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  ub constant uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  sa constant uuid := 'a1000000-0000-0000-0000-000000000002'; -- Manutenção 120min (A)
  sb constant uuid := 'b2000000-0000-0000-0000-000000000001'; -- Corte 60min (B)
  v_dia date := current_date + 2;
  v_r public.agendamentos;
  v_r1 public.agendamentos;
  v_r2 public.agendamentos;
  v_n int; v_num bigint; v_st text;
  v_ini timestamptz; v_fim timestamptz;
  v_falhou boolean;
  v_ag_confirmado uuid; v_ag_b uuid;
begin
  while extract(dow from v_dia) not in (1,2,3,4,5) loop v_dia := v_dia + 1; end loop;

  -- 1) criar reserva: aguardando_pagamento, prazo, evento 'criado', sem número
  v_r1 := public.fn_criar_reserva(a, sa, 'Cliente 1', '5577911110001', v_dia, 600, 'publico', 'chave-1'); -- 10:00–12:00
  if v_r1.status <> 'aguardando_pagamento' or v_r1.reserva_expira_em is null or v_r1.numero is not null then
    raise exception 'FALHOU: reserva criada com estado inesperado (%, %, %)', v_r1.status, v_r1.reserva_expira_em, v_r1.numero;
  end if;
  if v_r1.preco_centavos <> 10000 or v_r1.sinal_centavos <> 3000 or v_r1.duracao_min <> 120 then
    raise exception 'FALHOU: preço/sinal/duração não vieram do serviço no banco';
  end if;
  select count(*) into v_n from public.agendamento_eventos where agendamento_id = v_r1.id and tipo = 'criado';
  if v_n <> 1 then raise exception 'FALHOU: evento criado ausente'; end if;
  raise notice 'OK: reserva criada (aguardando_pagamento, prazo, valores do serviço, sem número, evento criado)';

  -- 2) idempotência: mesma chave devolve a MESMA reserva, sem duplicar
  v_r := public.fn_criar_reserva(a, sa, 'Cliente 1', '5577911110001', v_dia, 600, 'publico', 'chave-1');
  select count(*) into v_n from public.agendamentos where profissional_id = a and chave_idempotencia = 'chave-1';
  if v_r.id <> v_r1.id or v_n <> 1 then raise exception 'FALHOU: idempotência criou/retornou reserva diferente'; end if;
  select count(*) into v_n from public.agendamento_eventos where agendamento_id = v_r1.id and tipo = 'criado';
  if v_n <> 1 then raise exception 'FALHOU: retry duplicou o evento criado'; end if;
  raise notice 'OK: retry com a mesma chave devolve a mesma reserva (sem duplicar)';

  -- 3) outra pessoa (outra chave) no mesmo horário -> recusada (mensagem amigável, SQLSTATE 23P01)
  v_falhou := false;
  begin
    perform public.fn_criar_reserva(a, sa, 'Cliente 2', '5577911110002', v_dia, 600, 'publico', 'chave-2');
  exception when exclusion_violation then v_falhou := true;
  end;
  if not v_falhou then raise exception 'FALHOU: segunda pessoa reservou o mesmo horário'; end if;
  raise notice 'OK: mesmo horário, outra pessoa -> recusado';

  -- 4) horário exatamente encostado (12:00–14:00) é aceito
  v_r2 := public.fn_criar_reserva(a, sa, 'Cliente 3', '5577911110003', v_dia, 720, 'publico', 'chave-3');
  raise notice 'OK: reserva encostada 12:00 aceita (id %)', v_r2.id;

  -- 5) profissional diferente, mesmo horário -> aceito
  perform public.fn_criar_reserva(b, sb, 'Cliente B', '5511911110001', v_dia, 600, 'publico', 'chave-b1');
  raise notice 'OK: outra profissional no mesmo horário aceita';

  -- 6) serviço de OUTRA profissional é recusado pela função
  v_falhou := false;
  begin
    perform public.fn_criar_reserva(a, sb, 'Fraude', '5577911110009', v_dia, 780, 'publico', 'chave-x');
  exception when sqlstate 'P0001' then v_falhou := true;
  end;
  if not v_falhou then raise exception 'FALHOU: reserva de A usando serviço de B foi aceita'; end if;
  raise notice 'OK: serviço de outra profissional recusado em fn_criar_reserva';

  -- 7) RESERVA EXPIRADA (prazo vencido, ainda marcada aguardando_pagamento) não bloqueia
  update public.agendamentos set reserva_expira_em = now() - interval '1 minute' where id = v_r1.id;
  if not exists (select 1 from public.fn_horarios_disponiveis(a, v_dia, 120) where inicio_min = 600) then
    raise exception 'FALHOU: 10:00 deveria aparecer livre: a reserva vencida não pode bloquear';
  end if;
  v_r := public.fn_criar_reserva(a, sa, 'Cliente 4', '5577911110004', v_dia, 600, 'publico', 'chave-4');
  select status into v_st from public.agendamentos where id = v_r1.id;
  if v_st <> 'expirado' then raise exception 'FALHOU: reserva vencida deveria virar expirado, está %', v_st; end if;
  select count(*) into v_n from public.agendamento_eventos where agendamento_id = v_r1.id and tipo = 'expirado';
  if v_n <> 1 then raise exception 'FALHOU: evento expirado não gravado (%)', v_n; end if;
  if not exists (select 1 from public.agendamentos where id = v_r1.id) then
    raise exception 'FALHOU: registro expirado não deveria ser apagado (histórico)';
  end if;
  raise notice 'OK: reserva vencida libera o horário, vira expirado, grava evento e permanece no histórico';

  -- 8) reserva NÃO vencida continua bloqueando
  v_falhou := false;
  begin
    perform public.fn_criar_reserva(a, sa, 'Cliente 5', '5577911110005', v_dia, 600, 'publico', 'chave-5');
  exception when exclusion_violation then v_falhou := true;
  end;
  if not v_falhou then raise exception 'FALHOU: reserva dentro do prazo não bloqueou o horário'; end if;
  raise notice 'OK: reserva ainda dentro do prazo continua bloqueando';

  -- 9) caminho DIRETO (painel/reagendamento): o trigger libera vencidas conflitantes, o banco barra as válidas
  v_ini := (v_dia + time '15:00') at time zone 'America/Sao_Paulo';
  v_fim := (v_dia + time '16:00') at time zone 'America/Sao_Paulo';
  insert into public.agendamentos (profissional_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id, servico_nome_snap,
    preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status, reserva_expira_em)
  values (a, 'V', '5577900000001', sa, 'Manutenção', 10000, 3000, 60, v_ini, v_fim, 'aguardando_pagamento', now() + interval '10 minutes')
  returning id into v_ag_b;
  update public.agendamentos set reserva_expira_em = now() - interval '1 minute' where id = v_ag_b;
  insert into public.agendamentos (profissional_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id, servico_nome_snap,
    preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status, confirmado_em)
  values (a, 'Painel', '5577900000002', sa, 'Manutenção', 10000, 3000, 60, v_ini, v_fim, 'confirmado', now())
  returning id into v_ag_confirmado;
  select status into v_st from public.agendamentos where id = v_ag_b;
  if v_st <> 'expirado' then raise exception 'FALHOU: trigger não expirou a reserva vencida conflitante (%)', v_st; end if;
  v_falhou := false;
  begin
    insert into public.agendamentos (profissional_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id, servico_nome_snap,
      preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status, reserva_expira_em)
    values (a, 'W', '5577900000003', sa, 'Manutenção', 10000, 3000, 60, v_ini, v_fim, 'aguardando_pagamento', now() + interval '10 minutes');
  exception when exclusion_violation then v_falhou := true;
  end;
  if not v_falhou then raise exception 'FALHOU: INSERT direto sobre horário confirmado foi aceito'; end if;
  raise notice 'OK: INSERT direto -> vencida é liberada pelo trigger; horário válido continua protegido pela EXCLUDE';

  -- 10) janela: data além de hoje+21 é recusada para reserva pública
  v_falhou := false;
  begin
    perform public.fn_criar_reserva(a, sa, 'Longe', '5577911110077', current_date + 40, 600, 'publico', 'chave-longe');
  exception when exclusion_violation then v_falhou := true;
  end;
  if not v_falhou then raise exception 'FALHOU: reserva pública além da janela foi aceita'; end if;
  raise notice 'OK: reserva pública fora da janela recusada';

  -- 11) NUMERAÇÃO: sequência por profissional, atômica, #000001, única por profissional
  select public.fn_proximo_numero_agendamento(a) into v_num;
  if v_num <> 1 then raise exception 'FALHOU: primeiro número de A deveria ser 1, veio %', v_num; end if;
  select public.fn_proximo_numero_agendamento(a) into v_num;
  if v_num <> 2 then raise exception 'FALHOU: segundo número de A deveria ser 2, veio %', v_num; end if;
  select public.fn_proximo_numero_agendamento(b) into v_num;
  if v_num <> 1 then raise exception 'FALHOU: sequência de B deveria começar em 1 (independente de A), veio %', v_num; end if;
  if ('#' || lpad(v_num::text, 6, '0')) <> '#000001' then raise exception 'FALHOU: formato #000001'; end if;
  raise notice 'OK: numeração sequencial por profissional (A: 1,2 — B: 1), formato #000001';

  -- reservas não pagas/expiradas não consumiram número
  if exists (select 1 from public.agendamentos where profissional_id = a and numero is not null) then
    raise exception 'FALHOU: alguma reserva recebeu número antes da confirmação';
  end if;

  update public.agendamentos set numero = 1, confirmado_em = now(), status = 'confirmado' where id = v_ag_confirmado;
  -- número repetido na MESMA profissional -> unique_violation
  v_falhou := false;
  begin
    update public.agendamentos set numero = 1, confirmado_em = now() where id = v_r2.id;
  exception when unique_violation then v_falhou := true;
  end;
  if not v_falhou then raise exception 'FALHOU: número 1 repetido na mesma profissional foi aceito'; end if;
  -- número sem confirmação -> check_violation
  v_falhou := false;
  begin
    update public.agendamentos set numero = 9 where id = v_r.id and confirmado_em is null;
  exception when check_violation then v_falhou := true;
  end;
  if not v_falhou then raise exception 'FALHOU: número foi aceito em reserva sem confirmado_em'; end if;
  raise notice 'OK: número único por profissional e só após confirmação';

  -- 12) via sessão logada: B não consegue criar reserva na agenda de A; A consegue na dela
  perform test.login_como(ub);
  v_falhou := false;
  begin
    perform public.fn_criar_reserva(a, sa, 'Invasor', '5577911110088', v_dia, 480, 'publico', 'chave-inv');
  exception when others then v_falhou := true;
  end;
  if not v_falhou then raise exception 'FALHOU: B criou reserva na agenda de A por fn_criar_reserva'; end if;
  perform test.login_como(ua);
  v_r := public.fn_criar_reserva(a, sa, 'Logada', '5577911110099', v_dia, 480, 'painel', 'chave-logada');
  perform test.logout();
  raise notice 'OK: via RLS, B não reserva na agenda de A; A reserva na própria';

  raise notice '=== RESERVAS EXPIRADAS / IDEMPOTÊNCIA / NUMERAÇÃO: TODOS OS TESTES PASSARAM ===';
end $$;

rollback;
reset role;
