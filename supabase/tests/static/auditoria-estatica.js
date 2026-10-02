// REVISÃO ESTÁTICA DAS MIGRATIONS (análise de texto). NÃO executa SQL e NÃO é um parser do PostgreSQL:
// ela confere padrões que não podem regredir. Não substitui rodar as migrations num Postgres real.
// Rodar: node supabase/tests/static/auditoria-estatica.js
'use strict';
const fs = require('fs'); const path = require('path');
const raiz = path.resolve(__dirname, '../../..');
const dirMig = path.join(raiz, 'supabase/migrations');
const arquivos = fs.readdirSync(dirMig).filter(f => f.endsWith('.sql')).sort();
const strip = s => s.replace(/--.*$/gm, ''); // remove comentários de linha
const migs = arquivos.map(f => ({ f, sql: strip(fs.readFileSync(path.join(dirMig, f), 'utf8')) }));
const tudo = migs.map(m => m.sql).join('\n');
let falhas = 0;
const check = (nome, ok, detalhe) => { console.log((ok ? '  OK   ' : '  FALHA') + ' ' + nome + (ok ? '' : '  -> ' + detalhe)); if (!ok) falhas++; };

// 1) versionamento
check('migrations ordenadas, com timestamps únicos', new Set(arquivos.map(f => f.split('_')[0])).size === arquivos.length, arquivos.join(','));

