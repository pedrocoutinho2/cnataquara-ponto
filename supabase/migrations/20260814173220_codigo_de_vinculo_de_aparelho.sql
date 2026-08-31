-- O codigo curto que a coordenacao digita no aparelho deixa de ser a credencial
-- do terminal. Ele vira codigo de vinculo: e trocado uma vez por um token forte,
-- gerado no servidor, e some. O que fica guardado no celular nao serve para
-- autorizar outro aparelho.
create table if not exists ponto.codigos_vinculo (
  id          uuid primary key default gen_random_uuid(),
  rep_id      uuid not null references ponto.rep(id),
  codigo_hash text not null,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now(),
  criado_por  uuid references ponto.empregados(id),
  revogado_em timestamptz
);
create unique index if not exists codigos_vinculo_hash_ativo
  on ponto.codigos_vinculo (codigo_hash) where ativo;

alter table ponto.codigos_vinculo enable row level security;

-- Sem policy para anon: o unico caminho de leitura e a funcao abaixo, que roda
-- como dono. A coordenacao enxerga pela policy de coordenacao.
drop policy if exists codigos_vinculo_coord on ponto.codigos_vinculo;
create policy codigos_vinculo_coord on ponto.codigos_vinculo
  for all to authenticated
  using (ponto.eh_coordenacao()) with check (ponto.eh_coordenacao());

create or replace function ponto.vincular_aparelho(p_codigo text, p_nome text default null)
returns text
language plpgsql
security definer
set search_path to 'ponto', 'public', 'extensions'
as $$
declare
  v_cod   ponto.codigos_vinculo;
  v_token text;
begin
  select * into v_cod
    from ponto.codigos_vinculo
   where codigo_hash = encode(digest(btrim(p_codigo), 'sha256'), 'hex')
     and ativo;

  if v_cod.id is null then
    raise exception 'Código inválido' using errcode = '28000';
  end if;

  -- 32 bytes: o aparelho passa a guardar isto, nunca o codigo digitado.
  v_token := encode(gen_random_bytes(32), 'hex');

  insert into ponto.terminais (rep_id, nome, token_hash, criado_por)
  values (
    v_cod.rep_id,
    coalesce(nullif(btrim(p_nome), ''),
             'Aparelho vinculado em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')),
    encode(digest(v_token, 'sha256'), 'hex'),
    v_cod.criado_por
  );

  return v_token;
end;
$$;

revoke all on function ponto.vincular_aparelho(text, text) from public;
grant execute on function ponto.vincular_aparelho(text, text) to anon, authenticated;

notify pgrst, 'reload schema';