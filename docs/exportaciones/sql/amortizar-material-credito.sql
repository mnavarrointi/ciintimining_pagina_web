create or replace view public.v_pagos_credito_material with (security_invoker=true) as
 select v.id,v.compra_id,v.movimiento_bancario_id,c.exportacion_id,b.fecha_movimiento fecha,trim(b.moneda) moneda,b.valor
 from public.exportacion_vinculos_pago_credito_oro v join public.exportacion_compras_oro c on c.id=v.compra_id join public.movimientos_bancarios b on b.id=v.movimiento_bancario_id
 where c.estado='ACTIVA' and b.estado_conciliacion='CONCILIADO' and b.naturaleza='DEBITO' and trim(b.moneda)=c.moneda and exists(select 1 from public.conciliaciones x join public.movimientos_tesoreria t on t.id=x.movimiento_tesoreria_id where x.movimiento_bancario_id=b.id and x.estado='CONFIRMADA' and t.estado='PAGADO' and t.exportacion_id=c.exportacion_id and t.rol_exportacion='PAGO_PROVEEDOR_METAL');
grant select on public.v_pagos_credito_material to authenticated;
create or replace view public.v_exportacion_compras_material as  SELECT i.id,
    i.exportacion_id,
    'CONTADO'::text AS modalidad,
    i.movimiento_bancario_id AS origen_id,
    b.fecha_movimiento AS fecha_recepcion,
    TRIM(BOTH FROM i.moneda) AS moneda,
    i.monto AS valor_total,
    COALESCE(( SELECT t.concepto
           FROM conciliaciones c
             JOIN movimientos_tesoreria t ON t.id = c.movimiento_tesoreria_id
          WHERE c.movimiento_bancario_id = b.id AND c.estado = 'CONFIRMADA'::text AND (t.estado <> ALL (ARRAY['ANULADO'::text, 'CANCELADO'::text]))
          ORDER BY c.created_at DESC
         LIMIT 1), b.descripcion_original) AS concepto
   FROM exportacion_imputaciones i
     JOIN movimientos_bancarios b ON b.id = i.movimiento_bancario_id
  WHERE NOT EXISTS(select 1 from public.v_pagos_credito_material pc where pc.movimiento_bancario_id=b.id) AND i.origen = 'BANCO'::text AND i.rubro = 'COMPRA DE MATERIAL'::text AND i.signo = '-1'::integer AND b.naturaleza = 'DEBITO'::text AND b.estado_conciliacion = 'CONCILIADO'::text AND (EXISTS ( SELECT 1
           FROM conciliaciones c
             JOIN movimientos_tesoreria t ON t.id = c.movimiento_tesoreria_id
          WHERE c.movimiento_bancario_id = b.id AND c.estado = 'CONFIRMADA'::text AND (t.estado <> ALL (ARRAY['ANULADO'::text, 'CANCELADO'::text]))))
UNION ALL
 SELECT b.id,
    t.exportacion_id,
    'CONTADO'::text AS modalidad,
    b.id AS origen_id,
    b.fecha_movimiento AS fecha_recepcion,
    TRIM(BOTH FROM b.moneda) AS moneda,
    b.valor AS valor_total,
    replace(t.concepto, 'AXP-025 (ORO SUR DETRACCION)'::text, 'AXP-026 (ORO SUR DETRACCION)'::text) AS concepto
   FROM movimientos_bancarios b
     JOIN LATERAL ( SELECT mt.id,
            mt.numero,
            mt.empresa_id,
            mt.beneficiario_id,
            mt.categoria_id,
            mt.pago_fijo_id,
            mt.cuenta_bancaria_id,
            mt.tipo_movimiento,
            mt.origen,
            mt.concepto,
            mt.fecha_causacion,
            mt.fecha_vencimiento,
            mt.fecha_pago,
            mt.periodo,
            mt.valor_original,
            mt.moneda,
            mt.tasa_cambio,
            mt.valor_base,
            mt.moneda_base,
            mt.estado,
            mt.comentario,
            mt.anulado_motivo,
            mt.fecha_anulacion,
            mt.created_by,
            mt.updated_by,
            mt.created_at,
            mt.updated_at,
            mt.codigo_visible,
            mt.solicitud_item_id,
            mt.clasificacion_operativa,
            mt.impacto_operativo,
            mt.exportacion_id,
            mt.rol_exportacion,
            mt.impacto_pyg_directo,
            mt.rubro_exportacion
           FROM conciliaciones cr
             JOIN movimientos_tesoreria mt ON mt.id = cr.movimiento_tesoreria_id
             JOIN exportaciones e ON e.id = mt.exportacion_id
          WHERE cr.movimiento_bancario_id = b.id AND cr.estado = 'CONFIRMADA'::text AND mt.estado = 'PAGADO'::text AND mt.rol_exportacion = 'COMPRA_METAL'::text AND mt.solicitud_item_id IS NULL AND e.codigo = 'AXP-026'::text
          ORDER BY cr.created_at DESC
         LIMIT 1) t ON true
  WHERE NOT EXISTS(select 1 from public.v_pagos_credito_material pc where pc.movimiento_bancario_id=b.id) AND b.naturaleza = 'DEBITO'::text AND b.estado_conciliacion = 'CONCILIADO'::text AND (TRIM(BOTH FROM b.moneda) = ANY (ARRAY['PEN'::text, 'USD'::text])) AND NOT (EXISTS ( SELECT 1
           FROM exportacion_imputaciones i
          WHERE i.movimiento_bancario_id = b.id))
