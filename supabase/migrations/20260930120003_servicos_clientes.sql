-- ETAPA 7B — SERVICOS e CLIENTES
-- Referência: etapa-7a-arquitetura.md, seções 2.7 e 2.8

create table public.servicos (
  id                uuid primary key default gen_random_uuid(),
  profissional_id   uuid not null references public.profissionais(id),
  nome              text not null,
  descricao         text,
  preco_centavos    integer not null,
  duracao_min       integer not null,
  sinal_centavos    integer not null default 0,
  ativo             boolean not null default true,
  ordem             integer not null default 0,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  constraint servicos_nome_nao_vazio check (btrim(nome) <> ''),
  constraint servicos_preco_nao_negativo check (preco_centavos >= 0),
  constraint servicos_duracao_positiva check (duracao_min > 0),
  constraint servicos_sinal_nao_maior_que_preco check (sinal_centavos >= 0 and sinal_centavos <= preco_centavos)
);

-- Chave única composta (profissional_id, id): é o que permite a FK composta
-- de AGENDAMENTOS (seção 3.1 item 3 da 7A) — o banco recusa ligar um
-- agendamento da profissional A a um serviço da profissional B.
alter table public.servicos add constraint servicos_pid_id_unico unique (profissional_id, id);

create index servicos_listagem_idx on public.servicos (profissional_id, ativo, ordem);

create trigger trg_servicos_atualizado_em
  before update on public.servicos
  for each row execute function public.fn_atualiza_timestamp();

comment on table public.servicos is
  'Serviços oferecidos. Não pode ser excluído se usado em agendamento (FK RESTRICT em agendamentos.servico_id) — só desativado.';

-- ---------------------------------------------------------------------
-- CLIENTES
-- ---------------------------------------------------------------------
create table public.clientes (
  id                 uuid primary key default gen_random_uuid(),
  profissional_id    uuid not null references public.profissionais(id),
  nome               text not null,
  whatsapp           text not null,
  instagram          text,
  email              text,
  observacoes        text,
  consentimento_em   timestamptz,
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now(),
  constraint clientes_nome_nao_vazio check (btrim(nome) <> ''),
  constraint clientes_whatsapp_minimo check (length(regexp_replace(whatsapp, '\D', '', 'g')) >= 10)
);

-- Mesma pessoa em duas profissionais = duas linhas independentes (seção 2.8).
create unique index clientes_unico_por_profissional_whatsapp
  on public.clientes (profissional_id, whatsapp);

-- Chave única composta para permitir a FK composta de AGENDAMENTOS.
alter table public.clientes add constraint clientes_pid_id_unico unique (profissional_id, id);

create index clientes_busca_nome_idx on public.clientes (profissional_id, nome);

create trigger trg_clientes_atualizado_em
  before update on public.clientes
  for each row execute function public.fn_atualiza_timestamp();

comment on table public.clientes is
  'Clientes por profissional. Ligação com agendamentos é por cliente_id (não mais por telefone) — trocar o WhatsApp não reescreve o histórico.';
