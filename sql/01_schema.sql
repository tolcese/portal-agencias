-- =====================================================================
-- PORTAL AGENCIAS — Schema v0.2.0
-- Proyecto Supabase NUEVO (independiente de Grupo Olyar)
-- Correr completo en: SQL Editor → New query → Run
-- =====================================================================


-- =====================================================================
-- 1. OPERADORES (vos y el resto del staff)
-- =====================================================================
create table operadores (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  rol text not null default 'operador' check (rol in ('admin','operador')),
  activo boolean not null default true,
  created_at timestamptz default now()
);


-- =====================================================================
-- 2. AGENCIAS (1 usuario = 1 agencia, alta sujeta a aprobación)
-- =====================================================================
create table agencias (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  razon_social text not null,
  cuit text not null,
  responsable text not null,
  telefono text not null,
  localidad text,
  provincia text,
  estado text not null default 'pendiente'
    check (estado in ('pendiente','aprobada','rechazada','suspendida')),
  motivo_estado text,
  aprobado_por uuid references operadores(id),
  aprobado_at timestamptz,
  created_at timestamptz default now()
);

create unique index agencias_cuit_uq on agencias (cuit);


-- =====================================================================
-- 3. BANCOS (lista administrable)
--    provincias = null  → disponible para todas
--    provincias = {...} → solo para agencias de esas provincias
-- =====================================================================
create table bancos (
  id smallint generated always as identity primary key,
  nombre text not null unique,
  admite_uva boolean not null default true,
  requiere_dni boolean not null default false,
  provincias text[],
  activo boolean not null default true,
  orden smallint not null default 0
);

insert into bancos (nombre, admite_uva, requiere_dni, provincias, orden) values
  ('Columbia', false, false, null,          1),
  ('Galicia',  true,  false, null,          2),
  ('ICBC',     true,  true,  null,          3),
  ('Bancor',   true,  false, '{Córdoba}',   4);


-- =====================================================================
-- 4. CONSULTAS
--    banco_id null      → "Todos"
--    plazo_deseado null → "Indistinto (máximo posible)"
-- =====================================================================
create table consultas (
  id bigint generated always as identity primary key,
  agencia_id uuid not null references agencias(id),

  cliente_dni text not null,
  cliente_cuit text,
  cliente_nombre text not null,

  vehiculo_marca text,
  vehiculo_modelo text,
  vehiculo_anio int,
  vehiculo_condicion text check (vehiculo_condicion in ('0km','usado')),
  valor_vehiculo numeric,

  monto_a_financiar numeric not null,
  monto_solicitado numeric,
  plazo_deseado int check (plazo_deseado in (12,18,24,36,48,60)),
  banco_id smallint references bancos(id),

  dni_frente_path text,
  dni_dorso_path text,
  observaciones text,
  consentimiento_datos boolean not null check (consentimiento_datos = true),

  bcra_resultado jsonb,

  estado text not null default 'nueva'
    check (estado in ('nueva','en_analisis','respondida','aceptada','desistida','cerrada')),
  operador_id uuid references operadores(id),
  tomada_at timestamptz,
  respondida_at timestamptz,
  cuota_aceptada_id bigint,

  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index consultas_agencia_idx  on consultas (agencia_id, created_at desc);
create index consultas_estado_idx   on consultas (estado);
create index consultas_operador_idx on consultas (operador_id);


-- =====================================================================
-- 5. OFERTAS (una por banco por consulta)
-- =====================================================================
create table ofertas (
  id bigint generated always as identity primary key,
  consulta_id bigint not null references consultas(id) on delete cascade,
  banco_id smallint not null references bancos(id),
  resultado text not null check (resultado in ('aprobado','rechazado')),
  monto_aprobado numeric,
  vigencia_hasta date,
  requisitos text,                       -- lo ve la agencia
  cargado_por uuid references operadores(id),
  created_at timestamptz default now(),
  unique (consulta_id, banco_id),
  check (resultado = 'rechazado' or monto_aprobado is not null)
);

-- Motivo de rechazo / notas por banco: SOLO operadores
create table ofertas_motivos (
  oferta_id bigint primary key references ofertas(id) on delete cascade,
  motivo text not null
);

-- Cuotas por plazo y tipo de tasa
create table oferta_cuotas (
  id bigint generated always as identity primary key,
  oferta_id bigint not null references ofertas(id) on delete cascade,
  plazo_meses int not null check (plazo_meses between 1 and 120),
  tipo_tasa text not null check (tipo_tasa in ('fija','uva')),
  cuota numeric not null check (cuota > 0),
  unique (oferta_id, plazo_meses, tipo_tasa)
);

alter table consultas
  add constraint consultas_cuota_fk
  foreign key (cuota_aceptada_id) references oferta_cuotas(id);


-- =====================================================================
-- 6. NOTAS INTERNAS POR CONSULTA (solo operadores)
-- =====================================================================
create table consulta_notas (
  id bigint generated always as identity primary key,
  consulta_id bigint not null references consultas(id) on delete cascade,
  operador_id uuid not null references operadores(id),
  nota text not null,
  created_at timestamptz default now()
);


-- =====================================================================
-- 7. HELPERS
-- =====================================================================
create or replace function es_operador() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from operadores where id = auth.uid() and activo)
$$;

