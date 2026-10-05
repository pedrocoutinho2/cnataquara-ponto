-- 05/10/2026 · ponto (snipevyvfxaotjhnabmx)
-- Ajuste passa a poder ser ALTERADO. Por baixo, a alteração cancela o ajuste
-- antigo e cria o novo na mesma transação, ligados por `substitui`. Assim o
-- histórico exigido pela Portaria 671/2021 continua inteiro, mas para quem usa
-- é uma edição só, sem pedir motivo de cancelamento.

alter table ponto.ajustes add column if not exists substitui uuid references ponto.ajustes(id);

create or replace function ponto.alterar_ajuste(
  p_ajuste uuid, p_tipo ponto.ajuste_tipo, p_horario timestamptz,
  p_minutos integer, p_justificativa text)
returns jsonb language plpgsql security definer
set search_path to 'ponto','public' as $fn$
declare
  v_eu uuid; v_old ponto.ajustes%rowtype; v_novo uuid; v_tz text;
begin
  if not ponto.eh_coordenacao() then
    raise exception 'Só a coordenação pode alterar um ajuste.';
  end if;
  v_eu := ponto.empregado_atual();
  if v_eu is null then
    raise exception 'Seu login nao esta ligado a um cadastro de pessoa. Vincule na aba Equipe antes de alterar ajuste.';
  end if;
  if length(coalesce(btrim(p_justificativa),'')) < 5 then
    raise exception 'Escreva a justificativa do ajuste.';
  end if;

  select * into v_old from ponto.ajustes where id = p_ajuste and cancelado_em is null for update;
  if not found then raise exception 'Ajuste não encontrado ou já cancelado.'; end if;
  if v_old.tipo = 'desconsiderar' or p_tipo = 'desconsiderar' then
    raise exception 'Desconsideração de marcação não se altera: cancele ou use Corrigir horário na marcação.';
  end if;

  select timezone into v_tz from ponto.rep limit 1;
  if p_tipo = 'insercao' then
    if p_horario is null then raise exception 'Informe o horário da marcação.'; end if;
    if (p_horario at time zone v_tz)::date <> v_old.data then
      raise exception 'O horário precisa ser no mesmo dia do ajuste.';
    end if;
  elsif coalesce(p_minutos,0) <= 0 then
    raise exception 'Informe quantos minutos.';
  end if;

  update ponto.ajustes
     set cancelado_em = now(), cancelado_por = v_eu,
         cancelamento_motivo = 'Substituído por alteração'
   where id = p_ajuste;

  insert into ponto.ajustes (empregado_id, data, tipo, horario, minutos, justificativa, criado_por, substitui)
  values (v_old.empregado_id, v_old.data, p_tipo,
          case when p_tipo = 'insercao' then p_horario end,
          case when p_tipo = 'insercao' then null else p_minutos end,
          btrim(p_justificativa), v_eu, p_ajuste)
  returning id into v_novo;

  insert into ponto.auditoria (ator, acao, alvo, detalhe)
  values (auth.uid(), 'alterar_ajuste', p_ajuste::text, jsonb_build_object(
    'novo', v_novo,
    'antes', jsonb_build_object('tipo', v_old.tipo, 'horario', v_old.horario, 'minutos', v_old.minutos, 'justificativa', v_old.justificativa),
    'depois', jsonb_build_object('tipo', p_tipo, 'horario', p_horario, 'minutos', p_minutos, 'justificativa', p_justificativa)));

  return jsonb_build_object('ok', true, 'novo_id', v_novo);
end;
$fn$;

-- Marcação original (ARP) é imutável por lei. "Corrigir horário" desconsidera a
-- batida original e insere o horário certo, na mesma transação.
create or replace function ponto.corrigir_marcacao(p_arp uuid, p_horario timestamptz, p_justificativa text)
returns jsonb language plpgsql security definer
set search_path to 'ponto','public' as $fn$
declare
  v_eu uuid; v_arp ponto.arp%rowtype; v_tz text; v_data date; v_novo uuid; v_desc uuid;
begin
  if not ponto.eh_coordenacao() then
    raise exception 'Só a coordenação pode corrigir uma marcação.';
  end if;
  v_eu := ponto.empregado_atual();
  if v_eu is null then
    raise exception 'Seu login nao esta ligado a um cadastro de pessoa. Vincule na aba Equipe antes de alterar ajuste.';
  end if;
  if length(coalesce(btrim(p_justificativa),'')) < 5 then
    raise exception 'Escreva a justificativa do ajuste.';
  end if;
  if p_horario is null then raise exception 'Informe o horário da marcação.'; end if;

  select * into v_arp from ponto.arp where id = p_arp;
  if not found then raise exception 'Marcação não encontrada.'; end if;
  select timezone into v_tz from ponto.rep limit 1;
  v_data := (v_arp.dh_marcacao at time zone v_tz)::date;
  if (p_horario at time zone v_tz)::date <> v_data then
    raise exception 'O horário precisa ser no mesmo dia da marcação.';
  end if;
  if exists (select 1 from ponto.ajustes where arp_id = p_arp and tipo = 'desconsiderar' and cancelado_em is null) then
    raise exception 'Esta marcação já foi desconsiderada.';
  end if;

  insert into ponto.ajustes (empregado_id, data, tipo, arp_id, justificativa, criado_por)
  values (v_arp.empregado_id, v_data, 'desconsiderar', p_arp, btrim(p_justificativa), v_eu)
  returning id into v_desc;
  insert into ponto.ajustes (empregado_id, data, tipo, horario, justificativa, criado_por, substitui)
  values (v_arp.empregado_id, v_data, 'insercao', p_horario, btrim(p_justificativa), v_eu, v_desc)
  returning id into v_novo;

  insert into ponto.auditoria (ator, acao, alvo, detalhe)
  values (auth.uid(), 'corrigir_marcacao', p_arp::text,
          jsonb_build_object('original', v_arp.dh_marcacao, 'novo', p_horario, 'insercao', v_novo));

  return jsonb_build_object('ok', true, 'novo_id', v_novo);
end;
$fn$;

revoke all on function ponto.alterar_ajuste(uuid, ponto.ajuste_tipo, timestamptz, integer, text) from public, anon;
revoke all on function ponto.corrigir_marcacao(uuid, timestamptz, text) from public, anon;
grant execute on function ponto.alterar_ajuste(uuid, ponto.ajuste_tipo, timestamptz, integer, text) to authenticated;
grant execute on function ponto.corrigir_marcacao(uuid, timestamptz, text) to authenticated;

notify pgrst, 'reload schema';
