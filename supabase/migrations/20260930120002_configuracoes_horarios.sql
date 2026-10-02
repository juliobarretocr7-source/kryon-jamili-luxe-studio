-- ETAPA 7B — CONFIGURACOES (1:1 com profissional), HORARIOS_FUNCIONAMENTO, INTERVALOS
-- Referência: etapa-7a-arquitetura.md, seções 2.3, 2.4, 2.5

create table public.configuracoes (
  profissional_id            uuid primary key references public.profissionais(id),
  antecedencia_minima_min    integer not null default 0,
  janela_agendamento_dias    integer not null default 21,
  passo_agenda_min           integer not null default 30,
  reserva_expira_min         integer not null default 10,
  sinal_modo                 text not null default 'fixo',
  sinal_fixo_centavos        integer not null default 5000,
  politica_cancelamento      text not null default 'Cancelamentos com menos de 24 horas podem resultar na perda do sinal.',
  proximo_numero_agendamento bigint not null default 1,
  criado_em                  timestamptz not null default now(),
  atualizado_em              timestamptz not null default now(),
  constraint configuracoes_sinal_modo_valido check (sinal_modo in ('fixo','por_servico')),
  constraint configuracoes_valores_positivos check (
    antecedencia_minima_min >= 0 and janela_agendamento_dias > 0
    and passo_agenda_min > 0 and reserva_expira_min > 0
    and sinal_fixo_centavos >= 0 and proximo_numero_agendamento >= 1
  )
);

create trigger trg_configuracoes_atualizado_em
  before update on public.configuracoes
  for each row execute function public.fn_atualiza_timestamp();

comment on table public.configuracoes is
  'Regras operacionais por profissional. Equivalente a cfg + constantes fixas do protótipo (S.cfg, HOLD, SINAL, janela de 21 dias, passo de 30min).';
comment on column public.configuracoes.proximo_numero_agendamento is
  'Contador atômico do número visível (#000001). Incrementado via fn_proximo_numero_agendamento() com lock de linha.';

-- ---------------------------------------------------------------------
-- HORARIOS_FUNCIONAMENTO: expediente semanal (equivalente a S.hrs[7])
-- Dia sem linha = fechado ("Folga"), igual ao protótipo (hrs[d]===null).
-- ---------------------------------------------------------------------
create table public.horarios_funcionamento (
  id                uuid primary key default gen_random_uuid(),
  profissional_id   uuid not null references public.profissionais(id),
  dia_semana        smallint not null,
  abre_min          smallint not null,
  fecha_min         smallint not null,
  ativo             boolean not null default true,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  constraint horarios_dia_semana_valido check (dia_semana between 0 and 6),
  constraint horarios_fecha_apos_abre check (fecha_min > abre_min),
  constraint horarios_minutos_validos check (abre_min >= 0 and fecha_min <= 1440)
);

-- Permite, no futuro, dois turnos no mesmo dia (não duplica o mesmo início).
create unique index horarios_unico_por_dia_e_inicio
  on public.horarios_funcionamento (profissional_id, dia_semana, abre_min);

create trigger trg_horarios_atualizado_em
  before update on public.horarios_funcionamento
  for each row execute function public.fn_atualiza_timestamp();

comment on table public.horarios_funcionamento is
  'Expediente semanal. dia_semana: 0=domingo ... 6=sábado (igual ao protótipo). Dia sem nenhuma linha = fechado.';

-- ---------------------------------------------------------------------
-- INTERVALOS: pausas/almoço (equivalente a S.brk, hoje um único intervalo
-- global no protótipo; aqui já preparado para mais de um e por dia).
-- ---------------------------------------------------------------------
create table public.intervalos (
  id                uuid primary key default gen_random_uuid(),
  profissional_id   uuid not null references public.profissionais(id),
  dia_semana        smallint, -- null = vale para todos os dias (igual ao intervalo global de hoje)
  inicio_min        smallint not null,
  fim_min           smallint not null,
  descricao         text,
  ativo             boolean not null default true,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  constraint intervalos_dia_semana_valido check (dia_semana is null or dia_semana between 0 and 6),
  constraint intervalos_fim_apos_inicio check (fim_min > inicio_min)
);

create index intervalos_profissional_idx on public.intervalos (profissional_id);

create trigger trg_intervalos_atualizado_em
  before update on public.intervalos
  for each row execute function public.fn_atualiza_timestamp();

comment on table public.intervalos is
  'Pausas dentro do expediente (equivalente a S.brk). dia_semana nulo = vale todo dia, reproduzindo o comportamento atual do protótipo.';
