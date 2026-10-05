-- 05/10/2026 · ponto · tipo de ajuste para hora extra de evento.
-- Fica numa migração própria: valor novo de enum não pode ser usado na mesma transação.
alter type ponto.ajuste_tipo add value if not exists 'evento';
