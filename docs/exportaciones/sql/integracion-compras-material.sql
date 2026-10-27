-- Aplicado para revisión en desarrollo. No reemplaza las funciones utilizadas por main.
-- No cambia pagos ni snapshots manuales; excluye el snapshot de Oro Sur en el cálculo integrado.
create or replace view public.v_exportacion_compras_material
with (security_invoker=true) as
select i.id, i.exportacion_id, 'CONTADO'::text modalidad,
       i.movimiento_bancario_id origen_id, b.fecha_movimiento fecha_recepcion,
       trim(i.moneda)::text moneda, i.monto valor_total,
       coalesce((select t.concepto from public.conciliaciones c
                 join public.movimientos_tesoreria t on t.id=c.movimiento_tesoreria_id
                 where c.movimiento_bancario_id=b.id and c.estado='CONFIRMADA'
                   and t.estado not in ('ANULADO','CANCELADO')
                 order by c.created_at desc limit 1), b.descripcion_original)::text concepto
from public.exportacion_imputaciones i
join public.movimientos_bancarios b on b.id=i.movimiento_bancario_id
where i.origen='BANCO' and i.rubro='COMPRA DE MATERIAL' and i.signo=-1
  and b.naturaleza='DEBITO' and b.estado_conciliacion='CONCILIADO'
  and exists(select 1 from public.conciliaciones c
             join public.movimientos_tesoreria t on t.id=c.movimiento_tesoreria_id
             where c.movimiento_bancario_id=b.id and c.estado='CONFIRMADA'
               and t.estado not in ('ANULADO','CANCELADO'))
union all
-- Legacy AXP-026 cash purchases already confirmed before structured rubro assignment.
-- Once backfilled, the imputacion branch above takes over without duplicating the bank movement.
select b.id,t.exportacion_id,'CONTADO'::text,b.id,b.fecha_movimiento,
       trim(b.moneda)::text,b.valor,
       replace(t.concepto,'AXP-025 (ORO SUR DETRACCION)','AXP-026 (ORO SUR DETRACCION)')::text
from public.movimientos_bancarios b
join lateral (
 select mt.* from public.conciliaciones cr
 join public.movimientos_tesoreria mt on mt.id=cr.movimiento_tesoreria_id
 join public.exportaciones e on e.id=mt.exportacion_id
 where cr.movimiento_bancario_id=b.id and cr.estado='CONFIRMADA'
   and mt.estado='PAGADO' and mt.rol_exportacion='COMPRA_METAL'
   and mt.solicitud_item_id is null and e.codigo='AXP-026'
 order by cr.created_at desc limit 1
) t on true
where b.naturaleza='DEBITO' and b.estado_conciliacion='CONCILIADO'
 and trim(b.moneda) in ('PEN','USD')
 and not exists(select 1 from public.exportacion_imputaciones i where i.movimiento_bancario_id=b.id)
union all
select c.id,c.exportacion_id,'CREDITO'::text,c.id,c.fecha_recepcion,
       trim(c.moneda)::text,c.valor_total,
       ('Material a crédito - '||coalesce(b.nombre,'Proveedor'))::text
from public.exportacion_compras_oro c
left join public.beneficiarios b on b.id=c.proveedor_id
where c.modalidad='CREDITO' and c.estado='ACTIVA';
revoke all on public.v_exportacion_compras_material from anon;
grant select on public.v_exportacion_compras_material to authenticated;


CREATE OR REPLACE FUNCTION public.obtener_balance_fecha_integrado(p_fecha date)
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

CREATE OR REPLACE FUNCTION public.obtener_variacion_balance_fecha_integrado(p_fecha date)
 RETURNS TABLE(posicion_id uuid, codigo text, lado text, categoria text, nombre text, empresa text, moneda character, valor_anterior numeric, valor_actual numeric, cambio_moneda_original numeric, tasa_anterior numeric, tasa_actual numeric, usd_anterior numeric, usd_actual numeric, cambio_usd_movimiento numeric, cambio_usd_tasa numeric, cambio_usd_total numeric, impacto_patrimonio_usd numeric)
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$
with anterior as (
  select * from public.obtener_balance_fecha_integrado(p_fecha - 1)
),
actual as (
  select * from public.obtener_balance_fecha_integrado(p_fecha)
),
ids as (
  select posicion_id from anterior
  union
  select posicion_id from actual
),
tasas as (
  select x.moneda,
         case
           when x.moneda='USD' then 1::numeric
           else (
             select t.unidades_por_usd
             from public.tasas_cambio_diarias t
             where t.moneda=x.moneda and t.fecha<=p_fecha
             order by t.fecha desc
             limit 1
           )
         end as tasa
  from (values ('COP'::char(3)),('USD'::char(3)),('PEN'::char(3))) x(moneda)
),
base as (
  select
    i.posicion_id,
    bp.cuenta_bancaria_id,
    coalesce(a.codigo,p.codigo) codigo,
    coalesce(a.lado,p.lado) lado,
    coalesce(a.categoria,p.categoria) categoria,
    coalesce(a.nombre,p.nombre) nombre,
    coalesce(a.empresa,p.empresa) empresa,
    coalesce(a.moneda,p.moneda) moneda,
    coalesce(p.valor_original,0) valor_anterior,
    coalesce(a.valor_original,0) valor_actual,
    coalesce(p.tasa_usd,case when coalesce(a.moneda,p.moneda)='USD' then 1 end) tasa_anterior,
    coalesce(a.tasa_usd,case when coalesce(a.moneda,p.moneda)='USD' then 1 end) tasa_actual,
    coalesce(p.valor_usd,0) usd_anterior,
    coalesce(a.valor_usd,0) usd_actual,
    0::numeric ajuste_transferencia
  from ids i
  left join anterior p on p.posicion_id=i.posicion_id
  left join actual a on a.posicion_id=i.posicion_id
  left join public.balance_posiciones bp on bp.id=i.posicion_id
),
calc as (
  select *,
    (valor_actual-valor_anterior)-ajuste_transferencia as cambio_absoluto_moneda,
    case
      when tasa_actual is null or tasa_actual=0 then null
      else ((valor_actual-valor_anterior)-ajuste_transferencia)/tasa_actual
    end as movimiento_usd,
    case
      when tasa_actual is null or tasa_actual=0 or tasa_anterior is null or tasa_anterior=0 then null
      else valor_anterior/tasa_actual-valor_anterior/tasa_anterior
    end as tasa_usd_impacto
  from base
)
select
  posicion_id,codigo,lado,categoria,nombre,empresa,moneda,
  valor_anterior,valor_actual,
  cambio_absoluto_moneda,
  tasa_anterior,tasa_actual,
  usd_anterior,usd_actual,
  movimiento_usd,
  tasa_usd_impacto,
  coalesce(movimiento_usd,0)+coalesce(tasa_usd_impacto,0),
  case
    when lado='PASIVO' then -(coalesce(movimiento_usd,0)+coalesce(tasa_usd_impacto,0))
    else coalesce(movimiento_usd,0)+coalesce(tasa_usd_impacto,0)
  end
from calc
order by case when lado='ACTIVO' then 1 else 2 end,categoria,nombre;
$function$;


revoke all on function public.obtener_balance_fecha_integrado(date) from PUBLIC,anon;
grant execute on function public.obtener_balance_fecha_integrado(date) to authenticated;
revoke all on function public.obtener_variacion_balance_fecha_integrado(date) from PUBLIC,anon;
grant execute on function public.obtener_variacion_balance_fecha_integrado(date) to authenticated;
NOTIFY pgrst, 'reload schema';