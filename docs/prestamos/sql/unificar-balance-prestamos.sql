-- Aplicar después de devoluciones-prestamos.sql.
-- El Balance integrado es la fuente única. La RPC de préstamos queda como alias compatible.
begin;
CREATE OR REPLACE FUNCTION public.obtener_balance_fecha_integrado(p_fecha date)
 RETURNS TABLE(posicion_id uuid, codigo text, lado text, categoria text, nombre text, empresa text, moneda character, fuente text, valor_original numeric, tasa_usd numeric, valor_usd numeric, fecha_valor date, actualizado boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
 select b.posicion_id,b.codigo,b.lado,b.categoria,b.nombre,b.empresa,b.moneda,
 case when a.capital is not null then 'CALCULADA' else b.fuente end,
 b.valor_original-coalesce(a.capital,0),b.tasa_usd,
 case when a.capital is null then b.valor_usd else (b.valor_original-a.capital)/nullif(b.tasa_usd,0) end,
 greatest(b.fecha_valor,a.fecha),b.actualizado
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
 where x.prestamo_id=d.prestamo_id and x.fecha<=p_fecha and x.fecha>=b.fecha_valor) a on true;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_balance_fecha_prestamos(p_fecha date)
 RETURNS TABLE(posicion_id uuid, codigo text, lado text, categoria text, nombre text, empresa text, moneda character, fuente text, valor_original numeric, tasa_usd numeric, valor_usd numeric, fecha_valor date, actualizado boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select * from public.obtener_balance_fecha_integrado(p_fecha); $function$;
commit;
