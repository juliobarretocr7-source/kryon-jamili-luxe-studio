Etapa 7B — Fundação real + banco de dados (auditada)
Status honesto: a fundação foi auditada e corrigida por revisão estática e simulação lógica em JavaScript. Nenhum SQL foi executado em PostgreSQL/Supabase real. Testes reais de PostgreSQL/Supabase ainda precisam ser executados em ambiente PostgreSQL real.
O que foi construído
#
Item pedido
Onde está
1
Projeto real
package.json, tsconfig.json, .env.example (scaffold Next.js + TS; telas entram nas etapas 7C+)
2-3
Supabase + PostgreSQL
supabase/config.toml + supabase/migrations/ (padrão Supabase CLI)
4-5
Schema + migrações versionadas
9 arquivos numerados em supabase/migrations/, aplicados em ordem
6-9
Tabelas, relacionamentos, índices, constraints
seção "Tabelas" abaixo
10
RLS
20260930120007_rls.sql (+ triggers/permissões em 20260930120008)
11
Multi-tenant
profissional_id em toda tabela de negócio + FKs compostas + RLS
12
Dados de desenvolvimento
supabase/seed.sql (Jamili igual ao seed() do protótipo + Profissional B só para teste)
13-15
Testes
supabase/tests/ (SQL para Postgres real) + supabase/tests/sim e static (rodam em Node)
16
Esta documentação
este arquivo
Tabelas criadas
profissionais, usuarios, configuracoes, horarios_funcionamento, intervalos, servicos, clientes, agendamentos, agendamento_eventos, pagamentos, transacoes_financeiras — exatamente as da arquitetura 7A, seção 2. Nenhuma tabela extra foi criada na auditoria (só uma coluna, agendamentos.chave_idempotencia).
Decisões seguidas da 7A
Stack Next.js + TypeScript + Supabase/PostgreSQL; sinal configurável por profissional (padrão fixo R$ 50); número do agendamento atribuído só na confirmação, sequencial por profissional; janela de 21 dias e passo de 30 min configuráveis; reserva temporária de 10 min configurável; faltou continua ocupando o horário. Não decididos aqui (não afetam o schema): gateway/quem recebe o sinal, política real de cancelamento/reembolso, pagamento tardio (7I), unificação dos fluxos de cliente (7H), domínio do link público, LGPD/termos.
Proteção contra dupla reserva (estado final)
alter table public.agendamentos
  add constraint agendamentos_sem_sobreposicao
  exclude using gist (
    profissional_id with =,
    tstzrange(inicio_em, fim_em, '[)') with &&
  )
  where (status in ('aguardando_pagamento','confirmado','em_atendimento','concluido','faltou'));
