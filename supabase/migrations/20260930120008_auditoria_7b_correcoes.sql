-- ETAPA 7B — AUDITORIA E CORREÇÃO FINAL DA FUNDAÇÃO
-- Migration corretiva/aditiva. As correções que mudam a DEFINIÇÃO de tabelas/funções/policies
-- (tstzrange, FKs compostas, idempotência, RLS granular, janela) foram feitas nas migrations
-- originais 004–007, porque a fundação 7B ainda não tem histórico publicado. Esta migration
-- reúne o que é puramente ADITIVO: imutabilidade, liberação de reservas vencidas no banco,
-- regra do número e endurecimento de permissões.

-- ---------------------------------------------------------------------
-- 1) IMUTABILIDADE de agendamento_eventos e transacoes_financeiras (7A 2.10 e 2.12).
--    Triggers de linha (UPDATE/DELETE) + de comando (TRUNCATE). Valem para QUALQUER papel,
--    inclusive o dono das tabelas; só quem é superuser/dono pode desligar o trigger
--    deliberadamente (manutenção), nunca a API. Sem "chave mestra" por configuração de
--    sessão: um GUC qualquer poderia ser ligado pelo próprio atacante.
-- ---------------------------------------------------------------------
create or replace function public.fn_bloquear_alteracao_imutavel()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Tabela % é imutável: % não é permitido (correção = novo registro).',
    tg_table_name, tg_op
    using errcode = 'restrict_violation'; -- 23001
end;
$$;

comment on function public.fn_bloquear_alteracao_imutavel() is
  'Bloqueia UPDATE/DELETE/TRUNCATE em tabelas de trilha/livro-caixa.';

create trigger trg_agendamento_eventos_imutavel
  before update or delete on public.agendamento_eventos
  for each row execute function public.fn_bloquear_alteracao_imutavel();
create trigger trg_agendamento_eventos_sem_truncate
  before truncate on public.agendamento_eventos
  for each statement execute function public.fn_bloquear_alteracao_imutavel();

create trigger trg_transacoes_imutavel
  before update or delete on public.transacoes_financeiras
  for each row execute function public.fn_bloquear_alteracao_imutavel();
create trigger trg_transacoes_sem_truncate
  before truncate on public.transacoes_financeiras
  for each statement execute function public.fn_bloquear_alteracao_imutavel();

-- ---------------------------------------------------------------------
-- 2) RESERVAS EXPIRADAS x EXCLUDE constraint.
--    A constraint não usa now() (impossível: expressão não imutável). A estratégia da 7A
--    (status 'expirado' gravado) já cobre fn_criar_reserva; este trigger fecha a lacuna dos
--    OUTROS caminhos que gravam horário ocupante (INSERT pelo painel, reagendamento por
--    UPDATE, confirmação): antes de a linha entrar, reservas aguardando_pagamento JÁ
--    VENCIDAS que colidem com o novo período viram 'expirado'. Reservas NÃO vencidas
--    continuam bloqueando (e a EXCLUDE recusa normalmente).
--    A EXCLUDE é verificada depois dos triggers BEFORE, então já enxerga a linha expirada.
-- ---------------------------------------------------------------------
create or replace function public.fn_liberar_reservas_vencidas_conflitantes()
returns trigger
language plpgsql
as $$
declare
  v_ids uuid[];
begin
  with expiradas as (
    update public.agendamentos a
    set status = 'expirado'
    where a.profissional_id = new.profissional_id
      and a.id <> new.id
      and a.status = 'aguardando_pagamento'
      and a.reserva_expira_em < now()
      and tstzrange(a.inicio_em, a.fim_em, '[)') && tstzrange(new.inicio_em, new.fim_em, '[)')
    returning a.id
  )
  select coalesce(array_agg(id), '{}') into v_ids from expiradas;

  if coalesce(array_length(v_ids, 1), 0) > 0 then
    insert into public.agendamento_eventos (profissional_id, agendamento_id, tipo, ator, dados)
    select a.profissional_id, a.id, 'expirado', 'sistema',
           jsonb_build_object('motivo', 'prazo_da_reserva_vencido', 'liberado_por', 'trigger_conflito')
    from public.agendamentos a
    where a.id = any(v_ids);
  end if;

  return new;
end;
$$;

comment on function public.fn_liberar_reservas_vencidas_conflitantes() is
  'Expira, antes de um INSERT/UPDATE de horário ocupante, as reservas vencidas que colidiriam com ele. Complementa (não substitui) a EXCLUDE constraint.';

create trigger trg_agendamentos_liberar_expiradas
  before insert or update of profissional_id, inicio_em, fim_em, status on public.agendamentos
  for each row
  when (new.status in ('aguardando_pagamento','confirmado','em_atendimento','concluido','faltou'))
  execute function public.fn_liberar_reservas_vencidas_conflitantes();

-- ---------------------------------------------------------------------
-- 3) NÚMERO DO AGENDAMENTO: só existe em agendamento que chegou a ser confirmado.
--    (Reforça a regra da 7A seção 8 no banco; não altera sequência nem formato.)
-- ---------------------------------------------------------------------
alter table public.agendamentos
  add constraint agendamentos_numero_so_confirmado
  check (numero is null or (confirmado_em is not null and numero >= 1));

-- ---------------------------------------------------------------------
-- 4) PERMISSÕES de execução / acesso (endurecimento; o RLS continua sendo a barreira principal).
--    Em Supabase os papéis anon/authenticated/service_role existem e recebem privilégios
--    padrão; em Postgres puro (testes locais) não existem, por isso o bloco é condicional.
-- ---------------------------------------------------------------------
-- Número sequencial: só o servidor (na transação de confirmação) — a profissional logada
-- não deve poder "queimar" números chamando a função direto.
revoke all on function public.fn_proximo_numero_agendamento(uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function public.fn_proximo_numero_agendamento(uuid) from anon;
    revoke all on function public.fn_expirar_reservas_vencidas(uuid) from anon;
    revoke all on function public.fn_criar_reserva(uuid, uuid, text, text, date, integer, text, text) from anon;
    revoke all on function public.fn_horarios_disponiveis(uuid, date, integer, uuid, boolean) from anon;
    revoke all on all tables in schema public from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on function public.fn_proximo_numero_agendamento(uuid) from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.fn_proximo_numero_agendamento(uuid) to service_role;
  end if;
end $$;
