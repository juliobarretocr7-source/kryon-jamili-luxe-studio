-- ETAPA 7B — PROFISSIONAIS (o tenant) e USUARIOS (vínculo com autenticação)
-- Referência: etapa-7a-arquitetura.md, seções 2.1 e 2.2

create table public.profissionais (
  id                 uuid primary key default gen_random_uuid(),
  slug               text not null,
  nome_studio        text not null,
  nome_profissional  text not null,
  whatsapp           text,
  endereco           text,
  fuso_horario       text not null default 'America/Sao_Paulo',
  status             text not null default 'ativo',
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now(),
  constraint profissionais_status_valido
    check (status in ('ativo','pausado','suspenso')),
  constraint profissionais_slug_formato
    check (slug ~ '^[a-z0-9-]+$')
);

create unique index profissionais_slug_unico on public.profissionais (slug);

create trigger trg_profissionais_atualizado_em
  before update on public.profissionais
  for each row execute function public.fn_atualiza_timestamp();

comment on table public.profissionais is
  'Raiz do isolamento multi-tenant. Cada studio/profissional é uma linha aqui.';

-- ---------------------------------------------------------------------
-- USUARIOS: vincula quem faz login (Supabase Auth) a um profissional.
-- Nunca guarda senha/hash: isso fica só no auth.users do Supabase.
-- O id desta tabela É o id do usuário no auth.users (1:1).
-- ---------------------------------------------------------------------
create table public.usuarios (
  id                uuid primary key, -- = auth.users.id, sem default: vem do cadastro
  profissional_id   uuid not null references public.profissionais(id),
  nome              text,
  email             text not null,
  papel             text not null default 'dono',
  ativo             boolean not null default true,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  constraint usuarios_papel_valido check (papel in ('dono','equipe'))
);

create index usuarios_profissional_id_idx on public.usuarios (profissional_id);
create unique index usuarios_email_unico on public.usuarios (email);

create trigger trg_usuarios_atualizado_em
  before update on public.usuarios
  for each row execute function public.fn_atualiza_timestamp();

comment on table public.usuarios is
  'Vínculo 1:1 (hoje) entre usuário autenticado (auth.users) e profissional. Preparada para papel=equipe no futuro.';
