-- ETAPA 7B — Funções de negócio que vivem no banco
-- Referência: etapa-7a-arquitetura.md, seções 5.2, 5.3, 6, 8
--
-- AUDITORIA 7B (resumo das mudanças nesta migration, ainda sem histórico publicado):
--  * fn_expirar_reservas_vencidas: passa a gravar o evento 'expirado' (7A 2.10/6).
--  * fn_horarios_disponiveis: passa a recusar datas além da janela de agendamento
--    (7A 5.2 "datas fora dela são recusadas"; antes a configuração existia mas nada a aplicava).
--  * fn_criar_reserva: idempotência real (chave por profissional) e tratamento de
--    unique_violation/exclusion_violation sem perder a garantia do banco.
--  * A numeração (fn_proximo_numero_agendamento) NÃO foi alterada.

-- ---------------------------------------------------------------------
-- 1) Número sequencial por profissional, atribuído só na confirmação.
--    SELECT ... FOR UPDATE trava a linha de configuracoes durante a
--    transação: duas confirmações simultâneas nunca recebem o mesmo número.
-- ---------------------------------------------------------------------
create or replace function public.fn_proximo_numero_agendamento(p_profissional_id uuid)
returns bigint
language plpgsql
as $$
declare
  v_numero bigint;
begin
  select proximo_numero_agendamento into v_numero
  from public.configuracoes
  where profissional_id = p_profissional_id
  for update;

  if v_numero is null then
    raise exception 'Profissional % sem configuracoes', p_profissional_id;
  end if;

  update public.configuracoes
  set proximo_numero_agendamento = v_numero + 1
  where profissional_id = p_profissional_id;

  return v_numero;
end;
$$;

comment on function public.fn_proximo_numero_agendamento(uuid) is
  'Devolve o próximo número (#000001...) da profissional com lock de linha. Deve ser chamada NA MESMA TRANSAÇÃO da confirmação (se ela falhar, o número volta atrás). Execução restrita ao papel de serviço (migração 20260930120008).';

-- ---------------------------------------------------------------------
-- 2) Expira reservas vencidas. Chamada (a) por rotina agendada a cada
--    minuto e (b) dentro da criação de reserva, para o horário pedido,
--    antes de checar disponibilidade (seção 6 da 7A).
--    Em dois passos (UPDATE e depois INSERT do evento) para o evento só
--    ser gravado depois de o novo estado do agendamento existir.
-- ---------------------------------------------------------------------
create or replace function public.fn_expirar_reservas_vencidas(p_profissional_id uuid default null)
returns integer
language plpgsql
as $$
declare
  v_ids uuid[];
begin
  with expiradas as (
    update public.agendamentos
    set status = 'expirado'
    where status = 'aguardando_pagamento'
      and reserva_expira_em < now()
      and (p_profissional_id is null or profissional_id = p_profissional_id)
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from expiradas;

  insert into public.agendamento_eventos (profissional_id, agendamento_id, tipo, ator, dados)
  select a.profissional_id, a.id, 'expirado', 'sistema',
         jsonb_build_object('motivo', 'prazo_da_reserva_vencido')
  from public.agendamentos a
  where a.id = any(v_ids);

  return coalesce(array_length(v_ids, 1), 0);
end;
$$;

comment on function public.fn_expirar_reservas_vencidas(uuid) is
  'Marca como expirado toda reserva aguardando_pagamento cujo prazo passou (e grava o evento). Sem argumento = rotina global; com profissional_id = dentro da criação de reserva. É ISSO que libera o horário: a EXCLUDE constraint não usa now().';

-- ---------------------------------------------------------------------
-- 3) Disponibilidade (equivalente a free(date, dur, exclId) do protótipo).
--    Reaproveitada pelo backend de consulta E pela criação de reserva.
--    Retorna os horários de início (em minutos desde 00:00) livres para
--    a data e duração informadas.
--    p_ignorar_janela: o painel da profissional aceita qualquer data futura
--    (7A 1.8); a área pública respeita janela_agendamento_dias.
-- ---------------------------------------------------------------------
create or replace function public.fn_horarios_disponiveis(
  p_profissional_id uuid,
  p_data date,
  p_duracao_min integer,
  p_excluir_agendamento_id uuid default null,
  p_ignorar_janela boolean default false
)
returns table (inicio_min integer)
language plpgsql
stable
as $$
declare
  v_dia_semana smallint := extract(dow from p_data);
  v_abre integer;
  v_fecha integer;
  v_passo integer;
  v_antecedencia integer;
  v_janela integer;
  v_fuso text;
  v_agora_min integer;
  v_hoje date;
  v_s integer;
