
create table public.exportacion_reconocimientos (
 id uuid primary key default gen_random_uuid(),
 exportacion_id uuid not null unique references public.exportaciones(id),
 anticipo_cobro_id uuid not null unique references public.exportacion_cobros_refineria(id),
 fecha date not null,
 anticipo_usd numeric(20,2) not null,
 balance_usd numeric(20,2) not null,
 material jsonb not null,
 costos jsonb not null,
 created_by uuid not null default auth.uid(),
 created_at timestamptz not null default now()
);
alter table public.exportacion_reconocimientos enable row level security;
revoke all on public.exportacion_reconocimientos from PUBLIC,anon,authenticated;
grant select,insert on public.exportacion_reconocimientos to authenticated;
create policy reconocimientos_read on public.exportacion_reconocimientos for select to authenticated using(
 exists(select 1 from usuarios_app where user_id=(select auth.uid()) and activo and rol in ('admin','consulta','tesoreria_pagos')));
create policy reconocimientos_insert on public.exportacion_reconocimientos for insert to authenticated with check(
 created_by=(select auth.uid()) and exists(select 1 from usuarios_app where user_id=(select auth.uid()) and activo and rol='admin'));

create function public.reconocer_exportacion_por_anticipo() returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
declare fecha_banco date; l public.exportacion_liquidaciones_refineria; materiales jsonb; proyectados jsonb;
begin
 if NEW.tipo<>'ANTICIPO' then return NEW;end if;
 select fecha_movimiento into fecha_banco from movimientos_bancarios where id=NEW.movimiento_bancario_id;
 select * into l from exportacion_liquidaciones_refineria where exportacion_id=NEW.exportacion_id;
 if l.balance_usd<0 then raise exception 'El balance negativo requiere definir un flujo de devolución antes de reconocer la exportación.';end if;
 select coalesce(jsonb_agg(to_jsonb(m)),'[]'::jsonb) into materiales from v_exportacion_compras_material m
 where m.exportacion_id=NEW.exportacion_id and m.fecha_recepcion<=fecha_banco;
 if jsonb_array_length(materiales)=0 then raise exception 'No hay compras de material recibidas a la fecha del anticipo.';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'beneficiario_id',c.beneficiario_id,
 'nombre',coalesce(b.nombre,c.concepto),'concepto',c.concepto,'moneda',c.moneda,'valor',c.monto_proyectado)),'[]'::jsonb)
 into proyectados from exportacion_costos_modelo c left join beneficiarios b on b.id=c.beneficiario_id
 where c.exportacion_id=NEW.exportacion_id and c.estado='PROYECTADO' and c.monto_proyectado>0
 and not exists(select 1 from balance_posiciones p where p.activo and
 (p.metadata->>'costo_id'=c.id::text or p.metadata->>'costo_proyectado_id'=c.id::text));
 insert into exportacion_reconocimientos(exportacion_id,anticipo_cobro_id,fecha,anticipo_usd,balance_usd,material,costos)
 values(NEW.exportacion_id,NEW.id,fecha_banco,l.anticipo_usd,l.balance_usd,materiales,proyectados);
 return NEW;
end $$;
create trigger reconocer_exportacion_por_anticipo after insert on public.exportacion_cobros_refineria
 for each row execute function public.reconocer_exportacion_por_anticipo();
revoke all on function public.reconocer_exportacion_por_anticipo() from PUBLIC,anon;

create view public.v_exportacion_partidas_reconocidas with(security_invoker=true) as
select r.id reconocimiento_id,r.exportacion_id,r.fecha,'INVENTARIO'::text tipo,
 (m->>'id')::uuid origen_id,m->>'moneda' moneda,(m->>'valor_total')::numeric valor,
 'Salida de material — '||e.codigo||' — '||(m->>'concepto') nombre
from exportacion_reconocimientos r join exportaciones e on e.id=r.exportacion_id
cross join lateral jsonb_array_elements(r.material)m
union all
select r.id,r.exportacion_id,r.fecha,'COSTO', (c->>'id')::uuid,c->>'moneda',(c->>'valor')::numeric,
 (c->>'nombre')||' — '||e.codigo||' — '||(c->>'concepto')
from exportacion_reconocimientos r join exportaciones e on e.id=r.exportacion_id
cross join lateral jsonb_array_elements(r.costos)c;
revoke all on public.v_exportacion_partidas_reconocidas from PUBLIC,anon;
grant select on public.v_exportacion_partidas_reconocidas to authenticated;

