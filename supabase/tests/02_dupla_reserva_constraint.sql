-- TESTE — proteção contra dupla reserva NO BANCO (EXCLUDE + tstzrange).
-- Roda como o papel dono (ignora RLS) para isolar a constraint. Transação com ROLLBACK no fim.
\set ON_ERROR_STOP on
begin;

-- helper temporário: insere um agendamento com os campos obrigatórios coerentes com o status
create function pg_temp.ins_ag(p_prof uuid, p_serv uuid, p_ini timestamptz, p_fim timestamptz, p_status text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.agendamentos (
    profissional_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id, servico_nome_snap,
    preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status,
    reserva_expira_em, cancelado_em, cancelado_por
  ) values (
    p_prof, 'Cliente Teste', '5577900000001', p_serv, 'Servico', 10000, 3000,
    greatest(1, (extract(epoch from (p_fim - p_ini)) / 60)::int), p_ini, p_fim, p_status,
    case when p_status = 'aguardando_pagamento' then now() + interval '10 minutes' end,
    case when p_status = 'cancelado' then now() end,
    case when p_status = 'cancelado' then 'profissional' end
  ) returning id into v_id;
  return v_id;
end $$;

-- helper: tenta inserir e devolve true se o BANCO recusou por exclusion_violation
create function pg_temp.recusa(p_prof uuid, p_serv uuid, p_ini timestamptz, p_fim timestamptz, p_status text)
returns boolean language plpgsql as $$
begin
  perform pg_temp.ins_ag(p_prof, p_serv, p_ini, p_fim, p_status);
  return false;
exception when exclusion_violation then
  return true;
end $$;

do $$
declare
  a constant uuid := '11111111-1111-1111-1111-111111111111';
  b constant uuid := '22222222-2222-2222-2222-222222222222';
  sa constant uuid := 'a1000000-0000-0000-0000-000000000002';
  sb constant uuid := 'b2000000-0000-0000-0000-000000000001';
  d  timestamptz := date_trunc('day', now()) + interval '5 days';  -- base: instantes absolutos
  v_def text;
  v_st text;
begin
  -- 0) a constraint realmente usa tstzrange (e não tsrange)
  select pg_get_constraintdef(oid) into v_def
  from pg_constraint where conname = 'agendamentos_sem_sobreposicao';
  if v_def is null then raise exception 'FALHOU: constraint agendamentos_sem_sobreposicao não existe'; end if;
  if v_def !~* 'tstzrange' or v_def ~* '[^z]tsrange' then
    raise exception 'FALHOU: constraint não usa tstzrange: %', v_def;
  end if;
  raise notice 'OK: a EXCLUDE usa tstzrange -> %', v_def;

  -- 1) base: A 14:00–15:00 confirmado
  perform pg_temp.ins_ag(a, sa, d + interval '14 hours', d + interval '15 hours', 'confirmado');

  -- 2) A 14:30–15:30 (sobreposição parcial) -> DEVE falhar
  if not pg_temp.recusa(a, sa, d + interval '14 hours 30 minutes', d + interval '15 hours 30 minutes', 'confirmado') then
    raise exception 'FALHOU: banco aceitou 14:30–15:30 sobre 14:00–15:00 da mesma profissional';
  end if;
  raise notice 'OK: 14:00–15:00 x 14:30–15:30 (mesma profissional) -> recusado pelo banco';

  -- 2b) contido / contendo / idêntico -> DEVE falhar
  if not pg_temp.recusa(a, sa, d + interval '14 hours 10 minutes', d + interval '14 hours 50 minutes', 'confirmado')
     or not pg_temp.recusa(a, sa, d + interval '13 hours', d + interval '16 hours', 'confirmado')
     or not pg_temp.recusa(a, sa, d + interval '14 hours', d + interval '15 hours', 'confirmado') then
    raise exception 'FALHOU: banco aceitou intervalo contido/contendo/idêntico';
  end if;
  raise notice 'OK: intervalo contido, contendo e idêntico -> recusados';

  -- 3) A 15:00–16:00 (exatamente encostado) -> DEVE permitir ('[)')
  perform pg_temp.ins_ag(a, sa, d + interval '15 hours', d + interval '16 hours', 'confirmado');
  -- e 13:00–14:00 encostando pelo outro lado
  perform pg_temp.ins_ag(a, sa, d + interval '13 hours', d + interval '14 hours', 'confirmado');
  raise notice 'OK: horários exatamente encostados (13–14, 14–15, 15–16) -> permitidos';

  -- 4) Profissional B 14:00–15:00 (mesmo instante) -> DEVE permitir
  perform pg_temp.ins_ag(b, sb, d + interval '14 hours', d + interval '15 hours', 'confirmado');
  raise notice 'OK: profissionais diferentes no mesmo horário -> permitido';

  -- 5) cada status OCUPANTE bloqueia; cada status NÃO ocupante não bloqueia
  foreach v_st in array array['aguardando_pagamento','confirmado','em_atendimento','concluido','faltou'] loop
    if not pg_temp.recusa(a, sa, d + interval '14 hours 15 minutes', d + interval '14 hours 45 minutes', v_st) then
      raise exception 'FALHOU: status ocupante % foi aceito sobre horário ocupado', v_st;
    end if;
  end loop;
  raise notice 'OK: aguardando_pagamento/confirmado/em_atendimento/concluido/faltou ocupam o horário';

  perform pg_temp.ins_ag(a, sa, d + interval '14 hours 15 minutes', d + interval '14 hours 45 minutes', 'cancelado');
  perform pg_temp.ins_ag(a, sa, d + interval '14 hours 15 minutes', d + interval '14 hours 45 minutes', 'expirado');
  raise notice 'OK: cancelado e expirado NÃO ocupam o horário';

  -- 6) atualizar status de cancelado -> confirmado sobre horário ocupado volta a ser barrado (UPDATE também é protegido)
  begin
    update public.agendamentos set status = 'confirmado'
    where profissional_id = a and status = 'cancelado' and inicio_em = d + interval '14 hours 15 minutes';
    raise exception 'FALHOU: UPDATE reativou agendamento cancelado sobre horário ocupado';
  exception when exclusion_violation then
    raise notice 'OK: reativar cancelado sobre horário ocupado -> recusado (UPDATE protegido)';
  end;

  -- 7) independência do fuso da sessão: tstzrange compara instantes absolutos
  set local timezone = 'Asia/Tokyo';
  if not pg_temp.recusa(a, sa, d + interval '14 hours 30 minutes', d + interval '15 hours 30 minutes', 'confirmado') then
    raise exception 'FALHOU: com TimeZone=Asia/Tokyo o banco aceitou sobreposição';
  end if;
  set local timezone = 'America/Sao_Paulo';
  if not pg_temp.recusa(a, sa, d + interval '14 hours 30 minutes', d + interval '15 hours 30 minutes', 'confirmado') then
    raise exception 'FALHOU: com TimeZone=America/Sao_Paulo o banco aceitou sobreposição';
  end if;
  set local timezone = 'UTC';
  raise notice 'OK: proteção idêntica com TimeZone da sessão = Tokyo / São Paulo / UTC';

  raise notice '=== PROTEÇÃO CONTRA DUPLA RESERVA (EXCLUDE tstzrange): TODOS OS TESTES PASSARAM ===';
end $$;

rollback;
