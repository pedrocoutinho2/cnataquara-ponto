-- 05/10/2026 · ponto (snipevyvfxaotjhnabmx)
-- 1) Sexta da jornada Tarde passa a 11h às 18h (intervalo 14h às 15h, carga 6h).
--    Manhã já estava 09h às 18h na sexta. Decisão do Pedro, vale para todos.
update ponto.jornada_dias
   set entrada='11:00', saida_almoco='14:00', volta_almoco='15:00', saida='18:00', carga_min=360
 where jornada_id='7aa2e2ea-dd87-44ab-b1bf-21c8269e4fbe' and dia_semana=5;

-- 2) Extrato do banco: passa a mostrar também os dias apurados e ainda não
--    fechados (antes só lia banco_lancamentos, que está vazio, e a tela
--    mostrava "Sem lançamentos"). Mesma assinatura, o front não muda.
create or replace function ponto.extrato_banco(p_emp uuid, p_ini date, p_fim date)
returns table(data date, minutos integer, origem text, observacao text, acumulado integer)
language sql stable as $fn$
  with base as (
    select l.data, l.minutos, l.origem, l.observacao, 0 as ord
      from ponto.banco_lancamentos l
     where l.empregado_id = p_emp and l.data between p_ini and p_fim
    union all
    select a.data,
           case when a.apurado then a.saldo_min else 0 end,
           case when a.apurado then 'apurado (em aberto)' else 'sem apuração (fora da conta)' end,
           case when a.apurado then null else array_to_string(a.inconsistencias, '; ') end,
           1
      from ponto.espelho(p_emp, p_ini, least(p_fim, current_date - 1)) a
     where (not a.apurado or coalesce(a.saldo_min,0) <> 0)
       and not exists (select 1 from ponto.banco_lancamentos b
                        where b.empregado_id = p_emp and b.data = a.data and b.origem = 'apuracao')
  )
  select b.data, b.minutos, b.origem, b.observacao,
         (ponto.saldo_banco(p_emp, p_ini - 1)
          + sum(b.minutos) over (order by b.data, b.ord rows unbounded preceding))::integer
    from base b
   order by b.data, b.ord;
$fn$;

-- 3) Backup de 02/09 com CPF da equipe estava sem RLS. Fecha o acesso sem apagar.
alter table ponto.empregados_bkp_20260902_cap enable row level security;
revoke all on ponto.empregados_bkp_20260902_cap from anon, authenticated;

-- 4) Vínculo de login de um colaborador (dado individual, aplicado direto no banco e fora do repo público).

notify pgrst, 'reload schema';
