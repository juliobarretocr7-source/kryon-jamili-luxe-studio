-- ETAPA 7B — Row Level Security (isolamento multi-tenant)
-- Referência: etapa-7a-arquitetura.md, seção 3
--
-- auth.uid() é fornecido pelo Supabase Auth em produção (schema "auth" já
-- existe no projeto Supabase real). Esta migração NÃO cria auth.uid():
-- ela só é criada, como stub condicional, nos testes locais sem Supabase rodando
-- (ver supabase/tests/00_stub_auth_local.sql).
--
-- AUDITORIA 7B — o que mudou em relação à primeira versão desta migration:
--  * Antes: uma policy "FOR ALL ... TO PUBLIC" por tabela. Isolava por tenant, mas
--    deixava a profissional (via API com a chave anon + login) apagar o próprio
--    cadastro/vínculo, alterar/apagar eventos de auditoria e o livro-caixa, e gravar
--    pagamentos "aprovados" direto do navegador (7A seção 7: confirmação só pelo servidor).
--  * Agora: policies por comando e restritas ao papel "authenticated".
--    O papel "anon" não tem NENHUMA policy (nada acessível sem login; a área pública
--    é escopo da etapa 7H, com funções estreitas).
--  * Escritas reservadas ao servidor (papel de serviço, que contorna RLS): criar/remover
--    profissionais e usuários, gravar pagamentos, apagar qualquer coisa imutável.
--  * NÃO usamos FORCE ROW LEVEL SECURITY: fn_profissional_atual() (SECURITY DEFINER,
--    dono da tabela) precisa ler "usuarios" sem ser filtrada pela própria policy.

create or replace function public.fn_profissional_atual()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select profissional_id from public.usuarios where id = auth.uid() and ativo;
$$;

comment on function public.fn_profissional_atual() is
  'Descobre o profissional do usuário autenticado pela sessão. Nunca aceita profissional_id vindo do navegador (seção 3.1 item 2 da 7A).';

-- ---------------------------------------------------------------------
-- Habilita RLS em TODAS as tabelas de negócio.
-- ---------------------------------------------------------------------
alter table public.profissionais          enable row level security;
alter table public.usuarios               enable row level security;
alter table public.configuracoes          enable row level security;
alter table public.horarios_funcionamento enable row level security;
alter table public.intervalos             enable row level security;
alter table public.servicos               enable row level security;
alter table public.clientes               enable row level security;
alter table public.agendamentos           enable row level security;
alter table public.agendamento_eventos    enable row level security;
alter table public.pagamentos             enable row level security;
alter table public.transacoes_financeiras enable row level security;

-- ---------------------------------------------------------------------
-- PROFISSIONAIS: a profissional vê e edita só o próprio cadastro.
-- Sem INSERT/DELETE pelo navegador (cadastro = servidor, etapa 7C).
-- ---------------------------------------------------------------------
create policy profissionais_select on public.profissionais
  for select to authenticated using (id = public.fn_profissional_atual());
create policy profissionais_update on public.profissionais
  for update to authenticated
  using (id = public.fn_profissional_atual())
  with check (id = public.fn_profissional_atual());

-- ---------------------------------------------------------------------
-- USUARIOS: só leitura dos vínculos do próprio tenant. Criar/alterar/remover
-- usuário (inclusive papel e ativo) é operação de servidor — evita auto-promoção,
-- auto-reativação e "trancar a própria conta para fora".
-- ---------------------------------------------------------------------
create policy usuarios_select on public.usuarios
  for select to authenticated using (profissional_id = public.fn_profissional_atual());

-- ---------------------------------------------------------------------
-- CONFIGURACOES: leitura e edição. Sem INSERT/DELETE (nascem com o cadastro).
-- ---------------------------------------------------------------------
create policy configuracoes_select on public.configuracoes
  for select to authenticated using (profissional_id = public.fn_profissional_atual());
create policy configuracoes_update on public.configuracoes
  for update to authenticated
  using (profissional_id = public.fn_profissional_atual())
  with check (profissional_id = public.fn_profissional_atual());

-- ---------------------------------------------------------------------
-- Tabelas operacionais com CRUD completo dentro do próprio tenant.
-- ---------------------------------------------------------------------
create policy horarios_select on public.horarios_funcionamento
  for select to authenticated using (profissional_id = public.fn_profissional_atual());