begin
  select c.passo_agenda_min, c.antecedencia_minima_min, c.janela_agendamento_dias, p.fuso_horario
  into v_passo, v_antecedencia, v_janela, v_fuso
  from public.configuracoes c
  join public.profissionais p on p.id = c.profissional_id
  where c.profissional_id = p_profissional_id;

  if v_passo is null then
    return; -- profissional sem configuração: nenhum horário
  end if;

  select abre_min, fecha_min into v_abre, v_fecha
  from public.horarios_funcionamento
  where profissional_id = p_profissional_id and dia_semana = v_dia_semana and ativo
  order by abre_min limit 1;

  if v_abre is null then
    return; -- dia fechado: nenhum horário (regra obrigatória da seção 1)
  end if;

  v_hoje := (now() at time zone v_fuso)::date;
  v_agora_min := extract(hour from (now() at time zone v_fuso))*60
               + extract(minute from (now() at time zone v_fuso));

  if p_data < v_hoje then
    return; -- dias passados recusados no servidor (seção 5.2 da 7A)
  end if;

  if not p_ignorar_janela and p_data > v_hoje + v_janela then
    return; -- fora da janela de agendamento (hoje + janela_agendamento_dias), seção 5.2 da 7A
  end if;

  for v_s in select generate_series(v_abre, v_fecha - p_duracao_min, v_passo) loop
    -- antecedência mínima, só se for hoje
    if p_data = v_hoje and v_s < v_agora_min + v_antecedencia then
      continue;
    end if;

    -- intervalo/almoço: nenhum serviço pode atravessá-lo
    if exists (
      select 1 from public.intervalos i
      where i.profissional_id = p_profissional_id and i.ativo
        and (i.dia_semana is null or i.dia_semana = v_dia_semana)
        and v_s < i.fim_min and (v_s + p_duracao_min) > i.inicio_min
    ) then
      continue;
    end if;

    -- conflito com agendamentos ocupantes do mesmo dia.
    -- Reserva aguardando_pagamento já vencida (reserva_expira_em <= now()) NÃO ocupa,
    -- mesmo que a rotina ainda não a tenha marcado como 'expirado'.
    if exists (
      select 1 from public.agendamentos a
      where a.profissional_id = p_profissional_id
        and a.id <> coalesce(p_excluir_agendamento_id, '00000000-0000-0000-0000-000000000000'::uuid)
        and a.status in ('aguardando_pagamento','confirmado','em_atendimento','concluido','faltou')
        and (a.status <> 'aguardando_pagamento' or a.reserva_expira_em > now())
        and a.inicio_em < ((p_data + (v_s + p_duracao_min) * interval '1 minute') at time zone v_fuso)
        and a.fim_em    > ((p_data + v_s * interval '1 minute') at time zone v_fuso)
    ) then
      continue;
    end if;

    inicio_min := v_s;
    return next;
  end loop;
end;
$$;

comment on function public.fn_horarios_disponiveis(uuid, date, integer, uuid, boolean) is
  'Equivalente a free() do protótipo. Só informativa: quem garante de fato é fn_criar_reserva (EXCLUDE constraint). Limitação conhecida: usa apenas o primeiro turno do dia (horarios_funcionamento permite vários no futuro).';

