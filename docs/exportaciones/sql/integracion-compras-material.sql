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

CREATE OR REPLACE FUNCTION public.obtener_balance_fecha(p_fecha date)
 RETURNS TABLE(posicion_id uuid, codigo text, lado text, categoria text, nombre text, empresa text, moneda character, fuente text, valor_original numeric, tasa_usd numeric, valor_usd numeric, fecha_valor date, actualizado boolean)
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$
with fx as (
 select x.moneda, case when x.moneda='USD' then 1::numeric else (select t.unidades_por_usd from public.tasas_cambio_diarias t where t.moneda=x.moneda and t.fecha<=p_fecha order by t.fecha desc limit 1) end tasa
 from (values ('COP'::char(3)),('USD'::char(3)),('PEN'::char(3))) x(moneda)
), manuales as (
 select distinct on (bv.posicion_id) bv.posicion_id,bv.fecha_efectiva,bv.valor from public.balance_valores bv where bv.fecha_efectiva<=p_fecha order by bv.posicion_id,bv.fecha_efectiva desc
), bancos as (
 select bp.id posicion_id,
        case when base.saldo_inicial is null then null
             else base.saldo_inicial + coalesce((
               select sum(case when mb.naturaleza='CREDITO' then mb.valor else -mb.valor end)
               from public.movimientos_bancarios mb
               where mb.cuenta_bancaria_id=bp.cuenta_bancaria_id
                 and mb.fecha_movimiento>=base.periodo
                 and mb.fecha_movimiento<=p_fecha
             ),0) end valor,
        p_fecha fecha_valor,
        base.saldo_inicial is not null tiene_base
 from public.balance_posiciones bp
 left join lateral (
   select sim.periodo,sim.saldo_inicial
   from public.saldos_iniciales_mensuales sim
   where sim.cuenta_bancaria_id=bp.cuenta_bancaria_id
     and sim.periodo<=date_trunc('month',p_fecha)::date
   order by sim.periodo desc limit 1
 ) base on true
 where bp.fuente='BANCO' and bp.activo
), amortizaciones as (
 select a.posicion_id,
        coalesce(sum(a.valor_cop) filter(where a.tipo='RECEPCION_COP_PENDIENTE'),0) - coalesce(sum(a.valor_cop) filter(where a.tipo='MONETIZACION_DEFINITIVA'),0) cop_pendiente,
        coalesce(sum(a.valor_usd_definitivo) filter(where a.tipo='MONETIZACION_DEFINITIVA'),0) usd_definitivo,
        max(a.fecha) fecha_ultima
 from public.balance_amortizaciones_cxc a
 where a.fecha<=p_fecha
 group by a.posicion_id
), transito as (
 select coalesce(sum(case when t.moneda_origen='USD' then t.valor_origen else 0 end),0)::numeric valor
 from public.transferencias_bancarias_internas t
 join public.movimientos_bancarios salida on salida.id=t.movimiento_salida_id
 left join public.movimientos_bancarios entrada on entrada.id=t.movimiento_entrada_id
 where t.estado='EMPAREJADA'
   and salida.fecha_movimiento<=p_fecha
   and (entrada.fecha_movimiento>p_fecha or entrada.id is null)
), compras_material as (
 select moneda,sum(valor_total) valor,max(fecha_recepcion) fecha
 from public.v_exportacion_compras_material
 where fecha_recepcion<=p_fecha group by moneda
), valores as (
 select bp.id posicion_id,
        case
          when bp.codigo='PAS_AJUSTE_TEMP_FALCON' and p_fecha>=date '2026-09-28' then 0::numeric
          when bp.codigo='ACT_MONETIZACION' and p_fecha>=date '2026-09-29' then (select valor from transito)
          when bp.codigo='ACT_ORO_'||trim(bp.moneda) and cm.moneda is not null
            then coalesce(m.valor,0)+cm.valor
          when bp.fuente='BANCO' then b.valor
          when bp.moneda='USD' and a.posicion_id is not null then
            m.valor - a.usd_definitivo - case when a.cop_pendiente>0 then a.cop_pendiente / nullif((select tasa from fx where moneda='COP'),0) else 0 end
          else m.valor
        end valor,
        case
          when bp.codigo='PAS_AJUSTE_TEMP_FALCON' and p_fecha>=date '2026-09-28' then date '2026-09-28'
          when bp.codigo='ACT_MONETIZACION' and p_fecha>=date '2026-09-29' then p_fecha
          when bp.codigo='ACT_ORO_'||trim(bp.moneda) and cm.moneda is not null
            then greatest(m.fecha_efectiva,cm.fecha)
          when bp.fuente='BANCO' then b.fecha_valor
          else greatest(m.fecha_efectiva,coalesce(a.fecha_ultima,m.fecha_efectiva))
        end fecha_valor,
        case
          when bp.codigo='PAS_AJUSTE_TEMP_FALCON' and p_fecha>=date '2026-09-28' then true
          when bp.codigo='ACT_MONETIZACION' and p_fecha>=date '2026-09-29' then true
          when bp.codigo='ACT_ORO_'||trim(bp.moneda) and cm.moneda is not null then true
          when bp.fuente='BANCO' then coalesce(b.tiene_base,false)
          else m.fecha_efectiva is not null
        end actualizado
 from public.balance_posiciones bp
 left join compras_material cm on cm.moneda=trim(bp.moneda)
 left join manuales m on m.posicion_id=bp.id
 left join bancos b on b.posicion_id=bp.id
 left join amortizaciones a on a.posicion_id=bp.id
 where bp.activo
)
select * from (
select bp.id,bp.codigo,bp.lado,bp.categoria,bp.nombre,e.nombre_corto,bp.moneda,
       case when a.posicion_id is not null or
 (bp.codigo='ACT_ORO_'||trim(bp.moneda) and exists(
 select 1 from compras_material cm where cm.moneda=trim(bp.moneda)))
 then 'CALCULADA' else bp.fuente end,
       v.valor,fx.tasa,
       case when v.valor is null or fx.tasa is null then null else v.valor/fx.tasa end,
       v.fecha_valor,v.actualizado
from public.balance_posiciones bp
left join public.empresas e on e.id=bp.empresa_id
left join valores v on v.posicion_id=bp.id
left join amortizaciones a on a.posicion_id=bp.id
left join fx on fx.moneda=bp.moneda
where bp.activo
union all
select c.id,'CREDITO_ORO_'||c.id::text,'PASIVO','CUENTAS POR PAGAR',
       c.concepto,null::text,c.moneda::char(3),'CALCULADA',
       c.valor_total,fx.tasa,c.valor_total/nullif(fx.tasa,0),
       c.fecha_recepcion,true
from public.v_exportacion_compras_material c
left join fx on fx.moneda=c.moneda::char(3)
where c.modalidad='CREDITO' and c.fecha_recepcion<=p_fecha
) resultado
order by case when lado='ACTIVO' then 1 else 2 end,categoria,nombre;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_variacion_balance_fecha(p_fecha date)
 RETURNS TABLE(posicion_id uuid, codigo text, lado text, categoria text, nombre text, empresa text, moneda character, valor_anterior numeric, valor_actual numeric, cambio_moneda_original numeric, tasa_anterior numeric, tasa_actual numeric, usd_anterior numeric, usd_actual numeric, cambio_usd_movimiento numeric, cambio_usd_tasa numeric, cambio_usd_total numeric, impacto_patrimonio_usd numeric)
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$
with anterior as (
  select * from public.obtener_balance_fecha(p_fecha - 1)
),
actual as (
  select * from public.obtener_balance_fecha(p_fecha)
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

-- Backfill confirmed cash purchases from their original bank movements.
insert into public.exportacion_imputaciones
(exportacion_id,rubro,origen,movimiento_bancario_id,moneda,monto,signo)
select t.exportacion_id,'COMPRA DE MATERIAL','BANCO',b.id,trim(b.moneda),b.valor,-1
from public.movimientos_tesoreria t
join public.conciliaciones c on c.movimiento_tesoreria_id=t.id and c.estado='CONFIRMADA'
join public.movimientos_bancarios b on b.id=c.movimiento_bancario_id
join public.exportaciones e on e.id=t.exportacion_id
where e.codigo='AXP-026' and t.rol_exportacion='COMPRA_METAL'
 and t.estado='PAGADO' and t.solicitud_item_id is null
 and b.estado_conciliacion='CONCILIADO' and b.naturaleza='DEBITO'
on conflict (movimiento_bancario_id) do update set
 exportacion_id=excluded.exportacion_id,rubro=excluded.rubro,
 moneda=excluded.moneda,monto=excluded.monto,signo=excluded.signo;
-- Convert the replaced manual inventory snapshot to residual inventory.
-- The original amount is retained explicitly in the comment.
update public.balance_valores v set valor=0,
 comentario='Migración a inventario derivado de compras AXP-026. Saldo manual reemplazado: PEN 190677.71; Oro Sur conciliado: PEN 190642.20. Saldo residual manual: 0.',
 fuente_referencia='MIGRACION_INVENTARIO_COMPRAS_AXP026',updated_at=now()
from public.balance_posiciones p
where v.posicion_id=p.id and p.codigo='ACT_ORO_PEN'
 and v.fecha_efectiva='2026-09-30' and v.valor=190677.71;

-- Correct the cash purchase description; the export link already points to AXP-026.
update public.movimientos_tesoreria t set
 concepto='PAGO DE MATERIAL AXP-026 (ORO SUR DETRACCION)',updated_at=now()
from public.exportaciones e
where t.exportacion_id=e.id and e.codigo='AXP-026'
 and t.concepto='PAGO DE MATERIAL AXP-025 (ORO SUR DETRACCION)'
 and t.valor_original=2860 and t.moneda='PEN';