create or replace function es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from operadores where id = auth.uid() and activo and rol = 'admin')
$$;

create or replace function agencia_aprobada() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from agencias where id = auth.uid() and estado = 'aprobada')
$$;

-- ¿El operador actual puede modificar esta consulta? (la tomó él, o es admin)
create or replace function puede_editar_consulta(p_consulta bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select es_admin() or exists (
    select 1 from consultas
     where id = p_consulta and operador_id = auth.uid() and es_operador()
  )
$$;

grant execute on function es_operador()               to authenticated;
grant execute on function es_admin()                  to authenticated;
grant execute on function agencia_aprobada()          to authenticated;
grant execute on function puede_editar_consulta(bigint) to authenticated;


-- =====================================================================
-- 8. TRIGGERS
-- =====================================================================

-- updated_at automático
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger consultas_updated_at before update on consultas
  for each row execute function set_updated_at();

-- Alta automática de agencia al registrarse (solo si viene tipo = 'agencia')
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.raw_user_meta_data->>'tipo' = 'agencia' then
    insert into agencias (id, email, razon_social, cuit, responsable, telefono, localidad, provincia)
    values (
      new.id,
      new.email,
      new.raw_user_meta_data->>'razon_social',
      new.raw_user_meta_data->>'cuit',
      new.raw_user_meta_data->>'responsable',
      new.raw_user_meta_data->>'telefono',
      new.raw_user_meta_data->>'localidad',
      new.raw_user_meta_data->>'provincia'
    );
  end if;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Validar banco elegido por la agencia (activo, provincia, DNI si corresponde)
create or replace function validar_consulta_banco() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  b bancos;
  prov text;
begin
  if new.banco_id is null then return new; end if;

  select * into b from bancos where id = new.banco_id;
  if not found or not b.activo then
    raise exception 'Banco no disponible';
  end if;

  if b.provincias is not null then
    select provincia into prov from agencias where id = new.agencia_id;
    if prov is null or not (prov = any (b.provincias)) then
      raise exception 'El banco % no está disponible para tu provincia', b.nombre;
    end if;
  end if;

  if b.requiere_dni and (new.dni_frente_path is null or new.dni_dorso_path is null) then
    raise exception 'Para % hay que adjuntar frente y dorso del DNI', b.nombre;
  end if;

  return new;
end $$;

create trigger consultas_validar_banco before insert on consultas
  for each row execute function validar_consulta_banco();

-- Validar que no se cargue UVA en bancos que no la admiten (ej. Columbia)
create or replace function validar_cuota_uva() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.tipo_tasa = 'uva' and exists (
    select 1 from ofertas o join bancos b on b.id = o.banco_id
     where o.id = new.oferta_id and not b.admite_uva
  ) then
    raise exception 'Este banco solo opera con tasa fija';
  end if;
  return new;
end $$;

create trigger oferta_cuotas_validar_uva before insert or update on oferta_cuotas
  for each row execute function validar_cuota_uva();


-- =====================================================================
-- 9. ACCIONES (RPC) — OPERADORES
-- =====================================================================

-- Tomar consulta: bloqueo atómico, solo si sigue libre
create or replace function tomar_consulta(p_consulta bigint)
returns void language plpgsql security definer set search_path = public as $$
declare quien text;
begin
  if not es_operador() then raise exception 'No autorizado'; end if;

  update consultas
     set estado = 'en_analisis', operador_id = auth.uid(), tomada_at = now()
   where id = p_consulta and estado = 'nueva' and operador_id is null;

  if not found then
    select o.nombre into quien
      from consultas c left join operadores o on o.id = c.operador_id
     where c.id = p_consulta;
    raise exception 'Esta consulta ya la tomó %', coalesce(quien, 'otro operador');
  end if;
end $$;

-- Liberar consulta (el que la tomó, o admin) → vuelve a "nueva"
create or replace function liberar_consulta(p_consulta bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not puede_editar_consulta(p_consulta) then raise exception 'No autorizado'; end if;

  update consultas
     set estado = 'nueva', operador_id = null, tomada_at = null
   where id = p_consulta and estado = 'en_analisis';

  if not found then raise exception 'Solo se pueden liberar consultas en análisis'; end if;
end $$;

-- Enviar respuesta a la agencia (hasta acá las ofertas son borrador)
create or replace function enviar_respuesta(p_consulta bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not puede_editar_consulta(p_consulta) then raise exception 'No autorizado'; end if;

  if not exists (select 1 from ofertas where consulta_id = p_consulta) then
    raise exception 'Cargá al menos un banco antes de enviar';
  end if;

  if exists (
    select 1 from ofertas o
     where o.consulta_id = p_consulta and o.resultado = 'aprobado'
       and not exists (select 1 from oferta_cuotas q where q.oferta_id = o.id)
  ) then
    raise exception 'Hay bancos aprobados sin plazos/cuotas cargados';
  end if;

  update consultas
     set estado = 'respondida', respondida_at = now()
   where id = p_consulta and estado = 'en_analisis';

  if not found then raise exception 'La consulta no está en análisis'; end if;
end $$;

-- Aprobar / rechazar agencia (solo admin)
create or replace function aprobar_agencia(p_agencia uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'No autorizado'; end if;
  update agencias
     set estado = 'aprobada', aprobado_por = auth.uid(), aprobado_at = now(), motivo_estado = null
   where id = p_agencia and estado <> 'aprobada';
end $$;

create or replace function rechazar_agencia(p_agencia uuid, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'No autorizado'; end if;
  update agencias set estado = 'rechazada', motivo_estado = p_motivo where id = p_agencia;
end $$;


-- =====================================================================
-- 10. ACCIONES (RPC) — AGENCIAS
-- =====================================================================

-- Aceptar una opción puntual (banco + plazo + tipo de tasa)
create or replace function agencia_aceptar_opcion(p_consulta bigint, p_cuota bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not agencia_aprobada() then raise exception 'Agencia no habilitada'; end if;

  if not exists (
    select 1
      from consultas c
      join ofertas o       on o.consulta_id = c.id
      join oferta_cuotas q on q.oferta_id = o.id
     where c.id = p_consulta and q.id = p_cuota
       and c.agencia_id = auth.uid()
       and c.estado = 'respondida'
       and o.resultado = 'aprobado'
  ) then
    raise exception 'Opción inválida';
  end if;

  update consultas
     set estado = 'aceptada', cuota_aceptada_id = p_cuota
   where id = p_consulta;
end $$;

create or replace function agencia_desistir(p_consulta bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not agencia_aprobada() then raise exception 'Agencia no habilitada'; end if;

  update consultas
     set estado = 'desistida'
   where id = p_consulta
     and agencia_id = auth.uid()
     and estado in ('nueva','en_analisis','respondida');

  if not found then raise exception 'No se puede desistir esta consulta'; end if;
end $$;

grant execute on function tomar_consulta(bigint)                 to authenticated;
grant execute on function liberar_consulta(bigint)               to authenticated;
grant execute on function enviar_respuesta(bigint)               to authenticated;
grant execute on function aprobar_agencia(uuid)                  to authenticated;
grant execute on function rechazar_agencia(uuid, text)           to authenticated;
grant execute on function agencia_aceptar_opcion(bigint, bigint) to authenticated;
grant execute on function agencia_desistir(bigint)               to authenticated;


-- =====================================================================
-- 11. RLS
-- =====================================================================
alter table operadores      enable row level security;
alter table agencias        enable row level security;
alter table bancos          enable row level security;
alter table consultas       enable row level security;
alter table ofertas         enable row level security;
alter table ofertas_motivos enable row level security;
alter table oferta_cuotas   enable row level security;
alter table consulta_notas  enable row level security;

-- operadores
create policy "op ve operadores" on operadores
  for select using (es_operador());
create policy "admin gestiona operadores" on operadores
  for all using (es_admin()) with check (es_admin());

-- agencias
create policy "agencia ve su ficha" on agencias
  for select using (id = auth.uid());
create policy "operador ve agencias" on agencias
  for select using (es_operador());
create policy "admin edita agencias" on agencias
  for update using (es_admin()) with check (es_admin());

-- bancos
create policy "todos ven bancos" on bancos
  for select using (auth.uid() is not null);
create policy "admin gestiona bancos" on bancos
  for all using (es_admin()) with check (es_admin());

-- consultas
create policy "agencia ve sus consultas" on consultas
  for select using (agencia_id = auth.uid() and agencia_aprobada());
create policy "agencia crea consultas" on consultas
  for insert with check (
    agencia_id = auth.uid() and agencia_aprobada()
    and estado = 'nueva' and operador_id is null
  );
create policy "operador ve consultas" on consultas
  for select using (es_operador());
create policy "operador edita las suyas" on consultas
  for update using (es_admin() or (es_operador() and operador_id = auth.uid()))
  with check   (es_admin() or (es_operador() and operador_id = auth.uid()));

-- ofertas (la agencia solo las ve después de "Enviar respuesta")
create policy "agencia ve ofertas enviadas" on ofertas
  for select using (
    agencia_aprobada() and exists (
      select 1 from consultas c
       where c.id = consulta_id and c.agencia_id = auth.uid()
         and c.estado in ('respondida','aceptada','desistida','cerrada')
    )
  );
create policy "operador ve ofertas" on ofertas
  for select using (es_operador());
create policy "operador carga ofertas de las suyas" on ofertas
  for all using (puede_editar_consulta(consulta_id))
  with check (puede_editar_consulta(consulta_id));

-- motivos internos
create policy "operador ve motivos" on ofertas_motivos
  for select using (es_operador());
create policy "operador carga motivos de las suyas" on ofertas_motivos
  for all using (
    exists (select 1 from ofertas o where o.id = oferta_id and puede_editar_consulta(o.consulta_id))
  ) with check (
    exists (select 1 from ofertas o where o.id = oferta_id and puede_editar_consulta(o.consulta_id))
  );

-- cuotas
create policy "agencia ve cuotas enviadas" on oferta_cuotas
  for select using (
    agencia_aprobada() and exists (
      select 1 from ofertas o join consultas c on c.id = o.consulta_id
       where o.id = oferta_id and c.agencia_id = auth.uid()
         and c.estado in ('respondida','aceptada','desistida','cerrada')
    )
  );
create policy "operador ve cuotas" on oferta_cuotas
  for select using (es_operador());
create policy "operador carga cuotas de las suyas" on oferta_cuotas
  for all using (
    exists (select 1 from ofertas o where o.id = oferta_id and puede_editar_consulta(o.consulta_id))
  ) with check (
    exists (select 1 from ofertas o where o.id = oferta_id and puede_editar_consulta(o.consulta_id))
  );

-- notas internas
create policy "operador ve notas" on consulta_notas
  for select using (es_operador());
create policy "operador agrega notas" on consulta_notas
  for insert with check (es_operador() and operador_id = auth.uid());


-- =====================================================================
-- 12. STORAGE — bucket privado para DNI
--     Ruta: {agencia_id}/{archivo}
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dni', 'dni', false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

create policy "agencia sube a su carpeta" on storage.objects
  for insert with check (
    bucket_id = 'dni'
    and (storage.foldername(name))[1] = auth.uid()::text
    and agencia_aprobada()
  );

create policy "agencia ve su carpeta" on storage.objects
  for select using (
    bucket_id = 'dni'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "operador ve todo dni" on storage.objects
  for select using (bucket_id = 'dni' and es_operador());


-- =====================================================================
-- 13. REALTIME (bandeja en vivo + panel de la agencia)
-- =====================================================================
alter publication supabase_realtime
  add table consultas, ofertas, oferta_cuotas, agencias;


-- =====================================================================
-- 14. Recargar schema de PostgREST
-- =====================================================================
notify pgrst, 'reload schema';
