create table public.balance_liquidaciones_proveedor(
 id uuid primary key default gen_random_uuid(),
 proveedor_id uuid not null references public.beneficiarios(id),
 fecha date not null,
 concepto text not null,
 partidas jsonb not null check(jsonb_typeof(partidas)='array'),
 movimientos_bancarios uuid[] not null,
 comentario text,
 created_by uuid not null default auth.uid(),
 created_at timestamptz not null default now(),
 unique(proveedor_id,fecha)
);
alter table public.balance_liquidaciones_proveedor enable row level security;
create policy liquidaciones_proveedor_lectura on public.balance_liquidaciones_proveedor for select to authenticated using (app_private.usuario_app_activo());
create policy liquidaciones_proveedor_crear on public.balance_liquidaciones_proveedor for insert to authenticated with check (app_private.usuario_es_admin() and created_by=auth.uid());
grant select,insert on public.balance_liquidaciones_proveedor to authenticated;
CREATE OR REPLACE FUNCTION public.obtener_balance_fecha_integrado(p_fecha date)
 RETURNS TABLE(posicion_id uuid, codigo text, lado text, categoria text, nombre text, empresa text, moneda character, fuente text, valor_original numeric, tasa_usd numeric, valor_usd numeric, fecha_valor date, actualizado boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
 select b.posicion_id,b.codigo,b.lado,b.categoria,b.nombre,b.empresa,b.moneda,
 case when a.capital is not null or cierre.importe is not null then 'CALCULADA' else b.fuente end,
 b.valor_original-coalesce(a.capital,0)-coalesce(cierre.importe,0),b.tasa_usd,
 case when a.capital is null and cierre.importe is null then b.valor_usd else (b.valor_original-coalesce(a.capital,0)-coalesce(cierre.importe,0))/nullif(b.tasa_usd,0) end,
 greatest(b.fecha_valor,a.fecha,cierre.fecha),b.actualizado
 from (
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
from v_exportacion_partidas_reconocidas p join tasas t on t.moneda=p.moneda where p.tipo='COSTO' and p.fecha<=p_fecha
) b
 left join prestamos_devolucion_condiciones d on d.posicion_id=b.posicion_id
 left join lateral(select sum(x.valor_capital) capital,max(x.fecha) fecha from prestamos_aplicaciones x
 where x.prestamo_id=d.prestamo_id and x.fecha<=p_fecha and x.fecha>=b.fecha_valor) a on true
 left join lateral(select sum((p->>'valor_original')::numeric) importe,max(l.fecha) fecha from public.balance_liquidaciones_proveedor l cross join lateral jsonb_array_elements(l.partidas) p where (p->>'posicion_id')::uuid=b.posicion_id and l.fecha<=p_fecha and l.fecha>=b.fecha_valor) cierre on true;
$function$;
CREATE OR REPLACE FUNCTION public.obtener_partidas_exportacion_fecha(p_fecha date)
 RETURNS TABLE(id text, movimiento_bancario_id uuid, tipo text, moneda text, valor numeric, nombre text, exportacion text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
with cierres as(select * from public.balance_liquidaciones_proveedor where fecha=p_fecha),
 movimientos as(
 select 'LIQ_PROVEEDOR:'||l.id||':BANCO:'||b.id id,b.id movimiento_bancario_id,'BANCO_PROVEEDOR'::text tipo,trim(b.moneda) moneda,-b.valor valor,
 'Liquidación global Prosegur — pago bancario'::text nombre,'Liquidación Prosegur '||l.fecha::text exportacion
 from cierres l join public.movimientos_bancarios b on b.id=any(l.movimientos_bancarios)
 union all
 select 'LIQ_PROVEEDOR:'||l.id||':PASIVO:'||(p->>'posicion_id'),null::uuid,'PASIVO_PROVEEDOR',p->>'moneda',(p->>'valor_original')::numeric,
 'Cancelación pasivo — '||(p->>'nombre'),'Liquidación Prosegur '||l.fecha::text
 from cierres l cross join lateral jsonb_array_elements(l.partidas) p
 ), valorados as(
 select m.*,case when moneda='USD' then valor else valor/nullif((select t.unidades_por_usd from public.tasas_cambio_diarias t where trim(t.moneda)=m.moneda and t.fecha<=p_fecha order by t.fecha desc limit 1),0) end usd
 from movimientos m
 ), diferencia as(
 select exportacion,sum(usd) importe from valorados group by exportacion having bool_and(usd is not null)
 )
 select * from (select 'ANTICIPO:'||r.id::text,c.movimiento_bancario_id,'BANCO_ANTICIPO','USD',r.anticipo_usd,
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
 where c.tipo='BALANCE' and greatest(b.fecha_movimiento,r.fecha)=p_fecha
 union all
 select 'PAGO_MATERIAL:'||p.id,p.movimiento_bancario_id,'BANCO_PAGO_MATERIAL',p.moneda,-p.valor,'Pago material a crédito — '||e.codigo,e.codigo
 from public.v_pagos_credito_material p join public.exportaciones e on e.id=p.exportacion_id where p.fecha=p_fecha
 union all
 select 'AMORTIZA_MATERIAL:'||p.id,null::uuid,'AMORTIZA_MATERIAL',p.moneda,p.valor,'Disminución cuenta por pagar de material — '||e.codigo,e.codigo
 from public.v_pagos_credito_material p join public.exportaciones e on e.id=p.exportacion_id where p.fecha=p_fecha) originales
 union all select id,movimiento_bancario_id,tipo,moneda,valor,nombre,exportacion from movimientos
 union all select 'LIQ_PROVEEDOR:PUENTE:'||exportacion,null::uuid,'PUENTE_PROVEEDOR','USD',-importe,'Contrapartida del ajuste cuentas Prosegur',exportacion from diferencia where abs(importe)>0.000001
 union all select 'LIQ_PROVEEDOR:AJUSTE:'||exportacion,null::uuid,'AJUSTE_PROVEEDOR','USD',importe,'Ajuste cuentas Prosegur',exportacion from diferencia where abs(importe)>0.000001;
$function$;