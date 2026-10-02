-- ETAPA 7B — AGENDAMENTOS (a tabela mais importante) e AGENDAMENTO_EVENTOS
-- Referência: etapa-7a-arquitetura.md, seções 2.9 e 2.10

create table public.agendamentos (
  id                        uuid primary key default gen_random_uuid(),
  profissional_id           uuid not null references public.profissionais(id),
  numero                    bigint, -- nulo até confirmar; ver fn_proximo_numero_agendamento()

  cliente_id                uuid, -- nulo enquanto a reserva não foi paga
  cliente_nome_snap         text not null,
  cliente_whatsapp_snap     text not null,

  servico_id                uuid not null,
  servico_nome_snap         text not null,
  preco_centavos            integer not null,
  sinal_centavos            integer not null,
  duracao_min               integer not null,

  inicio_em                 timestamptz not null,
  fim_em                    timestamptz not null,

  status                    text not null default 'aguardando_pagamento',
  reserva_expira_em         timestamptz,

  confirmado_em             timestamptz,
  cancelado_em              timestamptz,
  cancelado_por             text,
  cancelamento_motivo       text,

  origem                    text not null default 'painel',
  observacoes               text,
  token_publico_hash        text,
  chave_idempotencia        text, -- opcional: retry/duplo clique da MESMA solicitação devolve a mesma reserva (7A 5.3 item 4)

  criado_em                 timestamptz not null default now(),
  atualizado_em             timestamptz not null default now(),

  constraint agendamentos_status_valido check (
    status in ('aguardando_pagamento','confirmado','em_atendimento','concluido','cancelado','faltou','expirado')
  ),
  constraint agendamentos_origem_valida check (origem in ('publico','painel')),
  constraint agendamentos_cancelado_por_valido check (
    cancelado_por is null or cancelado_por in ('cliente','profissional','sistema')
  ),
  constraint agendamentos_fim_apos_inicio check (fim_em > inicio_em),
  constraint agendamentos_valores_nao_negativos check (
    preco_centavos >= 0 and sinal_centavos >= 0 and sinal_centavos <= preco_centavos and duracao_min > 0
  ),
  -- Reserva aguardando pagamento precisa de prazo de expiração; as demais não.
  constraint agendamentos_expira_so_se_aguardando check (
    (status = 'aguardando_pagamento' and reserva_expira_em is not null)
    or (status <> 'aguardando_pagamento')
  ),

  -- FKs compostas (seção 3.1 item 3): o banco recusa ligar um agendamento
  -- da profissional A a um cliente/serviço da profissional B, mesmo com bug no código.
  constraint agendamentos_cliente_mesmo_tenant
    foreign key (profissional_id, cliente_id) references public.clientes (profissional_id, id) on delete restrict,
  constraint agendamentos_servico_mesmo_tenant
    foreign key (profissional_id, servico_id) references public.servicos (profissional_id, id) on delete restrict
);

-- Serviço/cliente usado em agendamento não pode ser fisicamente apagado:
-- a FK composta acima é ON DELETE RESTRICT explícito (auditoria 7B: antes dependia do padrão NO ACTION).

-- Único por profissional (números não se repetem, nem entre profissionais diferentes
-- terem o mesmo número visual — cada uma tem sua própria sequência).
create unique index agendamentos_numero_unico_por_profissional
  on public.agendamentos (profissional_id, numero) where numero is not null;

-- Idempotência da criação de reserva (7A 5.3 item 4): mesma chave, mesma profissional
-- => no máximo uma reserva. Chaves nulas não participam (criação sem idempotência).
create unique index agendamentos_idempotencia_unica
  on public.agendamentos (profissional_id, chave_idempotencia) where chave_idempotencia is not null;

-- Chave única composta: permite que outras tabelas (pagamentos, agendamento_eventos,
-- transacoes_financeiras)
-- referenciem (profissional_id, id) com FK composta, garantindo mesmo tenant.
alter table public.agendamentos add constraint agendamentos_pid_id_unico unique (profissional_id, id);

