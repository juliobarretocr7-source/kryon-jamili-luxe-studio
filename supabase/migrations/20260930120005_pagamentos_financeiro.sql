-- ETAPA 7B — PAGAMENTOS e TRANSACOES_FINANCEIRAS
-- Referência: etapa-7a-arquitetura.md, seções 2.11 e 2.12
-- Pagamento real (PIX) é etapa 7I; aqui só a estrutura, com provedor 'simulado' para dev/teste.

create table public.pagamentos (
  id                     uuid primary key default gen_random_uuid(),
  profissional_id        uuid not null references public.profissionais(id),
  agendamento_id         uuid not null,
  finalidade             text not null default 'sinal',
  valor_centavos         integer not null,
  provedor               text not null,
  provedor_pagamento_id  text,
  metodo                 text not null default 'pix',
  status                 text not null default 'pendente',
  pix_copia_cola         text,
  pix_expira_em          timestamptz,
  chave_idempotencia     text not null,
  aprovado_em            timestamptz,
  criado_em              timestamptz not null default now(),
  atualizado_em          timestamptz not null default now(),
  constraint pagamentos_finalidade_valida check (finalidade in ('sinal','restante')),
  constraint pagamentos_metodo_valido check (metodo in ('pix')),
  constraint pagamentos_status_valido check (
    status in ('pendente','aprovado','recusado','expirado','cancelado','estornado')
  ),
  constraint pagamentos_valor_positivo check (valor_centavos > 0),
  -- AUDITORIA 7B: FK composta — pagamento da profissional A nunca aponta para
  -- agendamento da profissional B (antes era FK simples por agendamento_id).
  constraint pagamentos_agendamento_mesmo_tenant
    foreign key (profissional_id, agendamento_id) references public.agendamentos (profissional_id, id)
);

-- Chave única composta: permite FK composta de transacoes_financeiras -> pagamentos.
alter table public.pagamentos add constraint pagamentos_pid_id_unico unique (profissional_id, id);

-- Evita cobrança duplicada por duplo clique/retry de rede.
create unique index pagamentos_idempotencia_unica on public.pagamentos (chave_idempotencia);
-- Idempotência do lado do gateway: mesmo pagamento não é registrado duas vezes.
create unique index pagamentos_provedor_id_unico
  on public.pagamentos (provedor, provedor_pagamento_id) where provedor_pagamento_id is not null;

create index pagamentos_agendamento_idx on public.pagamentos (agendamento_id);
create index pagamentos_status_idx on public.pagamentos (profissional_id, status);

create trigger trg_pagamentos_atualizado_em
  before update on public.pagamentos
  for each row execute function public.fn_atualiza_timestamp();

comment on table public.pagamentos is
  'Cada tentativa de cobrança no gateway (o que o gateway diz). Provedor "simulado" existe só para dev/teste (nunca em produção, seção 7.2 da 7A).';

-- ---------------------------------------------------------------------
-- TRANSACOES_FINANCEIRAS (livro-caixa, imutável)
-- ---------------------------------------------------------------------
create table public.transacoes_financeiras (
  id                     uuid primary key default gen_random_uuid(),
  profissional_id        uuid not null references public.profissionais(id),
  tipo                   text not null,
  origem                 text not null,
  categoria              text not null,
  descricao              text,
  valor_centavos         integer not null,
  metodo                 text not null,
  ocorrido_em            timestamptz not null default now(),
  data_local             date not null,
  agendamento_id         uuid,
  pagamento_id           uuid,
  estorna_transacao_id   uuid,
  criado_em              timestamptz not null default now(),
  constraint transacoes_tipo_valido check (tipo in ('entrada','saida')),
  constraint transacoes_origem_valida check (origem in ('sinal','restante','manual','estorno')),
  constraint transacoes_valor_positivo check (valor_centavos > 0),
  constraint transacoes_agendamento_mesmo_tenant
    foreign key (profissional_id, agendamento_id) references public.agendamentos (profissional_id, id)
);

-- AUDITORIA 7B: chave única composta + FKs compostas. Antes, pagamento_id e
-- estorna_transacao_id eram FKs simples (permitiam ligar a profissional A a
-- pagamento/lançamento da profissional B). A unique vem ANTES das FKs que a usam.
alter table public.transacoes_financeiras
  add constraint transacoes_pid_id_unico unique (profissional_id, id);
alter table public.transacoes_financeiras
  add constraint transacoes_pagamento_mesmo_tenant
    foreign key (profissional_id, pagamento_id) references public.pagamentos (profissional_id, id);
alter table public.transacoes_financeiras
  add constraint transacoes_estorno_mesmo_tenant
    foreign key (profissional_id, estorna_transacao_id) references public.transacoes_financeiras (profissional_id, id);

-- Um pagamento aprovado gera no máximo uma entrada financeira.
create unique index transacoes_pagamento_unico on public.transacoes_financeiras (pagamento_id) where pagamento_id is not null;

create index transacoes_periodo_idx on public.transacoes_financeiras (profissional_id, data_local);
create index transacoes_agendamento_idx on public.transacoes_financeiras (agendamento_id);

comment on table public.transacoes_financeiras is
  'Livro-caixa imutável: nunca é editado nem apagado (paridade com o protótipo; trigger trg_transacoes_imutavel, migração 20260930120008). Correção = novo lançamento de estorno.';
