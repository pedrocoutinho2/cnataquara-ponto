-- ============================================================
-- ponto_016
-- 1) Data de início da apuração (go-live do REP nesta unidade).
--    Antes dela não havia sistema: contar falta ou saldo negativo
--    de dia sem marcação seria inventar passivo. A data mora no REP,
--    não no código, para não precisar de deploy quando mudar.
-- 2) ponto.dia_equipe(data): visão do dia inteiro, todo mundo junto.
-- ============================================================

alter table ponto.rep add column if not exists apuracao_inicio date;

comment on column ponto.rep.apuracao_inicio is
  'Primeiro dia apurado pelo REP. Dias anteriores são ignorados por espelho(), '
  'fechar_banco() e tudo que deriva deles. Nulo = apura desde sempre.';

update ponto.rep set apuracao_inicio = date '2026-08-17' where apuracao_inicio is null;

-- ---------- espelho: recorta o início pela data de go-live ----------
-- Todos os relatórios (resumo_equipe, relatorio_faltas, recorrencia_atrasos)
-- passam por aqui, então o recorte num lugar só vale para o sistema inteiro.
create or replace function ponto.espelho(p_emp uuid, p_ini date, p_fim date)
 returns table(data date, dia_semana smallint, feriado text, carga_prev_min integer,
   entrada timestamp with time zone, saida_almoco timestamp with time zone,
   volta_almoco timestamp with time zone, saida timestamp with time zone,
   marcacoes integer, trabalhado_min integer, intervalo_min integer, atraso_min integer,
   saida_antec_min integer, saldo_min integer, falta boolean, apurado boolean,
   abono_min integer, noturno_min integer, inconsistencias text[])
 language sql
 stable
as $function$
  select a.*
    from generate_series(
           greatest(p_ini, coalesce((select r.apuracao_inicio from ponto.rep r limit 1), p_ini)),
           p_fim, '1 day') d
    cross join lateral ponto.apurar_dia(p_emp, d::date) a;
$function$;

-- ---------- fechar_banco: mesmo recorte ----------
create or replace function ponto.fechar_banco(p_emp uuid, p_ini date, p_fim date)
 returns integer
 language plpgsql
as $function$
declare
  r record;
  total integer := 0;
  v_ini date := greatest(p_ini, coalesce((select x.apuracao_inicio from ponto.rep x limit 1), p_ini));
begin
  for r in
    select * from generate_series(v_ini, p_fim, '1 day') d
    cross join lateral ponto.apurar_dia(p_emp, d::date) a
  loop
    if r.apurado and r.saldo_min is not null and r.saldo_min <> 0 then
      insert into ponto.banco_lancamentos (empregado_id, data, minutos, origem)
      values (p_emp, r.data, r.saldo_min, 'apuracao')
      on conflict (empregado_id, data, origem) do update set minutos = excluded.minutos;
      total := total + 1;
    end if;
  end loop;
  return total;
end;
$function$;

-- ---------- dia_equipe: o dia de todo mundo numa tela ----------
create or replace function ponto.dia_equipe(p_data date)
 returns table(empregado_id uuid, nome text, cargo text, carga_prev_min integer, feriado text,
   entrada timestamp with time zone, saida_almoco timestamp with time zone,
   volta_almoco timestamp with time zone, saida timestamp with time zone,
   marcacoes integer, trabalhado_min integer, intervalo_min integer, atraso_min integer,
   saldo_min integer, falta boolean, apurado boolean, abono_min integer,
   inconsistencias text[], sinalizadas integer, saldo_banco_min integer,
   justificativa text)
 language sql
 stable
as $function$
  select e.id, e.nome::text, e.cargo, a.carga_prev_min, a.feriado,
         a.entrada, a.saida_almoco, a.volta_almoco, a.saida,
         a.marcacoes, a.trabalhado_min, a.intervalo_min, a.atraso_min,
         a.saldo_min, a.falta, a.apurado, a.abono_min, a.inconsistencias,
         (select count(*) from ponto.marcacao_contexto c
            join ponto.arp ar on ar.id = c.arp_id
           where c.empregado_id = e.id
             and c.revisao = 'pendente'
             and (ar.dh_marcacao at time zone
                  coalesce((select r2.timezone from ponto.rep r2 limit 1), 'America/Sao_Paulo')
                 )::date = p_data)::integer,
         ponto.saldo_banco(e.id, p_data),
         (select string_agg(j.justificativa, ' · ')
            from ponto.ajustes j
           where j.empregado_id = e.id and j.data = p_data and j.cancelado_em is null)
    from ponto.empregados e
    cross join lateral ponto.apurar_dia(e.id, p_data) a
   where e.ativo
     and p_data >= coalesce((select r3.apuracao_inicio from ponto.rep r3 limit 1), p_data)
     and (e.admissao is null or p_data >= e.admissao)
     and (e.demissao is null or p_data <= e.demissao)
   order by e.nome;
$function$;

grant execute on function ponto.dia_equipe(date) to authenticated, service_role;

notify pgrst, 'reload schema';