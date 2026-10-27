
create table public.exportacion_cobros_refineria (
 id uuid primary key default gen_random_uuid(),
 exportacion_id uuid not null references public.exportacion_liquidaciones_refineria(exportacion_id) on delete restrict,
 tipo text not null check(tipo in ('ANTICIPO','BALANCE')),
 movimiento_bancario_id uuid not null unique references public.movimientos_bancarios(id),
 monto_usd numeric(20,2) not null check(monto_usd>0),
 created_by uuid not null default auth.uid(),
 created_at timestamptz not null default now(),
 unique(exportacion_id,tipo)
);
alter table public.exportacion_cobros_refineria enable row level security;
revoke all on public.exportacion_cobros_refineria from anon;
grant select,insert on public.exportacion_cobros_refineria to authenticated;
create policy cobros_refineria_read on public.exportacion_cobros_refineria for select to authenticated
 using(exists(select 1 from public.usuarios_app u where u.user_id=(select auth.uid()) and u.activo and u.rol in ('admin','consulta','tesoreria_pagos')));
create policy cobros_refineria_insert on public.exportacion_cobros_refineria for insert to authenticated
 with check(created_by=(select auth.uid()) and exists(select 1 from public.usuarios_app u where u.user_id=(select auth.uid()) and u.activo and u.rol='admin'));
create view public.v_ingresos_refineria_disponibles with(security_invoker=true) as
select b.id,b.fecha_movimiento,b.descripcion_original,b.referencia,b.valor,
 trim(b.moneda)::text moneda,cb.banco,cb.nombre_cuenta
from public.movimientos_bancarios b
left join public.cuentas_bancarias cb on cb.id=b.cuenta_bancaria_id
where b.naturaleza='CREDITO' and trim(b.moneda)='USD' and b.valor>0
 and not exists(select 1 from public.exportacion_cobros_refineria r where r.movimiento_bancario_id=b.id)
 and not exists(select 1 from public.exportacion_imputaciones i where i.movimiento_bancario_id=b.id)
 and not exists(select 1 from public.exportacion_aplicaciones_modelo a where a.movimiento_bancario_id=b.id)
 and not exists(select 1 from public.exportacion_vinculos_pago_credito_oro v where v.movimiento_bancario_id=b.id)
 and not exists(select 1 from public.prestamos_aplicaciones p where p.movimiento_bancario_id=b.id)
 and not exists(select 1 from public.transferencias_bancarias_internas t where (t.movimiento_entrada_id=b.id or t.movimiento_salida_id=b.id) and t.estado<>'ANULADA')
 and not exists(select 1 from public.conciliaciones c
 join public.movimientos_tesoreria t on t.id=c.movimiento_tesoreria_id
 left join public.solicitud_pago_items s on s.id=t.solicitud_item_id
 where c.movimiento_bancario_id=b.id and c.estado='CONFIRMADA'
 and t.estado not in ('ANULADO','CANCELADO') and (t.exportacion_id is not null or s.exportacion_id is not null));
revoke all on public.v_ingresos_refineria_disponibles from anon;
grant select on public.v_ingresos_refineria_disponibles to authenticated;

create function public.validar_cobro_refineria() returns trigger language plpgsql
security invoker set search_path=public,pg_temp as $$
declare l public.exportacion_liquidaciones_refineria; esperado numeric;
begin
 select * into l from public.exportacion_liquidaciones_refineria where exportacion_id=NEW.exportacion_id for update;
 if not found then raise exception 'Registra primero la liquidación.'; end if;
 esperado:=case when NEW.tipo='ANTICIPO' then l.anticipo_usd when NEW.tipo='BALANCE' then l.balance_usd else null end;
 perform 1 from public.movimientos_bancarios where id=NEW.movimiento_bancario_id for update;
 if esperado is null or esperado<=0 or NEW.monto_usd<>esperado then raise exception 'El importe debe coincidir con el concepto de la liquidación.'; end if;
 if not exists(select 1 from public.v_ingresos_refineria_disponibles b where b.id=NEW.movimiento_bancario_id and b.valor=esperado and b.moneda='USD')
 then raise exception 'El ingreso no está disponible, ya está vinculado o su valor/moneda no coincide.'; end if;
 return NEW;