create policy horarios_insert on public.horarios_funcionamento
  for insert to authenticated with check (profissional_id = public.fn_profissional_atual());
create policy horarios_update on public.horarios_funcionamento
  for update to authenticated
  using (profissional_id = public.fn_profissional_atual())
  with check (profissional_id = public.fn_profissional_atual());
create policy horarios_delete on public.horarios_funcionamento
  for delete to authenticated using (profissional_id = public.fn_profissional_atual());

create policy intervalos_select on public.intervalos
  for select to authenticated using (profissional_id = public.fn_profissional_atual());
create policy intervalos_insert on public.intervalos
  for insert to authenticated with check (profissional_id = public.fn_profissional_atual());
create policy intervalos_update on public.intervalos
  for update to authenticated
  using (profissional_id = public.fn_profissional_atual())
  with check (profissional_id = public.fn_profissional_atual());
create policy intervalos_delete on public.intervalos
  for delete to authenticated using (profissional_id = public.fn_profissional_atual());

create policy servicos_select on public.servicos
  for select to authenticated using (profissional_id = public.fn_profissional_atual());
create policy servicos_insert on public.servicos
  for insert to authenticated with check (profissional_id = public.fn_profissional_atual());
create policy servicos_update on public.servicos
  for update to authenticated
  using (profissional_id = public.fn_profissional_atual())
  with check (profissional_id = public.fn_profissional_atual());
create policy servicos_delete on public.servicos
  for delete to authenticated using (profissional_id = public.fn_profissional_atual());

create policy clientes_select on public.clientes
  for select to authenticated using (profissional_id = public.fn_profissional_atual());
create policy clientes_insert on public.clientes
  for insert to authenticated with check (profissional_id = public.fn_profissional_atual());
create policy clientes_update on public.clientes
  for update to authenticated
  using (profissional_id = public.fn_profissional_atual())
  with check (profissional_id = public.fn_profissional_atual());
create policy clientes_delete on public.clientes
  for delete to authenticated using (profissional_id = public.fn_profissional_atual());

-- ---------------------------------------------------------------------
-- AGENDAMENTOS: sem DELETE (7A 5.5: cancelar = mudar status, nunca apagar).
-- ---------------------------------------------------------------------
create policy agendamentos_select on public.agendamentos
  for select to authenticated using (profissional_id = public.fn_profissional_atual());
create policy agendamentos_insert on public.agendamentos
  for insert to authenticated with check (profissional_id = public.fn_profissional_atual());
create policy agendamentos_update on public.agendamentos
  for update to authenticated
  using (profissional_id = public.fn_profissional_atual())
  with check (profissional_id = public.fn_profissional_atual());

-- ---------------------------------------------------------------------
-- AGENDAMENTO_EVENTOS e TRANSACOES_FINANCEIRAS (imutáveis): só ler e acrescentar.
-- Além disso há triggers que bloqueiam UPDATE/DELETE/TRUNCATE (migração 20260930120008).
-- ---------------------------------------------------------------------
create policy agendamento_eventos_select on public.agendamento_eventos
  for select to authenticated using (profissional_id = public.fn_profissional_atual());
create policy agendamento_eventos_insert on public.agendamento_eventos
  for insert to authenticated with check (profissional_id = public.fn_profissional_atual());

create policy transacoes_select on public.transacoes_financeiras
  for select to authenticated using (profissional_id = public.fn_profissional_atual());
create policy transacoes_insert on public.transacoes_financeiras
  for insert to authenticated with check (profissional_id = public.fn_profissional_atual());

-- ---------------------------------------------------------------------
-- PAGAMENTOS: só leitura pelo navegador. Quem grava/aprova pagamento é o servidor
-- (webhook validado, etapa 7I) com o papel de serviço (contorna RLS por natureza).
-- ---------------------------------------------------------------------
create policy pagamentos_select on public.pagamentos
  for select to authenticated using (profissional_id = public.fn_profissional_atual());

-- Observação sobre as funções fn_criar_reserva/fn_horarios_disponiveis: rodam como
-- SECURITY INVOKER (padrão). Quando chamadas por um usuário logado, o RLS acima se aplica
-- a tudo que elas leem/gravam. A chamada pelo papel "anon" (página pública) fica para a
-- etapa 7H, com função própria e projeção mínima — por ora anon não tem acesso a nada.
