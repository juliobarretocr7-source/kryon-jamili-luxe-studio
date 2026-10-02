-- TESTE — fn_horarios_disponiveis: duração, intervalo, conflitos, dia fechado,
-- cancelamento libera horário. Mesmos casos da regra de disponibilidade do protótipo.

\set ON_ERROR_STOP on
begin;

do $$
declare
  v_prof uuid := '11111111-1111-1111-1111-111111111111';
  v_dia date;
  v_qtd int;
  v_min int;
  v_max int;
  v_ag_id uuid;
begin
  -- acha a próxima segunda-feira (dia aberto 08:00-18:00 no seed) para o teste
  v_dia := current_date + 1;
  while extract(dow from v_dia) not in (1,2,3,4,5) loop
    v_dia := v_dia + 1;
  end loop;

  delete from public.agendamentos where profissional_id = v_prof and observacoes = 'TESTE_DISPONIBILIDADE';

  -- CASO: serviço de 2h30 (150min), expediente até 18:00 (1080min).
  -- Último início possível é 15:30 (930min); 16:00 não pode aparecer.
  select count(*), min(inicio_min), max(inicio_min) into v_qtd, v_min, v_max
  from public.fn_horarios_disponiveis(v_prof, v_dia, 150);
  if v_max <> 930 then
    raise exception 'FALHOU: ultimo horario para servico de 150min deveria ser 930 (15:30), veio %', v_max;
  end if;
  if exists (select 1 from public.fn_horarios_disponiveis(v_prof, v_dia, 150) where inicio_min = 960) then
    raise exception 'FALHOU: 16:00 (960) apareceu disponivel para servico de 150min que nao caberia';
  end if;
  raise notice 'OK: servico de 2h30 nao oferece horario que terminaria depois do fechamento';

  -- CASO: cria um agendamento 13:30-16:00 (150min) e confere que cruzamentos ficam bloqueados
  insert into public.agendamentos (
    profissional_id, cliente_nome_snap, cliente_whatsapp_snap, servico_id, servico_nome_snap,
    preco_centavos, sinal_centavos, duracao_min, inicio_em, fim_em, status, observacoes
  ) values (
    v_prof, 'Cliente X', '5577900000010', 'a1000000-0000-0000-0000-000000000001', 'Alongamento',
    18000, 5000, 150,
    (v_dia + time '13:30') at time zone 'America/Sao_Paulo',
    (v_dia + time '16:00') at time zone 'America/Sao_Paulo',
    'confirmado', 'TESTE_DISPONIBILIDADE'
  ) returning id into v_ag_id;

  if exists (select 1 from public.fn_horarios_disponiveis(v_prof, v_dia, 60) where inicio_min = 780) then -- 13:00, terminaria 14:00
    raise exception 'FALHOU: 13:00 apareceu livre mesmo cruzando com agendamento 13:30-16:00';
  end if;
  if exists (select 1 from public.fn_horarios_disponiveis(v_prof, v_dia, 60) where inicio_min = 930) then -- 15:30, cruza
    raise exception 'FALHOU: 15:30 apareceu livre mesmo cruzando com agendamento 13:30-16:00';
  end if;
  if not exists (select 1 from public.fn_horarios_disponiveis(v_prof, v_dia, 60) where inicio_min = 960) then -- 16:00, encosta
    raise exception 'FALHOU: 16:00 deveria estar livre (comeca exatamente quando o outro termina)';
  end if;
  raise notice 'OK: agendamento 13:30-16:00 bloqueia cruzamentos e libera exatamente as 16:00';

  -- CASO: espaço exato 16:00-18:00, serviço de 2h -> 16:00 válido
  if not exists (select 1 from public.fn_horarios_disponiveis(v_prof, v_dia, 120) where inicio_min = 960) then
    raise exception 'FALHOU: 16:00 deveria ser valido para servico de 2h com espaco exato ate 18:00';
  end if;
  raise notice 'OK: espaco exato de 2h (16:00-18:00) e valido';

  -- CASO: serviço de 1h30, passo de 30min -> 16:00 e 16:30 válidos
  if not exists (select 1 from public.fn_horarios_disponiveis(v_prof, v_dia, 90) where inicio_min = 960)
     or not exists (select 1 from public.fn_horarios_disponiveis(v_prof, v_dia, 90) where inicio_min = 990) then
    raise exception 'FALHOU: 16:00 e 16:30 deveriam ser validos para servico de 1h30 (passo de 30min)';
  end if;
  raise notice 'OK: passo de 30 minutos oferece 16:00 e 16:30 para servico de 1h30';

  -- CASO: dia fechado (domingo no seed) -> nenhum horario
  select count(*) into v_qtd from public.fn_horarios_disponiveis(
    v_prof,
    v_dia + ((7 - extract(dow from v_dia)::int) % 7), -- proximo domingo
    60
  );
  if v_qtd <> 0 then
    raise exception 'FALHOU: domingo (fechado no seed) retornou % horarios, esperado 0', v_qtd;
  end if;
  raise notice 'OK: dia fechado (domingo) nao oferece nenhum horario';

  -- CASO: cancelar o agendamento 13:30-16:00 libera o horario das 14:00, por exemplo
  update public.agendamentos set status = 'cancelado', cancelado_em = now(), cancelado_por = 'profissional'
  where id = v_ag_id;
  if not exists (select 1 from public.fn_horarios_disponiveis(v_prof, v_dia, 60) where inicio_min = 840) then -- 14:00
    raise exception 'FALHOU: cancelar o agendamento deveria liberar as 14:00';
  end if;
  raise notice 'OK: cancelar o agendamento libera o horario novamente';

  -- CASO (auditoria 7B): janela de agendamento. Dentro da janela (hoje+21) há horários;
  -- fora (hoje+22 em dia útil) não; p_ignorar_janela = true (painel) volta a aceitar.
  declare
    v_fora date := current_date + 22;
  begin
    while extract(dow from v_fora) not in (1,2,3,4,5) loop v_fora := v_fora + 1; end loop;
    if exists (select 1 from public.fn_horarios_disponiveis(v_prof, v_fora, 60)) then
      raise exception 'FALHOU: data fora da janela de 21 dias ofereceu horarios';
    end if;
    if not exists (select 1 from public.fn_horarios_disponiveis(v_prof, v_fora, 60, null, true)) then
      raise exception 'FALHOU: com p_ignorar_janela=true (painel) deveria oferecer horarios';
    end if;
    raise notice 'OK: datas alem da janela sao recusadas (painel pode ignorar)';
  end;

  delete from public.agendamentos where profissional_id = v_prof and observacoes = 'TESTE_DISPONIBILIDADE';
  raise notice '=== DISPONIBILIDADE / CONFLITO / DURACAO: TODOS OS TESTES PASSARAM ===';
end $$;

rollback;
