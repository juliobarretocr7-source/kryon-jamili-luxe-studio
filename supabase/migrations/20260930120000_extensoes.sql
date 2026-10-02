-- ETAPA 7B — Fundação
-- Extensões necessárias:
--   pgcrypto   -> gen_random_uuid() para as chaves primárias
--   btree_gist -> necessária para a EXCLUDE constraint que combina
--                 igualdade (profissional_id) com sobreposição de intervalo
--                 de tempo (proteção contra dupla reserva, seção 2.9/10 da 7A)
create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- Função utilitária: mantém atualizado_em sempre correto em qualquer UPDATE.
-- Reaproveitada por todas as tabelas de negócio (evita repetir lógica).
create or replace function public.fn_atualiza_timestamp()
returns trigger
language plpgsql
as $$
begin
  new.atualizado_em = now();
  return new;
end;
$$;

comment on function public.fn_atualiza_timestamp() is
  'Preenche atualizado_em automaticamente em qualquer UPDATE. Usada via trigger em todas as tabelas de negócio.';
