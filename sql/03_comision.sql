-- =====================================================================
-- PORTAL AGENCIAS — Migración 03 (para portal v0.1.3 / operador v0.2.0)
-- Comisión por oferta: bruto (banco) / % (interno) / neto (cliente)
-- =====================================================================

-- Neto que le queda al cliente (lo ve la agencia)
alter table ofertas add column if not exists monto_neto numeric;

alter table ofertas
  add constraint ofertas_neto_chk
  check (resultado = 'rechazado' or monto_neto is not null) not valid;

-- La tabla interna pasa a guardar motivo de rechazo Y % de comisión
alter table ofertas_motivos rename to ofertas_internas;
alter table ofertas_internas alter column motivo drop not null;
alter table ofertas_internas
  add column if not exists comision_pct numeric
  check (comision_pct >= 0 and comision_pct < 100);

notify pgrst, 'reload schema';
