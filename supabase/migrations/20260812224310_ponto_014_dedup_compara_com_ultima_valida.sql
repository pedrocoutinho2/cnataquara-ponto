-- =====================================================================
-- Migration 014: a janela de repetição passa a comparar cada marcação com a
-- última APROVEITADA, não com a anterior bruta.
--
-- Com a comparação bruta, uma sequência de toques a 110 s um do outro sumia
-- inteira em cascata, inclusive uma batida legítima 3 minutos depois da
-- primeira. Comparando com a última válida, cada toque só é descartado se
-- estiver colado numa marcação que de fato entrou no cálculo.
-- =====================================================================

create or replace function ponto.apurar_dia(p_emp uuid, p_data date)
returns table(
  data date, dia_semana smallint, feriado text, carga_prev_min integer,
  entrada timestamptz, saida_almoco timestamptz, volta_almoco timestamptz, saida timestamptz,
  marcacoes integer, trabalhado_min integer, intervalo_min integer, atraso_min integer,
  saida_antec_min integer, saldo_min integer, falta boolean, apurado boolean,
  abono_min integer, noturno_min integer, inconsistencias text[])
language plpgsql
stable
as $function$
declare
  cfg          ponto.rep%rowtype;
  jd           ponto.jornada_dias%rowtype;
  v_dow        smallint;
  v_escala     char(1);
  m            timestamptz[] := '{}';
  r            record;
  n            integer;
  n_bruto      integer := 0;
  tol          smallint;
  int_min      smallint;
  prev_ent     timestamptz;
  prev_sai     timestamptz;
  probs        text[] := '{}';
  v_tem_jornada boolean;
  -- Janela de repetição. Duas batidas coladas são o mesmo gesto, não um
  -- almoço de 12 segundos. O ARP guarda as duas; a apuração usa a primeira.
  c_dedup_seg  constant integer := 120;
begin
  select * into cfg from ponto.rep limit 1;

  data       := p_data;
  v_dow      := extract(dow from p_data)::smallint;
  dia_semana := v_dow;

  select f.nome into feriado from ponto.feriados f where f.data = p_data limit 1;
  select e.escala_sabado into v_escala from ponto.empregados e where e.id = p_emp;

  select j.tolerancia_min, j.intervalo_min into tol, int_min
    from ponto.empregado_jornada ej
    join ponto.jornadas j on j.id = ej.jornada_id
   where ej.empregado_id = p_emp and ej.vigencia @> p_data limit 1;
  tol := coalesce(tol, 10); int_min := coalesce(int_min, 60);

  select exists(
    select 1 from ponto.empregado_jornada ej
     where ej.empregado_id = p_emp and ej.vigencia @> p_data
  ) into v_tem_jornada;

  if v_dow = 6 then
    if ponto.trabalha_sabado(v_escala, p_data) and feriado is null then
      jd.entrada := cfg.sabado_entrada;
      jd.saida   := cfg.sabado_saida;
      carga_prev_min := cfg.sabado_carga_min;
    else
      carga_prev_min := 0;
    end if;
  else
    select jdd.* into jd
      from ponto.empregado_jornada ej
      join ponto.jornadas j       on j.id = ej.jornada_id
      join ponto.jornada_dias jdd on jdd.jornada_id = j.id and jdd.dia_semana = v_dow
     where ej.empregado_id = p_emp and ej.vigencia @> p_data limit 1;
    carga_prev_min := case when feriado is not null then 0 else coalesce(jd.carga_min, 0) end;
  end if;

  for r in
    select me.horario from ponto.marcacoes_efetivas(p_emp, p_data) me order by me.horario
  loop
    n_bruto := n_bruto + 1;
    if array_length(m, 1) is null
       or r.horario - m[array_length(m, 1)] >= make_interval(secs => c_dedup_seg) then
      m := m || r.horario;
    end if;
  end loop;

  n := coalesce(array_length(m, 1), 0);
  marcacoes := n;

  select coalesce(sum(a.minutos), 0) into abono_min
    from ponto.ajustes a
   where a.empregado_id = p_emp and a.data = p_data
     and a.tipo in ('abono','atestado','ferias','folga') and a.cancelado_em is null;

  if n >= 1 then entrada      := m[1]; end if;
  if n >= 2 then saida_almoco := m[2]; end if;
  if n >= 3 then volta_almoco := m[3]; end if;
  if n >= 4 then saida        := m[4]; end if;
  if n = 2 then saida := m[2]; saida_almoco := null; volta_almoco := null; end if;

  trabalhado_min := 0;
  if n = 2 then
    trabalhado_min := extract(epoch from (m[2] - m[1]))/60;
  elsif n >= 4 then
    trabalhado_min := extract(epoch from (m[2] - m[1]))/60
                    + extract(epoch from (m[4] - m[3]))/60;
  end if;

  intervalo_min := case when n >= 3
    then (extract(epoch from (m[3] - m[2]))/60)::integer else null end;

  atraso_min := 0; saida_antec_min := 0;
  if jd.entrada is not null and entrada is not null then
    prev_ent := (p_data + jd.entrada) at time zone cfg.timezone;
    atraso_min := greatest(0, (extract(epoch from (entrada - prev_ent))/60)::integer);
    if atraso_min <= tol then atraso_min := 0; end if;
  end if;
  if jd.saida is not null and saida is not null then
    prev_sai := (p_data + jd.saida) at time zone cfg.timezone;
    saida_antec_min := greatest(0, (extract(epoch from (prev_sai - saida))/60)::integer);
    if saida_antec_min <= tol then saida_antec_min := 0; end if;
  end if;

  falta   := carga_prev_min > 0 and n = 0 and abono_min = 0;
  apurado := (n = 0 or n = 2 or n = 4);

  if not apurado then
    trabalhado_min := null; intervalo_min := null; saldo_min := null;
  else
    saldo_min := trabalhado_min + abono_min - carga_prev_min;
  end if;

  noturno_min := 0;
  if n >= 2 then
    select coalesce(sum(
      greatest(0, extract(epoch from (
        least(fim, (d::date + time '05:00') at time zone cfg.timezone)
        - greatest(ini, (d::date - 1 + time '22:00') at time zone cfg.timezone)))/60))::integer, 0)
      into noturno_min
      from (values (m[1], m[2]), (case when n>=4 then m[3] end, case when n>=4 then m[4] end))
             as p(ini, fim),
           generate_series(p_data, p_data + 1, '1 day') d
     where p.ini is not null;
  end if;

  if not v_tem_jornada and feriado is null and v_dow between 1 and 5 then
    probs := probs || 'sem jornada cadastrada para este dia'::text;
  end if;
  if n_bruto > n then
    probs := probs || format('%s marcação(ões) repetida(s) desconsiderada(s) na apuração', n_bruto - n)::text;
  end if;
  if n % 2 = 1 then probs := probs || 'número ímpar de marcações'::text; end if;
  if carga_prev_min > 360 and n >= 3 and intervalo_min < int_min then
    probs := probs || format('intervalo de %s min, abaixo do mínimo de %s', intervalo_min, int_min)::text;
  end if;
  if carga_prev_min > 360 and n = 2 then
    probs := probs || 'jornada acima de 6h sem intervalo registrado'::text;
  end if;
  if saldo_min > 120 then
    probs := probs || 'mais de 2h extras no dia (CLT art. 59)'::text;
  end if;
  if n > 4 then probs := probs || format('%s marcações no dia', n)::text; end if;

  inconsistencias := probs;
  return next;
end;
$function$;