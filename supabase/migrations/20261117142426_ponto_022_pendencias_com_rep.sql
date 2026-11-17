-- ponto_022_pendencias_com_rep
-- Rede. v_pendencias ganha rep_id e empregado_id no fim, para a tela de pendências
-- filtrar pela unidade escolhida. Colunas existentes mantidas na mesma ordem.
create or replace view ponto.v_pendencias as
 SELECT c.arp_id,
    e.nome,
    a.dh_marcacao,
    c.sinais_ok,
    c.dentro_cerca,
    c.ip_autorizado,
    c.face_ok,
    c.liveness_ok,
    c.distancia_cerca_m,
    c.observacao,
    c.rep_id,
    c.empregado_id
   FROM ponto.marcacao_contexto c
     JOIN ponto.arp a ON a.id = c.arp_id
     JOIN ponto.empregados e ON e.id = c.empregado_id
  WHERE c.revisao = 'pendente'::ponto.revisao;

notify pgrst, 'reload schema';
