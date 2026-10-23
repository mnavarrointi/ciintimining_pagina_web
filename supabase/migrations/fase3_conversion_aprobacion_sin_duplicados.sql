-- FASE 3 / DESARROLLO. No aplicar a la base compartida sin pruebas de regresion.
-- Vincular una proyeccion a un item BORRADOR existente; la solicitud no se aprueba aqui.
create or replace function public.vincular_costo_proyectado_a_giro(p_costo_id uuid,p_solicitud_item_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare c public.exportacion_costos_modelo%rowtype; i public.solicitud_pago_items%rowtype; s public.solicitudes_pago%rowtype;
begin
 if not exists(select 1 from public.usuarios_app u where u.user_id=auth.uid() and u.activo and u.rol in ('admin','tesoreria_pagos')) then raise exception 'Usuario no autorizado'; end if;
 select * into c from public.exportacion_costos_modelo where id=p_costo_id for update;
 if not found or c.estado<>'PROYECTADO' then raise exception 'Costo no disponible'; end if;
 select * into i from public.solicitud_pago_items where id=p_solicitud_item_id for update;
 if not found then raise exception 'Item no encontrado'; end if;
 select * into s from public.solicitudes_pago where id=i.solicitud_id for update;
 if s.estado<>'BORRADOR' or i.estado<>'BORRADOR' then raise exception 'Solo se permite vincular borradores'; end if;
 if c.solicitud_item_id is not null and c.solicitud_item_id<>i.id then raise exception 'Costo vinculado a otro item'; end if;
 if exists(select 1 from public.exportacion_costos_modelo x where x.solicitud_item_id=i.id and x.id<>c.id) then raise exception 'Item ya vinculado'; end if;
 if c.exportacion_id is distinct from i.exportacion_id or c.beneficiario_id is distinct from i.beneficiario_id or c.rubro is distinct from i.rubro_exportacion or c.moneda is distinct from trim(i.moneda) or i.naturaleza_economica is distinct from 'EXPORTACION' then raise exception 'Datos de exportacion, rubro, beneficiario o moneda no coinciden'; end if;
 update public.exportacion_costos_modelo set solicitud_item_id=i.id,updated_at=now() where id=c.id;
 return c.id;
end $$;
revoke all on function public.vincular_costo_proyectado_a_giro(uuid,uuid) from public,anon;
grant execute on function public.vincular_costo_proyectado_a_giro(uuid,uuid) to authenticated;

-- Sincronizar estado del costo al aprobar o anular un item, sin crear asientos.
create or replace function public.sincronizar_costo_proyectado_giro()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if new.estado='APROBADO' and old.estado is distinct from new.estado then
   update public.exportacion_costos_modelo
   set estado='CAUSADO',monto_definitivo=new.valor,fecha_causacion=coalesce(new.fecha_causacion_override,(select fecha_solicitud from public.solicitudes_pago where id=new.solicitud_id)),updated_at=now()
   where solicitud_item_id=new.id and estado='PROYECTADO';
 elsif new.estado in ('ANULADO','CANCELADO','ELIMINADO') and old.estado is distinct from new.estado then
   update public.exportacion_costos_modelo set estado='ANULADO',updated_at=now()
   where solicitud_item_id=new.id and estado='PROYECTADO';
 end if;
 return new;
end $$;
drop trigger if exists trg_sincronizar_costo_proyectado_giro on public.solicitud_pago_items;
create trigger trg_sincronizar_costo_proyectado_giro after update of estado on public.solicitud_pago_items
for each row execute function public.sincronizar_costo_proyectado_giro();

-- Corregir imputacion existente: solamente APROBADO y nunca reemplazar una conciliacion bancaria.
create or replace function public.sincronizar_imputacion_solicitud()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if new.estado not in ('APROBADO') or new.naturaleza_economica is distinct from 'EXPORTACION'
   or new.exportacion_id is null or new.rubro_exportacion is null
   or trim(new.moneda) not in ('PEN','USD') then
   delete from public.exportacion_imputaciones where solicitud_item_id=new.id and origen='SOLICITUD';
   return new;
 end if;
 if exists(select 1 from public.exportacion_imputaciones where solicitud_item_id=new.id and origen='BANCO') then
   delete from public.exportacion_imputaciones where solicitud_item_id=new.id and origen='SOLICITUD';
   return new;
 end if;
 delete from public.exportacion_imputaciones where solicitud_item_id=new.id and origen='SOLICITUD';
 insert into public.exportacion_imputaciones(exportacion_id,rubro,origen,solicitud_item_id,moneda,monto,signo)
 values(new.exportacion_id,new.rubro_exportacion,'SOLICITUD',new.id,trim(new.moneda),new.valor,-1);
 return new;
end $$;

-- Auditoria requerida antes de despliegue: comprobar triggers existentes en INSERT/UPDATE/DELETE,
-- probar re-aprobaciones, anulaciones, conciliaciones parciales y actualizaciones post-conciliacion.
-- Esta migracion NO crea movimientos de tesoreria ni partidas contables nuevas.