end $$;
create trigger validar_cobro_refineria before insert on public.exportacion_cobros_refineria for each row execute function public.validar_cobro_refineria();

create function public.proteger_liquidacion_conciliada() returns trigger language plpgsql
security invoker set search_path=public,pg_temp as $$
begin
 if exists(select 1 from public.exportacion_cobros_refineria c where c.exportacion_id=OLD.exportacion_id
 and (NEW.exportacion_id<>OLD.exportacion_id or c.monto_usd<>case when c.tipo='ANTICIPO' then NEW.anticipo_usd else NEW.balance_usd end))
 then raise exception 'No se puede cambiar el importe de un concepto ya conciliado.'; end if;
 NEW.updated_at:=now();NEW.updated_by:=auth.uid();
 return NEW;
end $$;
create trigger proteger_liquidacion_conciliada before update on public.exportacion_liquidaciones_refineria for each row execute function public.proteger_liquidacion_conciliada();

create function public.buscar_cobros_refineria(p_exportacion_id uuid,p_tipo text,p_busqueda text default '')
returns table(id uuid,fecha_movimiento date,descripcion_original text,referencia text,valor numeric,moneda text,banco text,nombre_cuenta text)
language sql stable security invoker set search_path=public,pg_temp as $$
 select b.* from public.v_ingresos_refineria_disponibles b
 join public.exportacion_liquidaciones_refineria l on l.exportacion_id=p_exportacion_id
 where b.valor=case when p_tipo='ANTICIPO' then l.anticipo_usd when p_tipo='BALANCE' then l.balance_usd else null end
 and (coalesce(p_busqueda,'')='' or concat_ws(' ',b.descripcion_original,b.referencia,b.banco,b.nombre_cuenta) ilike '%'||p_busqueda||'%')
 order by b.fecha_movimiento desc,b.id limit 100;
$$;
create function public.conciliar_cobro_refineria(p_exportacion_id uuid,p_tipo text,p_movimiento_bancario_id uuid)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare l public.exportacion_liquidaciones_refineria; v uuid; previo uuid; importe numeric;
begin
 if not exists(select 1 from public.usuarios_app where user_id=auth.uid() and activo and rol='admin') then raise exception 'Sin permisos para conciliar.'; end if;
 select * into l from public.exportacion_liquidaciones_refineria where exportacion_id=p_exportacion_id for update;
 if not found then raise exception 'Registra primero la liquidación.'; end if;
 select id,movimiento_bancario_id into v,previo from public.exportacion_cobros_refineria where exportacion_id=p_exportacion_id and tipo=p_tipo;
 if found then
  if previo=p_movimiento_bancario_id then return v; end if;
  raise exception 'Este concepto ya está conciliado.';
 end if;
 importe:=case when p_tipo='ANTICIPO' then l.anticipo_usd when p_tipo='BALANCE' then l.balance_usd else null end;
 if importe is null or importe<=0 then raise exception 'El concepto debe ser anticipo o balance con importe positivo.'; end if;
 insert into public.exportacion_cobros_refineria(exportacion_id,tipo,movimiento_bancario_id,monto_usd)
 values(p_exportacion_id,p_tipo,p_movimiento_bancario_id,importe) returning id into v;
 return v;
end $$;
revoke all on function public.validar_cobro_refineria() from PUBLIC,anon;
revoke all on function public.proteger_liquidacion_conciliada() from PUBLIC,anon;
revoke all on function public.buscar_cobros_refineria(uuid,text,text) from PUBLIC,anon;
revoke all on function public.conciliar_cobro_refineria(uuid,text,uuid) from PUBLIC,anon;
grant execute on function public.buscar_cobros_refineria(uuid,text,text),public.conciliar_cobro_refineria(uuid,text,uuid) to authenticated;
notify pgrst,'reload schema';