Camadas, da mais forte para a mais amigável:
EXCLUDE no banco (barreira final, vale para qualquer caminho: função, painel, reagendamento, SQL direto).
fn_criar_reserva: uma transação só — expira vencidas, revalida disponibilidade, insere, grava evento. Se duas pessoas chegarem juntas, o banco aceita uma e a outra recebe exclusion_violation, traduzida para "Esse horário acabou de ser reservado. Escolha outro horário." (SQLSTATE 23P01, o backend mapeia para HTTP 409).
Idempotência: chave_idempotencia opcional, única por profissional. Repetir a mesma chamada (duplo clique/retry) devolve a mesma reserva, inclusive numa corrida entre duas chamadas com a mesma chave.
fn_horarios_disponiveis é só informativa (nunca substitui a constraint).
Reservas expiradas (estado final)
PostgreSQL não aceita now() numa EXCLUDE/índice parcial (expressão não imutável), então a constraint não usa now(). A estratégia da 7A (gravar status = 'expirado') foi preservada e ganhou uma terceira garantia:
Garantia
Onde
O que faz
Rotina global
fn_expirar_reservas_vencidas() (cron a cada minuto, 7I)
marca expirado + grava evento
Criação de reserva
fn_criar_reserva
expira as vencidas da profissional antes de checar
Gatilho (novo)
trg_agendamentos_liberar_expiradas (008)
antes de qualquer INSERT/UPDATE de horário ocupante, expira as vencidas que colidiriam — cobre painel, reagendamento e confirmação
Disponibilidade
fn_horarios_disponiveis
ignora aguardando_pagamento com reserva_expira_em <= now() mesmo antes de a rotina rodar
Reserva dentro do prazo continua bloqueando; reserva vencida nunca bloqueia; o registro expirado permanece como histórico.
Isolamento multi-tenant (estado final)
FKs compostas (profissional_id, X_id) → tabela(profissional_id, id): agendamentos→clientes/servicos, agendamento_eventos→agendamentos, pagamentos→agendamentos, transacoes_financeiras→agendamentos/pagamentos/transacoes (estorno). Não sobrou nenhuma FK simples para tabela de negócio além de profissionais(id).
RLS em todas as 11 tabelas, policies por comando e só para authenticated (o papel anon não tem policy nenhuma).
Escritas reservadas ao servidor (papel de serviço, que contorna RLS): criar/alterar/remover profissionais e usuarios, gravar pagamentos. Decisões da auditoria, fáceis de relaxar se você preferir outro desenho.
Chave de serviço: só servidor (.env.example sem NEXT_PUBLIC_, conferido no teste estático).
Numeração, valores e migrações
Numeração preservada: só na confirmação, por profissional, #000001 (formato de exibição), único por (profissional_id, numero), UUID interno separado, atômica por SELECT ... FOR UPDATE. Reforço novo: numero só pode existir com confirmado_em, e a função só é executável pelo papel de serviço (a profissional logada não "queima" números).
Dinheiro: 7 colunas *_centavos, todas integer; nenhum float/numeric/money (conferido no teste estático).
Migrations: 001–003 intactas. 004–007 corrigidas na origem (a 7B ainda não tem histórico publicado — corrigir lá evita drop/recreate de constraints). 008 é corretiva e aditiva.
Auditoria e correções finais
#
Problema encontrado
Arquivo / migration
Correção realizada
Motivo técnico
Impacto nos testes
1
EXCLUDE usava tsrange(inicio_em, fim_em) sobre colunas timestamptz
004_agendamentos
tstzrange(inicio_em, fim_em, '[)') (também no gatilho da 008)
tsrange exige converter timestamptz→timestamp, que depende do fuso da sessão (não é imutável) e não serve numa constraint; tstzrange compara instantes absolutos
02 confere pg_get_constraintdef e repete a sobreposição com TimeZone Tokyo/São Paulo/UTC; estático proíbe tsrange(
2
pagamentos.agendamento_id era FK simples (pagamento da A podia apontar agendamento da B)
005_pagamentos_financeiro
FK composta (profissional_id, agendamento_id); UNIQUE (profissional_id, id) em pagamentos
o banco passa a recusar o cruzamento mesmo com bug no código/RLS
04 (INSERT e UPDATE cruzados)
3
agendamento_eventos.agendamento_id era FK simples
004_agendamentos
FK composta (profissional_id, agendamento_id)
idem
04
4
Eventos (e livro-caixa) podiam sofrer UPDATE/DELETE/TRUNCATE
008 + 007_rls
trigger fn_bloquear_alteracao_imutavel (UPDATE/DELETE/TRUNCATE) em agendamento_eventos e transacoes_financeiras; RLS só com SELECT/INSERT
proteção vale também para o dono das tabelas; sem "chave mestra" por configuração de sessão (um GUC poderia ser ligado pelo próprio atacante)
05 (como authenticated → 0 linhas; como dono → exceção 23001)
5
transacoes_financeiras.pagamento_id e estorna_transacao_id eram FKs simples
005_pagamentos_financeiro
UNIQUE (profissional_id, id) + duas FKs compostas (ordem: unique antes das FKs)
fechava dois cruzamentos que a 7A exigia fechar
04; estático confere a ordem
6
RLS: uma policy FOR ALL para PUBLIC por tabela; o navegador podia apagar o próprio vínculo/cadastro, alterar papel/ativo, gravar pagamento "aprovado" e apagar agendamento
007_rls
policies por comando, TO authenticated; profissionais select/update; usuarios e pagamentos só select; agendamentos sem delete; fn_profissional_atual com search_path fixo
menor privilégio; 7A: confirmação de pagamento só pelo servidor, cancelar nunca apaga
01 (11 tabelas) e estático
7
Reserva vencida ainda não marcada bloqueava o INSERT direto/reagendamento (só fn_criar_reserva expirava)
008 (+ 006)
gatilho trg_agendamentos_liberar_expiradas; fn_expirar_reservas_vencidas grava evento expirado
EXCLUDE não pode usar now(); o status gravado é a única forma estática
06 passos 7–9; simulação JS
8
janela_agendamento_dias existia mas nada a aplicava
006_funcoes_negocio
fn_horarios_disponiveis recusa datas > hoje+janela (painel passa p_ignorar_janela)
7A 5.2: datas fora da janela são recusadas
03 e 06 passo 10
9
Idempotência da reserva não existia (a 7A 5.3 pede)
004 + 006
coluna chave_idempotencia, índice único por profissional, tratamento de unique_violation/exclusion_violation
duplo clique/retry não cria duas reservas nem devolve erro enganoso
06 passos 1–2; simulação JS
10
numero podia existir sem confirmação; fn_proximo_numero_agendamento executável por qualquer logado
008
check numero is null or confirmado_em is not null; REVOKE da função (só serviço)
reforça a regra da 7A seção 8 sem alterar sequência/formato
06 passo 11
11
FK para serviço/cliente dependia do padrão NO ACTION
004
ON DELETE RESTRICT explícito
intenção da 7A explícita no schema
estático
12
Bugs na infraestrutura de teste: (a) 01 rodava como dono da tabela, que ignora RLS (o teste de isolamento não testava RLS); (b) when insufficient_privilege or others engolia a própria falha FALHOU; (c) 00 fazia CREATE OR REPLACE auth.uid() e quebraria no Supabase real; (d) db:test não listava todos os testes; (e) testes deixavam dados e apagavam por filtro
tests/00…06, package.json
test.login_como troca para o papel authenticated; flags em vez de others; stub só se auth.uid() não existir; tudo em BEGIN … ROLLBACK; ON_ERROR_STOP
um teste que não consegue falhar não prova nada
todos reescritos
Limitações conhecidas (não corrigidas de propósito, documentadas)
fn_horarios_disponiveis usa só o primeiro turno do dia (a tabela já permite vários; a UI de turnos não existe ainda).
transacoes_financeiras não impede que pagamento_id e agendamento_id sejam de agendamentos diferentes da mesma profissional (não é cruzamento entre profissionais; pode virar FK de três colunas se quiser).
usuarios.id não tem FK para auth.users (evita acoplar seed/testes ao Supabase Auth; avaliar na 7C).
anon não tem acesso a nada; a página pública (funções estreitas por slug) é a etapa 7H.
Confirmação de reserva (número + pagamento + caixa em uma transação) é 7I; aqui só existem as peças (fn_proximo_numero_agendamento, constraints).
Como foi testado — seja claro sobre o que rodou
Realmente executado neste ambiente (Node.js)
Comando
O que é
Resultado
npm run test:static
revisão estática das migrations (análise de texto, não parser de Postgres)
46 de 46 verificações passaram
npm run test:sim
simulação lógica em JavaScript das regras (sobreposição [), status ocupantes, expiradas, idempotência, numeração, FK composta, imutabilidade, centavos)
12 de 12 passaram
A primeira execução do teste estático apontou 1 falha, que era erro de contagem do próprio script (7 colunas em centavos, não 8); o script foi corrigido, o schema não mudou.
Escritos, mas NÃO executados (precisam de PostgreSQL real)
supabase/tests/00_stub_auth_local.sql … 06_reservas_expiradas_idempotencia_numeracao.sql. Testes reais de PostgreSQL/Supabase ainda precisam ser executados em ambiente PostgreSQL real. Nenhuma migration foi aplicada em PostgreSQL, então não se pode afirmar que "funciona no Supabase".
supabase start && supabase db reset     # aplica as 9 migrations + seed
npm run db:test                         # roda 00..06 (cada um termina com ROLLBACK)
Em Supabase real o 00_stub_auth_local.sql detecta auth.uid() e os papéis existentes e não sobrescreve nada.
O que merece atenção na primeira execução real
Por nunca terem rodado, estes são os pontos com mais chance de pedir ajuste fino:
UPDATE dentro do gatilho BEFORE INSERT (008) e a interação com a EXCLUDE (teste 06 passo 9).
Troca de papel com SET ROLE dentro de blocos DO (test.login_como) e set local timezone no teste 02.
Grants/revokes condicionais da 008 em Supabase (papéis e privilégios padrão).
Concorrência real (duas conexões simultâneas disputando o mesmo horário e a mesma chave) não cabe em um script de sessão única: precisa de um teste com dois psql em paralelo ou pgbench.
Fora do escopo (continua para as próximas etapas)
Login/cadastro (7C), telas do painel (7D-7G), link público /agendar/{slug} (7H), PIX real/webhook/confirmação (7I). Esta auditoria não avançou para a 7C.
