CREATE OR REPLACE FUNCTION public.obtener_partidas_exportacion_fecha(p_fecha date)
 RETURNS TABLE(id text, movimiento_bancario_id uuid, tipo text, moneda text, valor numeric, nombre text, exportacion text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
with compras_contado as(
 select distinct on (c.origen_id) c.* from public.v_exportacion_compras_material c
 where c.modalidad='CONTADO' and c.fecha_recepcion=p_fecha order by c.origen_id,c.id
 ), cierres as(select * from public.balance_liquidaciones_proveedor where fecha=p_fecha),
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
 union all select 'LIQ_PROVEEDOR:AJUSTE:'||exportacion,null::uuid,'AJUSTE_PROVEEDOR','USD',importe,'Ajuste cuentas Prosegur',exportacion from diferencia where abs(importe)>0.000001
 union all
 select 'BANCO_COMPRA_CONTADO:'||c.origen_id,c.origen_id,'BANCO_COMPRA_CONTADO',c.moneda,-c.valor_total,'Pago compra al contado — '||c.concepto,e.codigo
 from compras_contado c join public.exportaciones e on e.id=c.exportacion_id
 union all
 select 'ALTA_INVENTARIO_CONTADO:'||c.origen_id,null::uuid,'ALTA_INVENTARIO_CONTADO',c.moneda,c.valor_total,'Aumento inventario de oro — '||c.concepto,e.codigo
 from compras_contado c join public.exportaciones e on e.id=c.exportacion_id;
$function$;