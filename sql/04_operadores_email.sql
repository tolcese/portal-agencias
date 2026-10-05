-- =====================================================================
-- PORTAL AGENCIAS — Migración 04 (para operador v0.3.0)
-- Email visible en la lista de operadores
-- =====================================================================
alter table operadores add column if not exists email text;

update operadores o
   set email = u.email
  from auth.users u
 where u.id = o.id and o.email is null;

notify pgrst, 'reload schema';
