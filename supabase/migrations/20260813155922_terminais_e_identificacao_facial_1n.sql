-- =====================================================================
-- Ponto sem senha: o aparelho autentica a chamada, o rosto identifica a
-- pessoa. Sem o terminal, o endpoint ficaria aberto para qualquer um que
-- tivesse a chave publicavel do HTML, e um descritor capturado uma vez
-- poderia ser reenviado para bater ponto no lugar de outra pessoa.
-- =====================================================================

create table if not exists ponto.terminais (
  id          uuid primary key default gen_random_uuid(),
  rep_id      uuid not null references ponto.rep(id),
  nome        text not null,
  token_hash  text not null unique,       -- sha-256 hex; o valor puro nunca e gravado
  ativo       boolean not null default true,
  criado_por  uuid references ponto.empregados(id),
  criado_em   timestamptz not null default now(),
  revogado_em timestamptz,
  ultimo_uso_em timestamptz
);

alter table ponto.terminais enable row level security;

drop policy if exists p_terminais_coord on ponto.terminais;
create policy p_terminais_coord on ponto.terminais
  for all to authenticated
  using (ponto.eh_coordenacao()) with check (ponto.eh_coordenacao());

-- O hash nao precisa sair do banco para lugar nenhum. Restringir por coluna
-- evita que a tela do admin carregue material de forca bruta sem necessidade.
revoke all on ponto.terminais from authenticated;
grant select (id, rep_id, nome, ativo, criado_por, criado_em, revogado_em, ultimo_uso_em)
  on ponto.terminais to authenticated;
grant insert (rep_id, nome, token_hash, criado_por), update (nome, ativo, revogado_em)
  on ponto.terminais to authenticated;

-- Desafio de vivacidade passa a nascer antes de saber quem e a pessoa.
alter table ponto.liveness_desafios alter column empregado_id drop not null;
alter table ponto.liveness_desafios
  add column if not exists terminal_id uuid references ponto.terminais(id);

-- Identificacao 1:N. A margem sobre o segundo colocado e o que separa a
-- pessoa certa de um parente parecido: similaridade alta sozinha nao basta.
create or replace function ponto.identificar_face(p_descritor vector)
returns table(empregado_id uuid, nome text, similaridade real, margem real)
language sql
stable
security definer
set search_path to 'ponto', 'public'
as $function$
  with por_pessoa as (
    select b.empregado_id as emp,
           max(1 - (b.descritor <=> p_descritor))::real as sim
      from ponto.biometria_facial b
      join ponto.empregados e on e.id = b.empregado_id and e.ativo
     where b.revogado_em is null
     group by b.empregado_id
  ),
  ordenado as (
    select p.emp, e.nome::text as nome, p.sim,
           row_number() over (order by p.sim desc) as rn,
           lead(p.sim) over (order by p.sim desc) as segundo
      from por_pessoa p
      join ponto.empregados e on e.id = p.emp
  )
  select emp, nome, sim, (sim - coalesce(segundo, 0))::real
    from ordenado
   where rn = 1;
$function$;

-- So o service role identifica. Exposta ao anon, a funcao viraria um oraculo
-- que responde "de quem e este rosto" para qualquer um.
revoke all on function ponto.identificar_face(vector) from public, anon, authenticated;
grant execute on function ponto.identificar_face(vector) to service_role;

notify pgrst, 'reload schema';