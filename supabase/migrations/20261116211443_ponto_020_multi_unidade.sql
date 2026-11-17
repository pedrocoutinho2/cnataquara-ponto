-- ponto_020_multi_unidade
-- Rede (Taquara, Jardim América; Queimados quando entrar). Decisão 2026-11-11:
-- Ponto é controle interno em base única, um ponto.rep por unidade.
-- Cada função que lia "ponto.rep limit 1" passa a usar o REP do empregado.

-- 1. Unidade no REP
alter table ponto.rep add column if not exists unidade text;
update ponto.rep set unidade = 'taquara' where unidade is null and apelido = 'CNA Taquara';
alter table ponto.rep alter column unidade set not null;
alter table ponto.rep add constraint rep_unidade_key unique (unidade);

-- 2. Funções: REP do empregado em vez de "limit 1"
do $mig$
declare
  d text;
begin
  -- helper inline: troca exatamente uma ocorrência
  -- apurar_dia: REP do empregado e feriado do REP
  d := pg_get_functiondef('ponto.apurar_dia(uuid,date)'::regprocedure);
  assert (length(d) - length(replace(d, 'select * into cfg from ponto.rep limit 1;', ''))) / length('select * into cfg from ponto.rep limit 1;') = 1, 'apurar_dia cfg';
  d := replace(d, 'select * into cfg from ponto.rep limit 1;',
                  'select rp.* into cfg from ponto.rep rp join ponto.empregados e0 on e0.rep_id = rp.id where e0.id = p_emp;');
  assert position('from ponto.feriados f where f.data = p_data limit 1;' in d) > 0, 'apurar_dia feriado';
  d := replace(d, 'from ponto.feriados f where f.data = p_data limit 1;',
                  'from ponto.feriados f where f.data = p_data and f.rep_id = cfg.id limit 1;');
  execute d;

  d := pg_get_functiondef('ponto.alterar_ajuste(uuid,ponto.ajuste_tipo,timestamptz,integer,text)'::regprocedure);
  assert position('select timezone into v_tz from ponto.rep limit 1;' in d) > 0, 'alterar_ajuste';
  d := replace(d, 'select timezone into v_tz from ponto.rep limit 1;',
                  'select r.timezone into v_tz from ponto.rep r join ponto.empregados e0 on e0.rep_id = r.id where e0.id = v_old.empregado_id;');
  execute d;

  d := pg_get_functiondef('ponto.corrigir_marcacao(uuid,timestamptz,text)'::regprocedure);
  assert position('select timezone into v_tz from ponto.rep limit 1;' in d) > 0, 'corrigir_marcacao';
  d := replace(d, 'select timezone into v_tz from ponto.rep limit 1;',
                  'select r.timezone into v_tz from ponto.rep r where r.id = v_arp.rep_id;');
  execute d;

  d := pg_get_functiondef('ponto.lancar_evento(uuid[],date,time,time,text)'::regprocedure);
  assert position('select timezone into v_tz from ponto.rep limit 1;' in d) > 0, 'lancar_evento';
  d := replace(d, 'select timezone into v_tz from ponto.rep limit 1;',
                  'select r.timezone into v_tz from ponto.rep r join ponto.empregados e0 on e0.rep_id = r.id where e0.id = p_emps[1];');
  execute d;

  d := pg_get_functiondef('ponto.banco_saldo_vivo(uuid,date)'::regprocedure);
  assert position('select coalesce(apuracao_inicio, p_ate) as ini from ponto.rep limit 1' in d) > 0, 'banco_saldo_vivo';
  d := replace(d, 'select coalesce(apuracao_inicio, p_ate) as ini from ponto.rep limit 1',
                  'select coalesce(r.apuracao_inicio, p_ate) as ini from ponto.rep r join ponto.empregados e0 on e0.rep_id = r.id where e0.id = p_emp');
  execute d;

  d := pg_get_functiondef('ponto.espelho(uuid,date,date)'::regprocedure);
  assert position('(select r.apuracao_inicio from ponto.rep r limit 1)' in d) > 0, 'espelho';
  d := replace(d, '(select r.apuracao_inicio from ponto.rep r limit 1)',
                  '(select r.apuracao_inicio from ponto.rep r join ponto.empregados e0 on e0.rep_id = r.id where e0.id = p_emp)');
  execute d;

  d := pg_get_functiondef('ponto.fechar_banco(uuid,date,date)'::regprocedure);
  assert position('(select x.apuracao_inicio from ponto.rep x limit 1)' in d) > 0, 'fechar_banco';
  d := replace(d, '(select x.apuracao_inicio from ponto.rep x limit 1)',
                  '(select x.apuracao_inicio from ponto.rep x join ponto.empregados e0 on e0.rep_id = x.id where e0.id = p_emp)');
  execute d;

  d := pg_get_functiondef('ponto.marcacoes_efetivas(uuid,date)'::regprocedure);
  assert position('with cfg as (select timezone from ponto.rep limit 1)' in d) > 0, 'marcacoes_efetivas';
  d := replace(d, 'with cfg as (select timezone from ponto.rep limit 1)',
                  'with cfg as (select r.timezone from ponto.rep r join ponto.empregados e0 on e0.rep_id = r.id where e0.id = p_emp)');
  execute d;
  d := pg_get_functiondef('ponto.dia_equipe(date)'::regprocedure);
  assert position('with cfg as (select coalesce(timezone, ''America/Sao_Paulo'') as tz from ponto.rep limit 1)' in d) > 0, 'dia_equipe cfg';
  d := replace(d, 'with cfg as (select coalesce(timezone, ''America/Sao_Paulo'') as tz from ponto.rep limit 1)', '');
  d := replace(d, 'at time zone (select tz from cfg)', 'at time zone coalesce(r.timezone, ''America/Sao_Paulo'')');
  assert position('cross join lateral ponto.apurar_dia(e.id, p_data) a' in d) > 0, 'dia_equipe join';
  d := replace(d, 'cross join lateral ponto.apurar_dia(e.id, p_data) a', 'join ponto.rep r on r.id = e.rep_id' || chr(10) || '    cross join lateral ponto.apurar_dia(e.id, p_data) a');
  assert position('coalesce((select r3.apuracao_inicio from ponto.rep r3 limit 1), p_data)' in d) > 0, 'dia_equipe ini';
  d := replace(d, 'coalesce((select r3.apuracao_inicio from ponto.rep r3 limit 1), p_data)', 'coalesce(r.apuracao_inicio, p_data)');
  execute d;