-- ---------------------------------------------------------------------
-- A PROTEÇÃO CRÍTICA CONTRA DUPLA RESERVA (requisito 10 da etapa 7B).
-- Reproduz exatamente act()+ov() do protótipo: dois agendamentos do MESMO
-- profissional não podem ter períodos [inicio_em, fim_em) sobrepostos
-- enquanto ambos estiverem em status "ocupante". Isso é garantido pelo
-- PRÓPRIO BANCO — nenhuma verificação prévia no servidor é suficiente
-- sozinha, esta é a barreira final que nunca falha, mesmo sob concorrência.
--
-- AUDITORIA 7B: inicio_em/fim_em são timestamptz, então o intervalo TEM que ser
-- tstzrange. tsrange(timestamptz, ...) exigiria converter timestamptz -> timestamp,
-- conversão que depende do TimeZone da sessão (não é imutável) e não é aceita
-- numa expressão de índice/constraint. tstzrange compara INSTANTES absolutos,
-- independentemente do fuso da sessão. '[)' = início inclusivo, fim exclusivo,
-- logo horários exatamente encostados (14–15 e 15–16) NÃO conflitam.
--
-- RESERVAS EXPIRADAS: a constraint NÃO usa now() (expressão volátil não serve em
-- índice/constraint). A estratégia é estática, como na 7A seção 6: a reserva vencida
-- vira status 'expirado' (que não está na lista abaixo) por (a) rotina de expiração,
-- (b) fn_criar_reserva e (c) o trigger trg_agendamentos_liberar_expiradas
-- (migração 20260930120008), que expira vencidas conflitantes antes de qualquer
-- INSERT/UPDATE de horário ocupante.
-- ---------------------------------------------------------------------
alter table public.agendamentos
  add constraint agendamentos_sem_sobreposicao
  exclude using gist (
    profissional_id with =,
    tstzrange(inicio_em, fim_em, '[)') with &&
  )
  where (status in ('aguardando_pagamento','confirmado','em_atendimento','concluido','faltou'));

create index agendamentos_agenda_idx on public.agendamentos (profissional_id, inicio_em);
create index agendamentos_expiracao_idx on public.agendamentos (profissional_id, status, reserva_expira_em);
create index agendamentos_historico_cliente_idx on public.agendamentos (profissional_id, cliente_id, inicio_em);

create trigger trg_agendamentos_atualizado_em
  before update on public.agendamentos
  for each row execute function public.fn_atualiza_timestamp();

comment on table public.agendamentos is
  'O compromisso: quem, o quê, quando, em que estado. Preço/sinal/duração são cópias do serviço no momento da reserva (não dependem do preço atual).';
comment on constraint agendamentos_sem_sobreposicao on public.agendamentos is
  'Proteção contra dupla reserva NO BANCO (tstzrange, [) ). Requer extensão btree_gist (migração 20260930120000). Reservas vencidas deixam de ocupar ao virar expirado (sem now() na constraint).';

-- ---------------------------------------------------------------------
-- AGENDAMENTO_EVENTOS (auditoria) — seção 2.10
-- ---------------------------------------------------------------------
create table public.agendamento_eventos (
  id               uuid primary key default gen_random_uuid(),
  profissional_id  uuid not null references public.profissionais(id),
  agendamento_id   uuid not null,
  tipo             text not null,
  dados            jsonb,
  ator             text not null,
  criado_em        timestamptz not null default now(),
  constraint agendamento_eventos_tipo_valido check (
    tipo in ('criado','pago','confirmado','reagendado','cancelado','faltou','concluido','expirado','sinal_manual')
  ),
  constraint agendamento_eventos_ator_valido check (
    ator in ('profissional','cliente','sistema','webhook')
  ),
  -- AUDITORIA 7B: FK composta — um evento da profissional A nunca aponta para
  -- agendamento da profissional B (antes era FK simples por agendamento_id).
  constraint agendamento_eventos_agendamento_mesmo_tenant
    foreign key (profissional_id, agendamento_id) references public.agendamentos (profissional_id, id)
);

create index agendamento_eventos_agendamento_idx on public.agendamento_eventos (agendamento_id, criado_em);

comment on table public.agendamento_eventos is
  'Trilha imutável de tudo que acontece com um agendamento. Nunca é editada ou apagada (trigger trg_agendamento_eventos_imutavel, migração 20260930120008).';
