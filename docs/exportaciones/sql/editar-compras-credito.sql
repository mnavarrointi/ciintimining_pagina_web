create or replace function app_private.validar_edicion_compra_credito()
returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 if not app_private.usuario_puede_gestionar_pagos() then raise exception 'Sin autorización para editar compras'; end if;
 if row(new.id,new.exportacion_id,new.modalidad,new.estado,new.created_at,new.created_by)
 is distinct from row(old.id,old.exportacion_id,old.modalidad,old.estado,old.created_at,old.created_by)
 then raise exception 'No se puede cambiar la identidad ni el estado de la compra'; end if;
 perform 1 from public.exportacion_compras_oro where id=old.id for update;
 perform 1 from public.exportacion_liquidaciones_refineria where exportacion_id=old.exportacion_id for update;
 if old.estado<>'ACTIVA' or not exists(select 1 from public.exportaciones where id=old.exportacion_id and estado='EN_CURSO')
 then raise exception 'La compra o exportación no está activa'; end if;
 if exists(select 1 from public.exportacion_vinculos_pago_credito_oro where compra_id=old.id)
 or exists(select 1 from public.exportacion_cobros_refineria where exportacion_id=old.exportacion_id)
 or exists(select 1 from public.exportacion_reconocimientos where exportacion_id=old.exportacion_id)
 then raise exception 'No se puede editar: la compra tiene pagos vinculados o la exportación ya fue conciliada'; end if;
 if not exists(select 1 from public.beneficiarios where id=new.proveedor_id and activo)
 or new.valor_total is null or new.valor_total<=0 or new.moneda is null or new.moneda not in ('PEN','USD')
 or new.moneda_base is null or new.moneda_base not in ('PEN','USD','COP')
 or new.tasa_historica is null or new.tasa_historica<=0 or new.fecha_recepcion is null or new.fecha_estimada_pago is null
 or (new.moneda=new.moneda_base and new.tasa_historica<>1)
 then raise exception 'Datos de compra inválidos'; end if;
 return new;
end $$;
revoke all on function app_private.validar_edicion_compra_credito() from public;
create trigger validar_edicion_compra_credito before update on public.exportacion_compras_oro for each row execute function app_private.validar_edicion_compra_credito();
create policy compras_oro_actualizacion on public.exportacion_compras_oro for update to authenticated
using (app_private.usuario_puede_gestionar_pagos()) with check (app_private.usuario_puede_gestionar_pagos());