UNION ALL
 SELECT c.id,
    c.exportacion_id,
    'CREDITO'::text AS modalidad,
    c.id AS origen_id,
    c.fecha_recepcion,
    TRIM(BOTH FROM c.moneda) AS moneda,
    c.valor_total,
    'Material a crédito - '::text || COALESCE(b.nombre, 'Proveedor'::text) AS concepto
   FROM exportacion_compras_oro c
     LEFT JOIN beneficiarios b ON b.id = c.proveedor_id
  WHERE c.modalidad = 'CREDITO'::text AND c.estado = 'ACTIVA'::text;
CREATE OR REPLACE FUNCTION public.vincular_movimiento_compra_oro_credito(p_compra_id uuid, p_movimiento_bancario_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_compra public.exportacion_compras_oro%rowtype; v_mov public.movimientos_bancarios%rowtype; v_id uuid; v_pagado numeric;
begin
 if not exists(select 1 from public.usuarios_app where user_id=auth.uid() and activo and rol in ('admin','tesoreria_pagos')) then raise exception 'Sin permisos'; end if;
 select * into v_mov from public.movimientos_bancarios where id=p_movimiento_bancario_id for update;
 select * into v_compra from public.exportacion_compras_oro where id=p_compra_id and modalidad='CREDITO' and estado='ACTIVA' for update;
 if not found then raise exception 'Compra a credito no activa'; end if;
 select * into v_mov from public.movimientos_bancarios where id=p_movimiento_bancario_id;
 if not found then raise exception 'Movimiento inexistente'; end if;
 if v_mov.moneda<>v_compra.moneda then raise exception 'Monedas distintas'; end if;
 if v_mov.naturaleza<>'DEBITO' then raise exception 'El movimiento debe ser un egreso'; end if;
 if v_mov.estado_conciliacion<>'CONCILIADO' or v_mov.fecha_movimiento<v_compra.fecha_recepcion then raise exception 'El pago debe estar conciliado y ser posterior a la recepción del material'; end if;
 if not exists(select 1 from public.conciliaciones c join public.movimientos_tesoreria t on t.id=c.movimiento_tesoreria_id where c.movimiento_bancario_id=v_mov.id and c.estado='CONFIRMADA' and t.estado='PAGADO' and t.exportacion_id=v_compra.exportacion_id and t.rol_exportacion='PAGO_PROVEEDOR_METAL') then raise exception 'El pago no está conciliado como pago de material de esta exportación'; end if;
 select id into v_id from public.exportacion_vinculos_pago_credito_oro where movimiento_bancario_id=v_mov.id and compra_id=v_compra.id;
 if v_id is not null then return v_id; end if;
 select coalesce(sum(valor),0) into v_pagado from public.v_pagos_credito_material where compra_id=v_compra.id;
 if v_mov.valor<=0 or v_pagado+v_mov.valor>v_compra.valor_total then raise exception 'El pago supera el saldo pendiente de la compra'; end if;
 insert into public.exportacion_vinculos_pago_credito_oro(compra_id,movimiento_bancario_id) values(p_compra_id,p_movimiento_bancario_id)
 on conflict(movimiento_bancario_id) do nothing returning id into v_id;
 if v_id is null then
   select id into v_id from public.exportacion_vinculos_pago_credito_oro where movimiento_bancario_id=p_movimiento_bancario_id and compra_id=p_compra_id;
   if v_id is null then raise exception 'El movimiento ya esta vinculado a otra compra'; end if;
 end if;
 return v_id;
end $function$;
CREATE OR REPLACE FUNCTION public.resolver_movimiento_bancario_flujo_exportacion(p_movimiento_bancario_id uuid, p_exportacion_id uuid, p_rol_exportacion text, p_concepto text, p_cuenta_por_pagar_id uuid DEFAULT NULL::uuid, p_comentario text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_mb public.movimientos_bancarios%rowtype;
  v_exportacion public.exportaciones%rowtype;
  v_empresa_id uuid;
  v_mt_id uuid;
  v_saldo_cxp numeric;
  v_rol text;
  v_compra_id uuid;
begin
  if not app_private.usuario_es_admin() then
    raise exception 'Usuario no autorizado';
  end if;

  v_rol:=upper(trim(coalesce(p_rol_exportacion,'')));

  if v_rol not in (
    'ANTICIPO_CLIENTE','SALDO_CLIENTE','COBRO_CLIENTE',
    'COMPRA_METAL','PAGO_PROVEEDOR_METAL','TRANSPORTE_SEGURIDAD',
    'LABORATORIO','ADUANA','LOGISTICA','IMPUESTO_DIRECTO',
    'COMISION','OTRO_INGRESO','OTRO_COSTO'
  ) then
    raise exception 'Rol de exportacion no valido';
  end if;

  if nullif(trim(coalesce(p_concepto,'')),'') is null then
    raise exception 'El concepto es obligatorio';
  end if;

  select * into v_mb
  from public.movimientos_bancarios
  where id=p_movimiento_bancario_id
  for update;

  if not found then
    raise exception 'Movimiento bancario no encontrado';
  end if;

  if v_mb.estado_conciliacion='CONCILIADO' then
    raise exception 'El movimiento bancario ya esta conciliado';
  end if;

  select * into v_exportacion
  from public.exportaciones
  where id=p_exportacion_id
    and estado in ('EN_CURSO','CERRADA');

  if not found then
    raise exception 'Exportacion no encontrada o no disponible';
  end if;

  select empresa_id into v_empresa_id
  from public.cuentas_bancarias
  where id=v_mb.cuenta_bancaria_id;

  if v_empresa_id is null then
    raise exception 'La cuenta bancaria no tiene empresa asociada';
  end if;

  if v_mb.naturaleza='DEBITO'
     and v_rol in ('ANTICIPO_CLIENTE','SALDO_CLIENTE','COBRO_CLIENTE','OTRO_INGRESO') then
    raise exception 'El rol seleccionado corresponde a un ingreso';
  end if;

  if v_mb.naturaleza='CREDITO'
     and v_rol in ('COMPRA_METAL','PAGO_PROVEEDOR_METAL','TRANSPORTE_SEGURIDAD','LABORATORIO','ADUANA','LOGISTICA','IMPUESTO_DIRECTO','COMISION','OTRO_COSTO') then
    raise exception 'El rol seleccionado corresponde a un egreso';
  end if;

  if v_rol='PAGO_PROVEEDOR_METAL' and p_cuenta_por_pagar_id is null then
    raise exception 'Para pagos de material debes seleccionar la cuenta por pagar';
  end if;

  if p_cuenta_por_pagar_id is not null then
    select id into v_compra_id from public.exportacion_compras_oro where id=p_cuenta_por_pagar_id and exportacion_id=p_exportacion_id and estado='ACTIVA' for update;
    if exists(select 1 from public.exportacion_compras_oro where id=p_cuenta_por_pagar_id) and v_compra_id is null then raise exception 'La compra no pertenece a esta exportación o está inactiva'; end if;
    if v_compra_id is not null and v_rol<>'PAGO_PROVEEDOR_METAL' then raise exception 'Selecciona Pago proveedor / material'; end if;
  end if;
  insert into public.movimientos_tesoreria(
    empresa_id,cuenta_bancaria_id,tipo_movimiento,origen,
    clasificacion_operativa,impacto_operativo,impacto_pyg_directo,
    exportacion_id,rol_exportacion,concepto,
    fecha_causacion,fecha_pago,periodo,valor_original,moneda,
    estado,comentario,created_by,updated_by
  ) values (
    v_empresa_id,v_mb.cuenta_bancaria_id,
    case when v_mb.naturaleza='CREDITO' then 'INGRESO' else 'EGRESO' end,
    'BANCARIO',
    'FLUJO_EXPORTACION',true,false,
    p_exportacion_id,v_rol,trim(p_concepto),
    v_mb.fecha_movimiento,v_mb.fecha_movimiento,date_trunc('month',v_mb.fecha_movimiento)::date,
    v_mb.valor,v_mb.moneda,
    'PAGADO',nullif(trim(coalesce(p_comentario,'')),''),
    auth.uid(),auth.uid()
  )
  returning id into v_mt_id;

  if p_cuenta_por_pagar_id is not null and v_compra_id is null then
    select public.registrar_pago_cxp_exportacion(
      p_cuenta_por_pagar_id,v_mt_id,v_mb.fecha_movimiento,v_mb.valor,
      trim(v_mb.moneda),trim(p_concepto),nullif(trim(coalesce(p_comentario,'')),'')
    ) into v_saldo_cxp;
  end if;

  update public.conciliaciones
  set estado='RECHAZADA',updated_at=now()
  where movimiento_bancario_id=p_movimiento_bancario_id
    and estado='PROPUESTA';

  insert into public.conciliaciones(
    movimiento_bancario_id,movimiento_tesoreria_id,estado,metodo,confianza,
    criterio,comentario,created_by,confirmada_by,confirmada_at
  ) values (
    p_movimiento_bancario_id,v_mt_id,'CONFIRMADA','MANUAL',1.00,
    jsonb_build_object(
      'tipo_resolucion','FLUJO_EXPORTACION',
      'exportacion',v_exportacion.codigo,
      'rol_exportacion',v_rol,
      'cuenta_por_pagar_id',p_cuenta_por_pagar_id,
      'impacto_operativo',true,
      'impacto_pyg_directo',false
    ),
    nullif(trim(coalesce(p_comentario,'')),''),
    auth.uid(),auth.uid(),now()
  );

  update public.movimientos_bancarios
  set estado_conciliacion='CONCILIADO',
      explicacion_automatica='Flujo de exportacion ' || v_exportacion.codigo || ' · ' || v_rol || '. No impacta directamente el PyG.',
      updated_at=now()
  where id=p_movimiento_bancario_id;

  if v_compra_id is not null then
    perform public.vincular_movimiento_compra_oro_credito(v_compra_id,p_movimiento_bancario_id);
    select c.valor_total-coalesce((select sum(p.valor) from public.v_pagos_credito_material p where p.compra_id=c.id),0) into v_saldo_cxp from public.exportacion_compras_oro c where c.id=v_compra_id;
  end if;
  return jsonb_build_object(
    'movimiento_tesoreria_id',v_mt_id,
    'estado','CONCILIADO',
    'clasificacion_operativa','FLUJO_EXPORTACION',
    'exportacion',v_exportacion.codigo,
    'rol_exportacion',v_rol,
    'cuenta_por_pagar_id',p_cuenta_por_pagar_id,
    'saldo_cxp',v_saldo_cxp
  );
end;
$function$;
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
       c.moneda::char(3),'CALCULADA',c.valor_total-coalesce(pagos.valor,0),
       fx.tasa,(c.valor_total-coalesce(pagos.valor,0))/nullif(fx.tasa,0),greatest(c.fecha_recepcion,pagos.fecha),true
from public.v_exportacion_compras_material c
join public.exportaciones e on e.id=c.exportacion_id
left join public.exportacion_compras_oro original on original.id=c.id
left join public.beneficiarios p on p.id=original.proveedor_id
left join lateral (
 select case when c.moneda='USD' then 1::numeric else
 (select t.unidades_por_usd from public.tasas_cambio_diarias t
 where trim(t.moneda)=c.moneda and t.fecha<=p_fecha order by t.fecha desc limit 1) end tasa
) fx on true
left join lateral (select sum(p.valor) valor,max(p.fecha) fecha from public.v_pagos_credito_material p where p.compra_id=c.id and p.fecha<=p_fecha) pagos on true
where c.modalidad='CREDITO' and c.fecha_recepcion<=p_fecha;
$function$;
CREATE OR REPLACE FUNCTION public.obtener_partidas_exportacion_fecha(p_fecha date)
 RETURNS TABLE(id text, movimiento_bancario_id uuid, tipo text, moneda text, valor numeric, nombre text, exportacion text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
 where c.tipo='BALANCE' and greatest(b.fecha_movimiento,r.fecha)=p_fecha
 union all
 select 'PAGO_MATERIAL:'||p.id,p.movimiento_bancario_id,'BANCO_PAGO_MATERIAL',p.moneda,-p.valor,'Pago material a crédito — '||e.codigo,e.codigo
 from public.v_pagos_credito_material p join public.exportaciones e on e.id=p.exportacion_id where p.fecha=p_fecha
 union all
 select 'AMORTIZA_MATERIAL:'||p.id,null::uuid,'AMORTIZA_MATERIAL',p.moneda,p.valor,'Disminución cuenta por pagar de material — '||e.codigo,e.codigo
 from public.v_pagos_credito_material p join public.exportaciones e on e.id=p.exportacion_id where p.fecha=p_fecha;
$function$;