end $mig$;


-- 3. Identificação facial restrita ao REP do terminal (identificar_face(vector) continua igual)
create or replace function ponto.identificar_face_rep(p_descritor vector, p_rep_id uuid)
 returns table(empregado_id uuid, nome text, similaridade real, margem real)
 language sql stable security definer set search_path to 'ponto', 'public'
as $function$
  with por_pessoa as (
    select b.empregado_id as emp, max(1 - (b.descritor <=> p_descritor))::real as sim
      from ponto.biometria_facial b
      join ponto.empregados e on e.id = b.empregado_id and e.ativo and e.rep_id = p_rep_id
     where b.revogado_em is null
     group by b.empregado_id
  ),
  ordenado as (
    select p.emp, e.nome::text as nome, p.sim,
           row_number() over (order by p.sim desc) as rn,
           lead(p.sim) over (order by p.sim desc) as segundo
      from por_pessoa p join ponto.empregados e on e.id = p.emp
  )
  select emp, nome, sim, (sim - coalesce(segundo, 0))::real from ordenado where rn = 1;
$function$;
revoke all on function ponto.identificar_face_rep(vector, uuid) from public, anon, authenticated;
grant execute on function ponto.identificar_face_rep(vector, uuid) to service_role;

notify pgrst, 'reload schema';
