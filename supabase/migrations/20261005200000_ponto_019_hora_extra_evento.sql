-- 05/10/2026 · ponto (snipevyvfxaotjhnabmx)
-- Hora extra de evento: trabalho fora do relógio (evento, feira, ação em escola),
-- lançado pela coordenação com início e fim, para uma ou várias pessoas de uma vez.
-- Entra como ajuste tipo 'evento' (horario = início, minutos = duração) e soma
-- ao trabalhado do dia, inclusive adicional noturno. Pode ser alterado e cancelado
-- como qualquer ajuste.
-- Pré-requisito, aplicado antes em migração separada (enum novo não pode ser usado na mesma transação):
--   alter type ponto.ajuste_tipo add value if not exists 'evento';

do $mig$
declare d text;
begin
  -- apurar_dia: soma evento ao trabalhado, ao noturno e tira a falta
  d := pg_get_functiondef('ponto.apurar_dia'::regproc);
  assert (length(d) - length(replace(d, $o$  v_tem_jornada boolean;$o$, ''))) / length($o$  v_tem_jornada boolean;$o$) = 1, 'ancora 1';
  d := replace(d, $o$  v_tem_jornada boolean;$o$, $n$  v_tem_jornada boolean;
  v_evento_min  integer := 0;$n$);

  assert position($o$     and a.tipo in ('abono','atestado','ferias','folga') and a.cancelado_em is null;$o$ in d) > 0, 'ancora 2';
  d := replace(d, $o$     and a.tipo in ('abono','atestado','ferias','folga') and a.cancelado_em is null;$o$,
$n$     and a.tipo in ('abono','atestado','ferias','folga') and a.cancelado_em is null;

  -- Hora extra de evento: trabalho fora do relogio, lancado pela coordenacao
  -- com inicio e duracao. Soma ao trabalhado do dia.
  select coalesce(sum(a.minutos), 0) into v_evento_min
    from ponto.ajustes a
   where a.empregado_id = p_emp and a.data = p_data
     and a.tipo = 'evento' and a.cancelado_em is null;$n$);

  assert position($o$  falta   := carga_prev_min > 0 and n = 0 and abono_min = 0;$o$ in d) > 0, 'ancora 3';
  d := replace(d, $o$  falta   := carga_prev_min > 0 and n = 0 and abono_min = 0;$o$,
                  $n$  falta   := carga_prev_min > 0 and n = 0 and abono_min = 0 and v_evento_min = 0;$n$);

  assert position($o$    saldo_min := trabalhado_min + abono_min - carga_prev_min;$o$ in d) > 0, 'ancora 4';
  d := replace(d, $o$    saldo_min := trabalhado_min + abono_min - carga_prev_min;$o$,
$n$    trabalhado_min := trabalhado_min + v_evento_min;
    saldo_min := trabalhado_min + abono_min - carga_prev_min;$n$);

  assert position($o$  if not v_isento then
    if not v_tem_jornada$o$ in d) > 0, 'ancora 5';
  d := replace(d, $o$  if not v_isento then
    if not v_tem_jornada$o$, $n$  if v_evento_min > 0 then
    noturno_min := noturno_min + coalesce((
      select sum(greatest(0, extract(epoch from (
        least(a.horario + make_interval(mins => a.minutos), (dd::date + time '05:00') at time zone cfg.timezone)
        - greatest(a.horario, (dd::date - 1 + time '22:00') at time zone cfg.timezone)))/60))::integer
        from ponto.ajustes a, generate_series(p_data, p_data + 1, '1 day') dd
       where a.empregado_id = p_emp and a.data = p_data and a.tipo = 'evento'
         and a.cancelado_em is null and a.horario is not null), 0);
  end if;

  if not v_isento then
    if not v_tem_jornada$n$);
  execute d;

  -- alterar_ajuste: evento guarda início (horario) e duração (minutos)
  d := pg_get_functiondef('ponto.alterar_ajuste'::regproc);
  assert position($o$  if p_tipo = 'insercao' then
    if p_horario is null$o$ in d) > 0, 'ancora 6';
  d := replace(d, $o$  if p_tipo = 'insercao' then
    if p_horario is null$o$, $n$  if p_tipo in ('insercao','evento') then
    if p_horario is null$n$);
  assert position($o$  elsif coalesce(p_minutos,0) <= 0 then$o$ in d) > 0, 'ancora 7';
  d := replace(d, $o$  elsif coalesce(p_minutos,0) <= 0 then$o$, $n$  end if;
  if p_tipo <> 'insercao' and coalesce(p_minutos,0) <= 0 then$n$);
  assert position($o$          case when p_tipo = 'insercao' then p_horario end,$o$ in d) > 0, 'ancora 8';
  d := replace(d, $o$          case when p_tipo = 'insercao' then p_horario end,$o$,
                  $n$          case when p_tipo in ('insercao','evento') then p_horario end,$n$);
  execute d;
end
$mig$;

create or replace function ponto.lancar_evento(
  p_emps uuid[], p_data date, p_inicio time, p_fim time, p_nome text)
returns jsonb language plpgsql security definer
set search_path to 'ponto','public' as $fn$
declare
  v_eu uuid; v_tz text; v_ini timestamptz; v_fim timestamptz; v_min integer;
  v_emp uuid; n integer := 0;
begin
  if not ponto.eh_coordenacao() then
    raise exception 'Só a coordenação pode lançar hora extra de evento.';
  end if;
  v_eu := ponto.empregado_atual();
  if v_eu is null then
    raise exception 'Seu login nao esta ligado a um cadastro de pessoa. Vincule na aba Equipe antes de lancar ajuste.';
  end if;
  if length(coalesce(btrim(p_nome),'')) < 3 then raise exception 'Informe o nome do evento.'; end if;
  if p_emps is null or cardinality(p_emps) = 0 then raise exception 'Escolha pelo menos uma pessoa.'; end if;
  if p_data is null or p_inicio is null or p_fim is null then raise exception 'Informe data, início e fim do evento.'; end if;

  select timezone into v_tz from ponto.rep limit 1;
  v_ini := (p_data + p_inicio) at time zone v_tz;
  v_fim := (p_data + p_fim) at time zone v_tz;
  if v_fim <= v_ini then v_fim := v_fim + interval '1 day'; end if;  -- passou da meia-noite
  v_min := (extract(epoch from (v_fim - v_ini)) / 60)::integer;
  if v_min < 15 or v_min > 16 * 60 then raise exception 'Duração do evento fora do plausível (de 15 min a 16 h).'; end if;

  foreach v_emp in array p_emps loop
    insert into ponto.ajustes (empregado_id, data, tipo, horario, minutos, justificativa, criado_por)
    values (v_emp, p_data, 'evento', v_ini, v_min, 'Evento: ' || btrim(p_nome), v_eu);
    n := n + 1;
  end loop;

  insert into ponto.auditoria (ator, acao, alvo, detalhe)
  values (auth.uid(), 'lancar_evento', p_data::text,
          jsonb_build_object('nome', p_nome, 'pessoas', p_emps, 'inicio', p_inicio, 'fim', p_fim, 'minutos', v_min));

  return jsonb_build_object('ok', true, 'pessoas', n, 'minutos', v_min);
end;
$fn$;

revoke all on function ponto.lancar_evento(uuid[], date, time, time, text) from public, anon;
grant execute on function ponto.lancar_evento(uuid[], date, time, time, text) to authenticated;

notify pgrst, 'reload schema';