CREATE OR REPLACE FUNCTION public.obtener_balance_fecha_compras(p_fecha date)
 RETURNS TABLE(posicion_id uuid, codigo text, lado text, categoria text, nombre text, empresa text, moneda character, fuente text, valor_original numeric, tasa_usd numeric, valor_usd numeric, fecha_valor date, actualizado boolean)
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$
with base as (
 select * from public.obtener_balance_fecha(p_fecha)
), compras as (
 select moneda,sum(valor_total) valor,max(fecha_recepcion) fecha
 from public.v_exportacion_compras_material
 where fecha_recepcion<=p_fecha group by moneda
), inventario as (
 select b.*,
   case
     -- The legacy snapshot represented Oro Sur, now taken from confirmed purchases.
     -- Keep the stored history untouched for main; exclude it only in the integrated calculation.
     when b.codigo='ACT_ORO_PEN' and b.fecha_valor=date '2026-09-30'
          and b.valor_original=190677.71 and c.moneda is not null then 0::numeric
     else coalesce(b.valor_original,0)
   end residual,
   c.valor compra_valor,c.fecha compra_fecha
 from base b
 left join compras c on b.codigo='ACT_ORO_'||c.moneda
)
select b.posicion_id,b.codigo,b.lado,b.categoria,b.nombre,b.empresa,b.moneda,
       case when b.compra_valor is not null then 'CALCULADA' else b.fuente end,
       case when b.compra_valor is not null then b.residual+b.compra_valor else b.valor_original end,
       b.tasa_usd,
       case when b.compra_valor is not null then (b.residual+b.compra_valor)/nullif(b.tasa_usd,0) else b.valor_usd end,
       case when b.compra_valor is not null then greatest(b.fecha_valor,b.compra_fecha) else b.fecha_valor end,
       b.actualizado or b.compra_valor is not null
from inventario b
union all
select c.id,'CREDITO_ORO_'||c.id::text,'PASIVO','CUENTAS POR PAGAR',
       coalesce(p.nombre,c.concepto)||' — '||e.codigo,null::text,
       c.moneda::char(3),'CALCULADA',c.valor_total,
       fx.tasa,c.valor_total/nullif(fx.tasa,0),c.fecha_recepcion,true
from public.v_exportacion_compras_material c
join public.exportaciones e on e.id=c.exportacion_id
left join public.exportacion_compras_oro original on original.id=c.id
left join public.beneficiarios p on p.id=original.proveedor_id
left join lateral (
 select case when c.moneda='USD' then 1::numeric else
 (select t.unidades_por_usd from public.tasas_cambio_diarias t
 where trim(t.moneda)=c.moneda and t.fecha<=p_fecha order by t.fecha desc limit 1) end tasa
) fx on true
where c.modalidad='CREDITO' and c.fecha_recepcion<=p_fecha;
$function$;
revoke all on function public.obtener_balance_fecha_compras(date) from PUBLIC,anon;
grant execute on function public.obtener_balance_fecha_compras(date) to authenticated;

CREATE OR REPLACE FUNCTION public.obtener_balance_fecha_integrado(p_fecha date)
 RETURNS TABLE(posicion_id uuid, codigo text, lado text, categoria text, nombre text, empresa text, moneda character, fuente text, valor_original numeric, tasa_usd numeric, valor_usd numeric, fecha_valor date, actualizado boolean)
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$
with b as(select * from public.obtener_balance_fecha_compras(p_fecha)),
salidas as(
 select moneda,sum(valor) valor,max(fecha) fecha from public.v_exportacion_partidas_reconocidas
 where tipo='INVENTARIO' and fecha<=p_fecha group by moneda
), base as (
 select b.*,s.valor salida,s.fecha salida_fecha from b left join salidas s on b.codigo='ACT_ORO_'||s.moneda
), tasas as(
 select m.moneda,case when m.moneda='USD' then 1::numeric else
 (select unidades_por_usd from tasas_cambio_diarias t where trim(t.moneda)=m.moneda and t.fecha<=p_fecha order by fecha desc limit 1) end tasa
 from (values('USD'),('PEN'),('COP'))m(moneda)
)
select posicion_id,codigo,lado,categoria,nombre,empresa,moneda,
 case when salida is not null then 'CALCULADA' else fuente end,
 case when salida is not null then valor_original-salida else valor_original end,
 tasa_usd,case when salida is not null then (valor_original-salida)/nullif(tasa_usd,0) else valor_usd end,
 case when salida is not null then greatest(fecha_valor,salida_fecha) else fecha_valor end,actualizado
