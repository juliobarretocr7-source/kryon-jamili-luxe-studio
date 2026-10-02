-- SOMENTE PARA TESTES LOCAIS EM POSTGRES PURO. NÃO faz parte de supabase/migrations.
-- Em Supabase (local via `supabase start` ou nuvem) auth.uid() e os papéis
-- anon/authenticated/service_role JÁ EXISTEM: este arquivo detecta isso e não sobrescreve nada
-- (a versão anterior fazia CREATE OR REPLACE em auth.uid(), que falharia/ sobrescreveria o real).
--
-- O que este arquivo garante para os testes:
--  1) auth.uid() existe (stub lê app.current_user_id só se o real não existir);
--  2) os papéis anon/authenticated existem e recebem os privilégios padrão do Supabase,
--     para o RLS ser TESTADO DE VERDADE: o papel dono das tabelas (postgres) IGNORA RLS,
--     então os testes de isolamento precisam rodar como "authenticated" (test.login_como).

create schema if not exists auth;

do $$
begin
  if to_regprocedure('auth.uid()') is null then
    execute $f$
      create function auth.uid() returns uuid
      language sql stable
      as $body$
        select coalesce(
          nullif(current_setting('request.jwt.claim.sub', true), ''),
          nullif(current_setting('app.current_user_id', true), '')
        )::uuid
      $body$
    $f$;
  end if;

  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;

grant usage on schema public, auth to anon, authenticated;
-- Privilégios padrão do Supabase para tabelas/funções do schema public:
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
grant execute on function auth.uid() to anon, authenticated;

create schema if not exists test;
grant usage on schema test to anon, authenticated;

-- Uso nos testes:  select test.login_como('aaaaaaaa-...');   -- vira papel "authenticated" (RLS vale)
--                  select test.logout();                      -- volta ao papel original (dono)
-- Funciona com o auth.uid() REAL do Supabase (claims JWT) e com o stub.
create or replace function test.login_como(p_usuario_id uuid) returns void
language plpgsql
as $$
begin
  execute 'reset role';
  perform set_config('app.current_user_id', p_usuario_id::text, false);
  perform set_config('request.jwt.claim.sub', p_usuario_id::text, false);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_usuario_id, 'role', 'authenticated')::text, false);
  execute 'set role authenticated';
end;
$$;

create or replace function test.logout() returns void
language plpgsql
as $$
begin
  execute 'reset role';
  perform set_config('app.current_user_id', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claims', '', false);
end;
$$;

grant execute on all functions in schema test to anon, authenticated;
