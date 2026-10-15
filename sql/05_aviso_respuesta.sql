-- =====================================================================
-- PORTAL AGENCIAS — Migración 05 (para portal v0.1.9)
-- Marca cuándo la agencia vio la respuesta (aviso "Respuesta nueva")
-- =====================================================================
alter table consultas add column if not exists respuesta_vista_at timestamptz;

-- Las consultas ya respondidas antes de esta versión se dan por vistas
update consultas set respuesta_vista_at = now()
 where respondida_at is not null and respuesta_vista_at is null;

-- La agencia marca como vista su propia consulta respondida
create or replace function agencia_marcar_vista(p_consulta bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  update consultas
     set respuesta_vista_at = now()
   where id = p_consulta
     and agencia_id = auth.uid()
     and respondida_at is not null
     and respuesta_vista_at is null;
end $$;

grant execute on function agencia_marcar_vista(bigint) to authenticated;

notify pgrst, 'reload schema';
