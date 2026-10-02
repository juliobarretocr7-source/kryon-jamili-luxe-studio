-- ETAPA 7B — Dados de desenvolvimento
-- Jamili espelha exatamente o seed() do protótipo (mesmos serviços/horários).
-- "Profissional B" existe só para provar isolamento multi-tenant (seção 3.2 item "Testes").
--
-- Em produção real, profissionais/usuarios nascem no fluxo de cadastro (etapa 7C),
-- com o id do usuário vindo do Supabase Auth. Aqui inserimos direto para dev/teste.

insert into public.profissionais (id, slug, nome_studio, nome_profissional, whatsapp, fuso_horario, status)
values
  ('11111111-1111-1111-1111-111111111111', 'jamili', 'Luxe Studio', 'Jamili', '5577999990000', 'America/Sao_Paulo', 'ativo'),
  ('22222222-2222-2222-2222-222222222222', 'profissional-b-teste', 'Studio B (teste)', 'Profissional B', '5511988880000', 'America/Sao_Paulo', 'ativo');

-- usuarios.id normalmente = auth.users.id (criado no signup). Para dev, usamos
-- ids fixos previsíveis, para os scripts de teste conseguirem "logar como".
insert into public.usuarios (id, profissional_id, nome, email, papel, ativo)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'Jamili', 'jamili@example.com', 'dono', true),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'Profissional B', 'profissionalb@example.com', 'dono', true);

insert into public.configuracoes (profissional_id, antecedencia_minima_min, janela_agendamento_dias, passo_agenda_min, reserva_expira_min, sinal_modo, sinal_fixo_centavos, politica_cancelamento, proximo_numero_agendamento)
values
  ('11111111-1111-1111-1111-111111111111', 0, 21, 30, 10, 'fixo', 5000, 'Cancelamentos com menos de 24 horas podem resultar na perda do sinal.', 1),
  ('22222222-2222-2222-2222-222222222222', 0, 21, 30, 10, 'fixo', 5000, 'Cancelamentos com menos de 24 horas podem resultar na perda do sinal.', 1);

-- Horários da Jamili: segunda a sexta 08:00–18:00, sábado 08:00–16:00, domingo fechado
-- (0=domingo ... 6=sábado, igual ao protótipo S.hrs).
insert into public.horarios_funcionamento (profissional_id, dia_semana, abre_min, fecha_min) values
  ('11111111-1111-1111-1111-111111111111', 1, 480, 1080), -- segunda
  ('11111111-1111-1111-1111-111111111111', 2, 480, 1080), -- terça
  ('11111111-1111-1111-1111-111111111111', 3, 480, 1080), -- quarta
  ('11111111-1111-1111-1111-111111111111', 4, 480, 1080), -- quinta
  ('11111111-1111-1111-1111-111111111111', 5, 480, 1080), -- sexta
  ('11111111-1111-1111-1111-111111111111', 6, 480, 960);  -- sábado

-- Horários da Profissional B: só segunda a sexta 09:00–17:00 (suficiente para os testes de isolamento).
insert into public.horarios_funcionamento (profissional_id, dia_semana, abre_min, fecha_min) values
  ('22222222-2222-2222-2222-222222222222', 1, 540, 1020),
  ('22222222-2222-2222-2222-222222222222', 2, 540, 1020),
  ('22222222-2222-2222-2222-222222222222', 3, 540, 1020),
  ('22222222-2222-2222-2222-222222222222', 4, 540, 1020),
  ('22222222-2222-2222-2222-222222222222', 5, 540, 1020);

-- Sem intervalo cadastrado para nenhuma das duas (equivalente a S.brk = null no seed()).

-- Serviços da Jamili — exatamente os 5 do seed() do protótipo.
insert into public.servicos (id, profissional_id, nome, descricao, preco_centavos, duracao_min, sinal_centavos, ativo, ordem) values
  ('a1000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Alongamento', null, 18000, 150, 5000, true, 1),
  ('a1000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Manutenção', null, 10000, 120, 3000, true, 2),
  ('a1000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Banho de Gel', null, 12000, 90, 4000, true, 3),
  ('a1000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Blindagem', null, 8000, 60, 3000, true, 4),
  ('a1000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'Esmaltação em Gel', null, 5000, 60, 2000, true, 5);

-- Um serviço simples para a Profissional B, só para os testes de isolamento.
insert into public.servicos (id, profissional_id, nome, preco_centavos, duracao_min, sinal_centavos, ativo, ordem) values
  ('b2000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Corte', 6000, 60, 2000, true, 1);