-- ---------------------------------------------------------------------
-- 4) Criar reserva — operação transacional única (seção 5.3 da 7A).
--    Expira reservas vencidas do profissional, confere disponibilidade
--    de novo dentro da transação e insere. A EXCLUDE constraint é a
--    barreira final se duas pessoas chegarem exatamente juntas.
--    Idempotência: com p_chave_idempotencia, repetir a MESMA chamada
--    (duplo clique, retry de rede) devolve a reserva já criada em vez
--    de criar outra ou falhar.
-- ---------------------------------------------------------------------
create or replace function public.fn_criar_reserva(
  p_profissional_id uuid,
  p_servico_id uuid,
  p_cliente_nome text,
  p_cliente_whatsapp text,
  p_data date,
  p_inicio_min integer,
  p_origem text default 'publico',
  p_chave_idempotencia text default null
)
returns public.agendamentos
language plpgsql
as $$
declare
  v_servico public.servicos%rowtype;
  v_fuso text;
  v_reserva_min integer;
  v_inicio timestamptz;
  v_fim timestamptz;
  v_novo public.agendamentos%rowtype;
begin
  -- Idempotência: mesma chave, mesma profissional => devolve a reserva existente.
  if p_chave_idempotencia is not null then
    select * into v_novo from public.agendamentos
    where profissional_id = p_profissional_id and chave_idempotencia = p_chave_idempotencia;
    if found then
      return v_novo;
    end if;
  end if;

  perform public.fn_expirar_reservas_vencidas(p_profissional_id);

  select * into v_servico from public.servicos
  where id = p_servico_id and profissional_id = p_profissional_id and ativo;
  if not found then
    raise exception 'Serviço inválido ou inativo' using errcode = 'P0001';
  end if;

  select fuso_horario into v_fuso from public.profissionais where id = p_profissional_id;
  select reserva_expira_min into v_reserva_min from public.configuracoes where profissional_id = p_profissional_id;

  v_inicio := (p_data + p_inicio_min * interval '1 minute') at time zone v_fuso;
  v_fim := v_inicio + (v_servico.duracao_min * interval '1 minute');

  if not exists (
    select 1 from public.fn_horarios_disponiveis(
      p_profissional_id, p_data, v_servico.duracao_min, null, (p_origem = 'painel')
    ) f
    where f.inicio_min = p_inicio_min
  ) then
    raise exception 'Esse horário acabou de ser reservado. Escolha outro horário.' using errcode = '23P01';
  end if;

  insert into public.agendamentos (
    profissional_id, cliente_nome_snap, cliente_whatsapp_snap,
    servico_id, servico_nome_snap, preco_centavos, sinal_centavos, duracao_min,
    inicio_em, fim_em, status, reserva_expira_em, origem, chave_idempotencia
  ) values (
    p_profissional_id, p_cliente_nome, p_cliente_whatsapp,
    p_servico_id, v_servico.nome, v_servico.preco_centavos, v_servico.sinal_centavos, v_servico.duracao_min,
    v_inicio, v_fim, 'aguardando_pagamento', now() + (v_reserva_min * interval '1 minute'), p_origem,
    p_chave_idempotencia
  ) returning * into v_novo;

  insert into public.agendamento_eventos (profissional_id, agendamento_id, tipo, ator, dados)
  values (p_profissional_id, v_novo.id, 'criado', case when p_origem = 'publico' then 'cliente' else 'profissional' end,
          jsonb_build_object('inicio_em', v_inicio, 'fim_em', v_fim));

  return v_novo;
exception
  when unique_violation then
    -- Corrida entre duas chamadas com a MESMA chave: a outra já gravou; devolve a dela.
    if p_chave_idempotencia is not null then
      select * into v_novo from public.agendamentos
      where profissional_id = p_profissional_id and chave_idempotencia = p_chave_idempotencia;
      if found then
        return v_novo;
      end if;
    end if;
    raise;
  when exclusion_violation then
    -- Se a colisão foi com a própria reserva da mesma chave (retry simultâneo), devolve-a.
    if p_chave_idempotencia is not null then
      select * into v_novo from public.agendamentos
      where profissional_id = p_profissional_id and chave_idempotencia = p_chave_idempotencia;
      if found then
        return v_novo;
      end if;
    end if;
    raise exception 'Esse horário acabou de ser reservado. Escolha outro horário.' using errcode = '23P01';
end;
$$;

comment on function public.fn_criar_reserva is
  'Operação transacional única de reserva (idempotente por chave opcional). A EXCLUDE constraint (agendamentos_sem_sobreposicao) é a garantia final contra dupla reserva simultânea.';
