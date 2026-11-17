-- ponto_021_termo_por_unidade
-- Rede. Cada unidade (ponto.rep) tem o próprio termo de consentimento de biometria,
-- porque o responsável pelos dados (empregador, CNPJ) muda por unidade.
-- O termo de Jardim América nasce NÃO vigente: o front do ADM ainda carrega
-- "o termo vigente" sem filtrar unidade. Na ativação, remover o índice global
-- termos_um_vigente (fica para a migração que tornar o termo de JA vigente).

alter table ponto.termos add column if not exists rep_id uuid references ponto.rep(id);
update ponto.termos set rep_id = (select id from ponto.rep where unidade = 'taquara')
 where versao = '2026.1' and rep_id is null;
create unique index if not exists termos_um_vigente_por_rep on ponto.termos (rep_id) where vigente;

notify pgrst, 'reload schema';
