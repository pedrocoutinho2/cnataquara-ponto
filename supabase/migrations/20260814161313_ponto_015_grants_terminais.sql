-- A migration 20260813155922 criou ponto.terminais com RLS e policy, mas sem
-- os grants de tabela. Sem SELECT, a Edge Function (service_role) nunca acha
-- o terminal e devolve "aparelho nao autorizado" para qualquer token valido.
grant select, insert, update on ponto.terminais to authenticated;
grant all    on ponto.terminais to service_role;

notify pgrst, 'reload schema';