from base
union all
select r.id,'CXC_REFINERIA_'||r.exportacion_id::text,'ACTIVO','CUENTAS POR COBRAR',
 'Refinería — balance pendiente — '||e.codigo,null::text,'USD'::char(3),'CALCULADA',
 case when exists(select 1 from exportacion_cobros_refineria c join movimientos_bancarios mb on mb.id=c.movimiento_bancario_id
 where c.exportacion_id=r.exportacion_id and c.tipo='BALANCE' and mb.fecha_movimiento<=p_fecha) then 0 else r.balance_usd end,
 1::numeric,
 case when exists(select 1 from exportacion_cobros_refineria c join movimientos_bancarios mb on mb.id=c.movimiento_bancario_id
 where c.exportacion_id=r.exportacion_id and c.tipo='BALANCE' and mb.fecha_movimiento<=p_fecha) then 0 else r.balance_usd end,
 r.fecha,true
from exportacion_reconocimientos r join exportaciones e on e.id=r.exportacion_id where r.fecha<=p_fecha
union all
select p.origen_id,'CXP_COSTO_EXPORT_'||p.origen_id::text,'PASIVO','CUENTAS POR PAGAR',
 p.nombre,null::text,p.moneda::char(3),'CALCULADA',p.valor,t.tasa,p.valor/nullif(t.tasa,0),p.fecha,true
from v_exportacion_partidas_reconocidas p join tasas t on t.moneda=p.moneda where p.tipo='COSTO' and p.fecha<=p_fecha;
$function$;


create function public.obtener_partidas_exportacion_fecha(p_fecha date)
returns table(id text,movimiento_bancario_id uuid,tipo text,moneda text,valor numeric,nombre text,exportacion text)
language sql stable security invoker set search_path=public,pg_temp as $$
 select 'ANTICIPO:'||r.id::text,c.movimiento_bancario_id,'BANCO_ANTICIPO','USD',r.anticipo_usd,
 'Anticipo recibido — '||e.codigo,e.codigo
 from exportacion_reconocimientos r join exportacion_cobros_refineria c on c.id=r.anticipo_cobro_id join exportaciones e on e.id=r.exportacion_id where r.fecha=p_fecha
 union all
 select p.tipo||':'||p.origen_id::text,null::uuid,p.tipo,p.moneda,-p.valor,p.nombre,e.codigo
 from v_exportacion_partidas_reconocidas p join exportaciones e on e.id=p.exportacion_id where p.fecha=p_fecha
 union all
 select 'CXC:'||r.id::text,null::uuid,'CXC','USD',r.balance_usd,'Cuenta por cobrar — balance refinería — '||e.codigo,e.codigo
 from exportacion_reconocimientos r join exportaciones e on e.id=r.exportacion_id where r.fecha=p_fecha
 union all
 select 'BANCO_BALANCE:'||c.id::text,c.movimiento_bancario_id,'BANCO_BALANCE','USD',c.monto_usd,'Cobro del balance — '||e.codigo,e.codigo
 from exportacion_cobros_refineria c join exportacion_reconocimientos r on r.exportacion_id=c.exportacion_id
 join movimientos_bancarios b on b.id=c.movimiento_bancario_id join exportaciones e on e.id=c.exportacion_id
 where c.tipo='BALANCE' and b.fecha_movimiento=p_fecha and r.fecha<=p_fecha
 union all
 select 'CANCELA_CXC:'||c.id::text,null::uuid,'CANCELA_CXC','USD',-c.monto_usd,'Cancelación cuenta por cobrar — '||e.codigo,e.codigo
 from exportacion_cobros_refineria c join exportacion_reconocimientos r on r.exportacion_id=c.exportacion_id
 join movimientos_bancarios b on b.id=c.movimiento_bancario_id join exportaciones e on e.id=c.exportacion_id
 where c.tipo='BALANCE' and greatest(b.fecha_movimiento,r.fecha)=p_fecha;
$$;
revoke all on function public.obtener_partidas_exportacion_fecha(date) from PUBLIC,anon;
grant execute on function public.obtener_partidas_exportacion_fecha(date) to authenticated;
notify pgrst,'reload schema';


create function public.proteger_liquidacion_reconocida() returns trigger
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 if exists(select 1 from exportacion_reconocimientos r where r.exportacion_id=OLD.exportacion_id)
 and (NEW.exportacion_id is distinct from OLD.exportacion_id
 or NEW.anticipo_usd is distinct from OLD.anticipo_usd
 or NEW.balance_usd is distinct from OLD.balance_usd)
 then raise exception 'La exportación ya fue reconocida en Balance. Los importes requieren un ajuste o reversión del reconocimiento.';end if;
 return NEW;
end $$;
create trigger proteger_liquidacion_reconocida before update on public.exportacion_liquidaciones_refineria
 for each row execute function public.proteger_liquidacion_reconocida();
revoke all on function public.proteger_liquidacion_reconocida() from PUBLIC,anon;
