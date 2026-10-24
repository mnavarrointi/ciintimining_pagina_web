-- Fase 3: preparar vinculacion de costos proyectados con items de giro.
-- No ejecutar en produccion antes de pruebas de aprobacion y conciliacion.
-- No modifica balances, imputaciones ni movimientos bancarios.
create or replace function public.vincular_costo_proyectado_a_giro(
  p_costo_id uuid,
  p_solicitud_item_id uuid
) returns uuid
language plpgsql security invoker
set search_path = public, pg_temp
as $$
declare
  v_costo public.exportacion_costos_modelo%rowtype;
  v_item public.solicitud_pago_items%rowtype;
  v_solicitud public.solicitudes_pago%rowtype;
begin
  if not exists (
    select 1 from public.usuarios_app u
    where u.user_id = auth.uid() and u.activo
      and u.rol in ('admin','tesoreria_pagos')
  ) then
    raise exception 'Usuario no autorizado';
  end if;

  select * into v_costo
  from public.exportacion_costos_modelo
  where id = p_costo_id for update;
  if not found then raise exception 'Costo no encontrado'; end if;

  select * into v_item from public.solicitud_pago_items
  where id = p_solicitud_item_id for update;
  if not found then raise exception 'Item de solicitud no encontrado'; end if;

  select * into v_solicitud from public.solicitudes_pago
  where id = v_item.solicitud_id for update;
  if v_solicitud.estado <> 'BORRADOR' or v_item.estado <> 'BORRADOR' then
    raise exception 'La vinculacion solo es posible en borrador';
  end if;
  if v_costo.estado <> 'PROYECTADO' then
    raise exception 'El costo ya no esta proyectado';
  end if;
  if v_costo.solicitud_item_id is not null
     and v_costo.solicitud_item_id <> p_solicitud_item_id then
    raise exception 'Costo ya vinculado a otro item';
  end if;
  if v_costo.exportacion_id is distinct from v_item.exportacion_id
     or v_costo.beneficiario_id is distinct from v_item.beneficiario_id
     or v_costo.rubro is distinct from v_item.rubro_exportacion
     or v_costo.moneda is distinct from trim(v_item.moneda)
     or v_item.naturaleza_economica <> 'EXPORTACION' then
    raise exception 'Exportacion, beneficiario, rubro, moneda o naturaleza no coinciden';
  end if;
  update public.exportacion_costos_modelo
  set solicitud_item_id = p_solicitud_item_id,
      updated_at = now()
  where id = p_costo_id;
  return p_costo_id;
end $$;

revoke all on function public.vincular_costo_proyectado_a_giro(uuid,uuid) from public, anon;
grant execute on function public.vincular_costo_proyectado_a_giro(uuid,uuid) to authenticated;

-- PENDIENTE antes de activar:
-- 1. Cambiar sincronizar_imputacion_solicitud: solo APROBADO,
--    excluir items ya representados por imputaciones bancarias.
-- 2. Al aprobar, actualizar costo a CAUSADO y monto_definitivo = valor del item.
-- 3. Ajustar lectura gerencial para incluir proyeccion vinculada mientras sea BORRADOR;
--    al aprobar, reemplazarla por imputacion aprobada.
-- 4. Pruebas de idempotencia, anulacion y pagos parciales.
