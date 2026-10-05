-- =====================================================================
-- PORTAL AGENCIAS — Migración 02 (para portal v0.1.2)
-- Monto a financiar pasa a ser opcional (vacío = máximo disponible)
-- y se elimina "monto solicitado"
-- =====================================================================
alter table consultas alter column monto_a_financiar drop not null;
alter table consultas drop column if exists monto_solicitado;

notify pgrst, 'reload schema';
