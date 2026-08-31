-- Fonte de hora do relogio do PWA. O cabecalho Date da resposta HTTP nao
-- serve: em requisicao cross-origin o navegador so expoe os cabecalhos da
-- lista segura do CORS, e Date nao esta nela. Sem isso o cliente lia null,
-- caia no epoch e o relogio marcava 21:00 de 31/12/1969.
create or replace function ponto.agora()
returns timestamptz
language sql
stable
as $function$ select now() $function$;

revoke all on function ponto.agora() from public;
grant execute on function ponto.agora() to anon, authenticated;

notify pgrst, 'reload schema';