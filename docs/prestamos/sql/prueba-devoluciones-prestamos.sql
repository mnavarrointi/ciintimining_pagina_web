-- Prueba parametrizada y reversible. No contiene identificadores ni datos de producción.
-- Antes de ejecutar, configurar test.usuario_id, test.prestamo_id, test.movimiento_id
-- y test.total_devolver en una sesión de prueba autorizada.
begin;
do $$
declare p uuid; b uuid; u uuid; v uuid; original numeric; monto numeric;
 total numeric; fecha_pago date; saldo numeric; c numeric; rechazado boolean;
begin
 p:=nullif(current_setting('test.prestamo_id',true),'')::uuid;
 b:=nullif(current_setting('test.movimiento_id',true),'')::uuid;
 u:=nullif(current_setting('test.usuario_id',true),'')::uuid;
 total:=nullif(current_setting('test.total_devolver',true),'')::numeric;
 if p is null or b is null or u is null or total is null then raise exception 'Configura los parámetros de prueba en la sesión autorizada.'; end if;
 perform set_config('request.jwt.claim.sub',u::text,true);
 select capital_inicial into strict original from prestamos_grupo where id=p;
 select fecha_movimiento,valor into strict fecha_pago,monto from movimientos_bancarios where id=b;
 perform guardar_condiciones_prestamo(p,total,(select trim(moneda) from movimientos_bancarios where id=b));
 if not exists(select 1 from buscar_pagos_prestamo(p,'') where id=b) then raise exception 'Falta candidato'; end if;
 v:=vincular_pago_prestamo(p,b);
 if vincular_pago_prestamo(p,b)<>v then raise exception 'No idempotente'; end if;
 select valor_capital into c from prestamos_aplicaciones where id=v;
 if c<>round(original*monto/total,2) then raise exception 'Capital incorrecto'; end if;
 select valor_original into saldo from obtener_balance_fecha_prestamos(fecha_pago-1)
 where posicion_id=(select posicion_id from prestamos_devolucion_condiciones where prestamo_id=p);
 if saldo is distinct from original then raise exception 'Cambió historia anterior'; end if;
 select valor_original into saldo from obtener_balance_fecha_prestamos(fecha_pago)
 where posicion_id=(select posicion_id from prestamos_devolucion_condiciones where prestamo_id=p);
 if saldo is distinct from original-c then raise exception 'No disminuyó pasivo'; end if;
 if (select count(*) from obtener_partidas_prestamos_fecha(fecha_pago) where pareja_id='prestamo-aplicacion:'||v::text)<>2 then raise exception 'Falta contraparte'; end if;
 rechazado:=false;
 begin perform guardar_condiciones_prestamo(p,total+1,'USD');
 exception when others then rechazado:=true; end;
 if not rechazado then raise exception 'Se pudo alterar el total después de vincular'; end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 rechazado:=false;
 begin perform vincular_pago_prestamo(p,b);
 exception when others then rechazado:=true; end;
 if not rechazado then raise exception 'Acceso sin autorización'; end if;
end $$;
rollback;