// 2) tstzrange
check('nenhum tsrange( (sem tz) nas migrations', !/(^|[^z])tsrange\s*\(/i.test(tudo), 'encontrado tsrange(');
const excl = tudo.match(/exclude\s+using\s+gist\s*\(([\s\S]*?)\)\s*where\s*\(([\s\S]*?)\)\s*;/i);
check('EXCLUDE agendamentos_sem_sobreposicao existe', /agendamentos_sem_sobreposicao\s+exclude/i.test(tudo.replace(/\s+/g, ' ')), 'ausente');
check('EXCLUDE usa profissional_id with = e tstzrange(inicio_em, fim_em, \'[)\') with &&',
  !!excl && /profissional_id\s+with\s*=/i.test(excl[1]) && /tstzrange\(inicio_em,\s*fim_em,\s*'\[\)'\)\s+with\s*&&/i.test(excl[1]), excl && excl[1]);
check('EXCLUDE não usa now()/funções voláteis', !!excl && !/now\s*\(|current_timestamp|clock_timestamp/i.test(excl[0]), 'now() na constraint');
const ocup = excl ? [...excl[2].matchAll(/'([a-z_]+)'/g)].map(m => m[1]).sort() : [];
check('status ocupantes = aguardando_pagamento, confirmado, em_atendimento, concluido, faltou',
  JSON.stringify(ocup) === JSON.stringify(['aguardando_pagamento', 'concluido', 'confirmado', 'em_atendimento', 'faltou']), ocup.join(','));
check('btree_gist habilitada', /create extension if not exists btree_gist/i.test(tudo), 'ausente');

// 3) tabelas com profissional_id: RLS + policy, e FKs
const tabelas = [...tudo.matchAll(/create table public\.(\w+)\s*\(([\s\S]*?)\n\);/gi)].map(m => ({ nome: m[1], corpo: m[2] }));
const comPid = tabelas.filter(t => /\bprofissional_id\b/.test(t.corpo) || t.nome === 'profissionais');
check('tabelas de negócio detectadas (11)', tabelas.length === 11, tabelas.map(t => t.nome).join(','));
for (const t of comPid) {
  const rls = new RegExp(`alter table public\\.${t.nome}\\s+enable row level security`, 'i').test(tudo);
  const pol = new RegExp(`create policy \\w+ on public\\.${t.nome}\\b`, 'i').test(tudo);
  check(`RLS habilitado + ao menos uma policy em ${t.nome}`, rls && pol, `rls=${rls} policy=${pol}`);
}
const policies = [...tudo.matchAll(/create policy (\w+) on public\.(\w+)([\s\S]*?);/gi)];
check('toda policy é "to authenticated" (anon sem policy)', policies.length > 0 && policies.every(p => /to authenticated/i.test(p[3])), policies.filter(p => !/to authenticated/i.test(p[3])).map(p => p[1]).join(','));
check('nenhuma policy "using (true)" / sem filtro de tenant', policies.every(p => !/using\s*\(\s*true\s*\)/i.test(p[3]) && /fn_profissional_atual\(\)/.test(p[3])), 'policy sem fn_profissional_atual');
check('sem FORCE ROW LEVEL SECURITY (quebraria fn_profissional_atual)', !/force row level security/i.test(tudo), 'force rls');
const polDe = (tab, cmd) => policies.some(p => p[2] === tab && new RegExp(`for ${cmd}`, 'i').test(p[3]));
check('eventos e transações: sem policy de UPDATE/DELETE', ['agendamento_eventos', 'transacoes_financeiras'].every(t => !polDe(t, 'update') && !polDe(t, 'delete')), '');
check('pagamentos e usuarios: só SELECT pelo navegador', ['pagamentos', 'usuarios'].every(t => polDe(t, 'select') && !polDe(t, 'insert') && !polDe(t, 'update') && !polDe(t, 'delete')), '');
check('agendamentos: sem policy de DELETE (cancelar = mudar status)', !polDe('agendamentos', 'delete'), '');

// 4) FKs: nenhuma FK simples para tabelas de negócio (exceto profissionais); compostas onde exigido
const refsSimples = [...tudo.matchAll(/references\s+public\.(\w+)\s*\(\s*id\s*\)/gi)].map(m => m[1]);
check('FKs simples só apontam para profissionais(id)', refsSimples.every(r => r === 'profissionais'), refsSimples.filter(r => r !== 'profissionais').join(','));
const compostas = [...tudo.matchAll(/foreign key\s*\(\s*profissional_id\s*,\s*(\w+)\s*\)\s*references\s+public\.(\w+)\s*\(\s*profissional_id\s*,\s*id\s*\)/gi)].map(m => `${m[1]}->${m[2]}`);
for (const esperado of ['cliente_id->clientes', 'servico_id->servicos', 'agendamento_id->agendamentos', 'pagamento_id->pagamentos', 'estorna_transacao_id->transacoes_financeiras'])
  check(`FK composta (profissional_id, ${esperado.split('->')[0]}) -> ${esperado.split('->')[1]}`, compostas.includes(esperado), 'ausente');
check('FK composta de agendamento_id existe em 3 tabelas (agendamentos→eventos, pagamentos, transacoes)', compostas.filter(c => c === 'agendamento_id->agendamentos').length === 3, String(compostas.filter(c => c === 'agendamento_id->agendamentos').length));

// 5) ordem: a UNIQUE (profissional_id, id) precisa existir ANTES da FK composta que a usa
const posUnique = {}; const posFk = [];
let off = 0;
for (const m of migs) {
  for (const u of m.sql.matchAll(/(?:alter table public\.(\w+)\s+add constraint \w+ unique\s*\(\s*profissional_id\s*,\s*id\s*\))/gi)) posUnique[u[1]] = posUnique[u[1]] ?? off + u.index;
  for (const f of m.sql.matchAll(/foreign key\s*\(\s*profissional_id\s*,\s*\w+\s*\)\s*references\s+public\.(\w+)/gi)) posFk.push({ alvo: f[1], pos: off + f.index });
  off += m.sql.length + 1;
}
check('UNIQUE (profissional_id, id) definida antes de cada FK composta que a usa', posFk.every(f => posUnique[f.alvo] !== undefined && posUnique[f.alvo] < f.pos), posFk.filter(f => !(posUnique[f.alvo] < f.pos)).map(f => f.alvo).join(','));

// 6) dinheiro em centavos inteiros
const colunas = [...tudo.matchAll(/^\s*(\w+)\s+(integer|bigint|smallint|numeric|decimal|real|double precision|float\d*|money)\b/gim)];
check('nenhum tipo float/real/double/numeric/decimal/money nas migrations', !colunas.some(c => /numeric|decimal|real|double|float|money/i.test(c[2])), colunas.filter(c => /numeric|decimal|real|double|float|money/i.test(c[2])).map(c => c[1]).join(','));
const centavos = colunas.filter(c => /_centavos$/.test(c[1]));
check('todas as colunas *_centavos são integer', centavos.length === 7 && centavos.every(c => c[2].toLowerCase() === 'integer'), centavos.map(c => `${c[1]}:${c[2]}`).join(','));

// 7) imutabilidade, número e idempotência
for (const tab of ['agendamento_eventos', 'transacoes_financeiras']) {
  check(`trigger de UPDATE/DELETE em ${tab}`, new RegExp(`before update or delete on public\\.${tab}`, 'i').test(tudo), 'ausente');
  check(`trigger de TRUNCATE em ${tab}`, new RegExp(`before truncate on public\\.${tab}`, 'i').test(tudo), 'ausente');
}
check('índice único (profissional_id, numero) onde numero não é nulo', /create unique index agendamentos_numero_unico_por_profissional\s+on public\.agendamentos\s*\(\s*profissional_id\s*,\s*numero\s*\)\s*where numero is not null/i.test(tudo), 'ausente');
check('número só com confirmado_em (check)', /agendamentos_numero_so_confirmado/.test(tudo), 'ausente');
check('contador de número usa SELECT ... FOR UPDATE (atômico)', /from public\.configuracoes\s+where profissional_id = p_profissional_id\s+for update/i.test(tudo), 'ausente');
check('idempotência: índice único (profissional_id, chave_idempotencia)', /create unique index agendamentos_idempotencia_unica[\s\S]*?\(\s*profissional_id\s*,\s*chave_idempotencia\s*\)/i.test(tudo), 'ausente');
check('trigger libera reservas vencidas conflitantes (sem now() na EXCLUDE)', /trg_agendamentos_liberar_expiradas/.test(tudo) && /reserva_expira_em\s*<\s*now\(\)/.test(tudo), 'ausente');
check('fn_proximo_numero_agendamento: execução revogada de public', /revoke all on function public\.fn_proximo_numero_agendamento\(uuid\) from public/i.test(tudo), 'ausente');

// 8) segredos
const env = fs.readFileSync(path.join(raiz, '.env.example'), 'utf8');
check('service role key SEM prefixo NEXT_PUBLIC_', /^SUPABASE_SERVICE_ROLE_KEY=/m.test(env) && !/NEXT_PUBLIC_\w*SERVICE/i.test(env), 'service role exposta');

console.log(falhas ? `\n${falhas} verificação(ões) FALHARAM.` : '\nTodas as verificações estáticas passaram (análise de texto, sem executar SQL).');
process.exit(falhas ? 1 : 0);
