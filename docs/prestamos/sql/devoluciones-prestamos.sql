
create table public.prestamos_devolucion_condiciones (
 prestamo_id uuid primary key references public.prestamos_grupo(id),
 total_devolver numeric(20,2) not null check(total_devolver>0),
 moneda text not null check(moneda in ('COP','USD','PEN')),
 posicion_id uuid not null unique references public.balance_posiciones(id),
 created_at timestamptz not null default now(),
 created_by uuid default auth.uid()
);
alter table public.prestamos_devolucion_condiciones enable row level security;
revoke all on public.prestamos_devolucion_condiciones from anon;
grant select,insert,update on public.prestamos_devolucion_condiciones to authenticated;
create policy condiciones_lectura on public.prestamos_devolucion_condiciones for select to authenticated using ((select app_private.usuario_app_activo()));
create policy condiciones_creacion on public.prestamos_devolucion_condiciones for insert to authenticated with check ((select app_private.usuario_es_admin()));
create policy condiciones_edicion on public.prestamos_devolucion_condiciones for update to authenticated using ((select app_private.usuario_es_admin())) with check ((select app_private.usuario_es_admin()));

create or replace function public.validar_condiciones_devolucion_prestamo()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare p prestamos_grupo; bp balance_posiciones;
begin
 if app_private.usuario_es_admin() is not true then raise exception 'Sin permisos para modificar préstamos.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(new.prestamo_id::text,0));
 if TG_OP='UPDATE' and new.prestamo_id<>old.prestamo_id then raise exception 'No se puede cambiar el préstamo.'; end if;
 select * into strict p from prestamos_grupo where id=new.prestamo_id;
 select * into strict bp from balance_posiciones where id=new.posicion_id and activo
 and metadata->>'prestamo_id'=p.id::text;
 if trim(bp.moneda)<>p.moneda or bp.lado<>case when p.tipo='POR_PAGAR' then 'PASIVO' else 'ACTIVO' end then
 raise exception 'La posición del Balance no corresponde al préstamo.'; end if;
 if exists(select 1 from prestamos_aplicaciones where prestamo_id=p.id) then
 raise exception 'El total y la moneda quedan fijos desde el primer pago vinculado.'; end if;
 return new;
end $$;
create trigger validar_condiciones_devolucion before insert or update on public.prestamos_devolucion_condiciones
 for each row execute function public.validar_condiciones_devolucion_prestamo();

create or replace function public.guardar_condiciones_prestamo(p_prestamo_id uuid,p_total numeric,p_moneda text)
returns void language plpgsql set search_path=public,pg_temp as $$
declare pos uuid;
begin
 if app_private.usuario_es_admin() is not true then raise exception 'Sin permisos.'; end if;
 select id into strict pos from balance_posiciones where activo and metadata->>'prestamo_id'=p_prestamo_id::text;
 insert into prestamos_devolucion_condiciones(prestamo_id,total_devolver,moneda,posicion_id)
 values(p_prestamo_id,p_total,p_moneda,pos)
 on conflict(prestamo_id) do update set total_devolver=excluded.total_devolver,moneda=excluded.moneda;
end $$;

create or replace function public.buscar_pagos_prestamo(p_prestamo_id uuid,p_busqueda text default '')
returns table(id uuid,fecha date,valor numeric,moneda text,descripcion text,banco text,beneficiario text)
language sql stable set search_path=public,pg_temp as $$
 select b.id,b.fecha_movimiento,b.valor,trim(b.moneda),b.descripcion_original,cb.banco,
 (select be.nombre from conciliaciones c join movimientos_tesoreria mt on mt.id=c.movimiento_tesoreria_id
 left join beneficiarios be on be.id=mt.beneficiario_id where c.movimiento_bancario_id=b.id and c.estado='CONFIRMADA' limit 1)
 from movimientos_bancarios b join cuentas_bancarias cb on cb.id=b.cuenta_bancaria_id
 join prestamos_devolucion_condiciones d on trim(b.moneda)=d.moneda
 join prestamos_grupo p on p.id=d.prestamo_id
 where p.id=p_prestamo_id and b.fecha_movimiento>=p.fecha_inicio
 and b.estado_conciliacion='CONCILIADO'
 and b.naturaleza=case when p.tipo='POR_PAGAR' then 'DEBITO' else 'CREDITO' end
 and b.id is distinct from p.movimiento_origen_id
 and not exists(select 1 from balance_valores v where v.fuente_referencia='DEVOLUCION_PRESTAMO:'||b.id::text)
 and b.categoria_bancaria is null
 and coalesce(b.naturaleza_patrimonial,'NO_DETERMINADO') in ('NO_DETERMINADO','TRANSFERENCIA_NO_OPERATIVA')
 and exists(select 1 from conciliaciones c join movimientos_tesoreria m on m.id=c.movimiento_tesoreria_id
 where c.movimiento_bancario_id=b.id and c.estado='CONFIRMADA' and m.estado<>'ANULADO'
 and m.exportacion_id is null and coalesce(m.clasificacion_operativa,'PAGO_EGRESO') in ('PAGO_EGRESO','INGRESO','TRANSFERENCIA_NO_OPERATIVA'))
 and not exists(select 1 from prestamos_aplicaciones a where a.movimiento_bancario_id=b.id)
 and not exists(select 1 from prestamos_grupo q where q.movimiento_origen_id=b.id)
 and not exists(select 1 from exportacion_cobros_refineria x where x.movimiento_bancario_id=b.id)
 and not exists(select 1 from transferencias_bancarias_internas t where t.estado='EMPAREJADA' and b.id in (t.movimiento_salida_id,t.movimiento_entrada_id))
 and not exists(select 1 from exportacion_vinculos_pago_credito_oro x where x.movimiento_bancario_id=b.id)
 and b.valor<=d.total_devolver-coalesce((select sum(a.valor_pagado) from prestamos_aplicaciones a where a.prestamo_id=p.id),0)
 and (coalesce(p_busqueda,'')='' or concat_ws(' ',b.descripcion_original,b.referencia,cb.banco,
 (select string_agg(m.concepto,' ') from conciliaciones c join movimientos_tesoreria m on m.id=c.movimiento_tesoreria_id where c.movimiento_bancario_id=b.id and c.estado='CONFIRMADA'))
 ilike '%'||p_busqueda||'%')
 order by b.fecha_movimiento desc,b.id;
$$;

create or replace function public.validar_aplicacion_prestamo()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare p prestamos_grupo; d prestamos_devolucion_condiciones; b movimientos_bancarios;
 pagado numeric; capital numeric; tramo numeric;
begin
 if app_private.usuario_es_admin() is not true then raise exception 'Sin permisos para vincular pagos.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(new.prestamo_id::text,0));
 select * into strict p from prestamos_grupo where id=new.prestamo_id;
 select * into strict d from prestamos_devolucion_condiciones where prestamo_id=p.id;
 select * into strict b from movimientos_bancarios where id=new.movimiento_bancario_id for update;
 if not exists(select 1 from buscar_pagos_prestamo(p.id,'') x where x.id=b.id) then
 raise exception 'El pago no está disponible: revisa moneda, conciliación, saldo y vínculos previos.'; end if;
 if exists(select 1 from balance_valores where posicion_id=d.posicion_id and fecha_efectiva>=b.fecha_movimiento) then
 raise exception 'Existe un saldo manual posterior o del mismo día: revisar antes de amortizar para evitar duplicados.'; end if;
 select coalesce(sum(valor_pagado),0),coalesce(sum(valor_capital),0) into pagado,capital
 from prestamos_aplicaciones where prestamo_id=p.id;
 tramo:=round(p.capital_inicial*(pagado+b.valor)/d.total_devolver,2)-capital;
 if tramo<=0 or capital+tramo>p.capital_inicial then raise exception 'El pago supera el capital o no permite una amortización válida.'; end if;
 new.fecha:=b.fecha_movimiento; new.valor_pagado:=b.valor; new.moneda_pago:=d.moneda; new.valor_capital:=tramo;
 update movimientos_bancarios set naturaleza_patrimonial='TRANSFERENCIA_NO_OPERATIVA' where id=b.id;
 update movimientos_tesoreria m set clasificacion_operativa='TRANSFERENCIA_NO_OPERATIVA',impacto_operativo=false,impacto_pyg_directo=false
 where exists(select 1 from conciliaciones c where c.movimiento_bancario_id=b.id and c.estado='CONFIRMADA' and c.movimiento_tesoreria_id=m.id);
 update solicitud_pago_items i set naturaleza_economica='TRANSFERENCIA_NO_OPERATIVA'
 where exists(select 1 from movimientos_tesoreria m join conciliaciones c on c.movimiento_tesoreria_id=m.id
 where c.estado='CONFIRMADA' and c.movimiento_bancario_id=b.id and m.solicitud_item_id=i.id);
 return new;
end $$;
create trigger validar_aplicacion_prestamo before insert on public.prestamos_aplicaciones
 for each row execute function public.validar_aplicacion_prestamo();

create or replace function public.vincular_pago_prestamo(p_prestamo_id uuid,p_movimiento_id uuid)
returns uuid language plpgsql set search_path=public,pg_temp as $$
declare v uuid; otro uuid;
begin
 if app_private.usuario_es_admin() is not true then raise exception 'Sin permisos.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_prestamo_id::text,0));
 select id,prestamo_id into v,otro from prestamos_aplicaciones where movimiento_bancario_id=p_movimiento_id;
 if found then
 if otro=p_prestamo_id then return v; end if;
 raise exception 'Este pago ya pertenece a otro préstamo.';
 end if;
 insert into prestamos_aplicaciones(prestamo_id,movimiento_bancario_id,fecha,valor_capital,moneda_pago,valor_pagado,nota)
 values(p_prestamo_id,p_movimiento_id,current_date,1,'USD',1,'Vinculado desde Préstamos: fecha e importes verificados contra el extracto.')
 returning id into v; return v;
end $$;

create or replace function public.obtener_balance_fecha_prestamos(p_fecha date)
returns table(posicion_id uuid,codigo text,lado text,categoria text,nombre text,empresa text,moneda char(3),fuente text,valor_original numeric,tasa_usd numeric,valor_usd numeric,fecha_valor date,actualizado boolean)
language sql stable set search_path=public,pg_temp as $$
 select b.posicion_id,b.codigo,b.lado,b.categoria,b.nombre,b.empresa,b.moneda,
 case when a.capital is not null then 'CALCULADA' else b.fuente end,
 b.valor_original-coalesce(a.capital,0),b.tasa_usd,
 (b.valor_original-coalesce(a.capital,0))/nullif(b.tasa_usd,0),
 greatest(b.fecha_valor,a.fecha),b.actualizado
 from obtener_balance_fecha_integrado(p_fecha) b
 left join prestamos_devolucion_condiciones d on d.posicion_id=b.posicion_id
 left join lateral(select sum(x.valor_capital) capital,max(x.fecha) fecha from prestamos_aplicaciones x
 where x.prestamo_id=d.prestamo_id and x.fecha<=p_fecha and x.fecha>=b.fecha_valor) a on true;
$$;

create or replace function public.obtener_partidas_prestamos_fecha(p_fecha date)
returns table(id text,movimiento_bancario_id uuid,pareja_id text,tipo text,moneda text,valor numeric,nombre text,tercero text)
language sql stable set search_path=public,pg_temp as $$
 select 'PAGO_PRESTAMO:'||a.id,b.id,'prestamo-aplicacion:'||a.id,'BANCO',trim(b.moneda),
 case when p.tipo='POR_PAGAR' then -b.valor else b.valor end,
 'Pago vinculado — '||p.tercero,p.tercero
 from prestamos_aplicaciones a join prestamos_grupo p on p.id=a.prestamo_id
 join movimientos_bancarios b on b.id=a.movimiento_bancario_id where a.fecha=p_fecha
 union all
 select 'CAPITAL_PRESTAMO:'||a.id,null::uuid,'prestamo-aplicacion:'||a.id,'CAPITAL',p.moneda,
 case when p.tipo='POR_PAGAR' then a.valor_capital else -a.valor_capital end,
 case when p.tipo='POR_PAGAR' then 'Reducción del pasivo — ' else 'Reducción de cuenta por cobrar — ' end||p.tercero,p.tercero
 from prestamos_aplicaciones a join prestamos_grupo p on p.id=a.prestamo_id where a.fecha=p_fecha;
$$;

do $block$
declare def text;
begin
 select pg_get_functiondef('public.obtener_variacion_balance_fecha_integrado(date)'::regprocedure) into def;
 def:=replace(def,'public.obtener_variacion_balance_fecha_integrado(','public.obtener_variacion_balance_fecha_prestamos(');
 def:=replace(def,'public.obtener_balance_fecha_integrado(','public.obtener_balance_fecha_prestamos(');
 execute def;
end $block$;
revoke all on function public.guardar_condiciones_prestamo(uuid,numeric,text),public.buscar_pagos_prestamo(uuid,text),public.vincular_pago_prestamo(uuid,uuid),public.obtener_balance_fecha_prestamos(date),public.obtener_variacion_balance_fecha_prestamos(date),public.obtener_partidas_prestamos_fecha(date) from public,anon;
grant execute on function public.guardar_condiciones_prestamo(uuid,numeric,text),public.buscar_pagos_prestamo(uuid,text),public.vincular_pago_prestamo(uuid,uuid),public.obtener_balance_fecha_prestamos(date),public.obtener_variacion_balance_fecha_prestamos(date),public.obtener_partidas_prestamos_fecha(date) to authenticated;
revoke all on function public.validar_condiciones_devolucion_prestamo(),public.validar_aplicacion_prestamo() from public,anon,authenticated;
notify pgrst,'reload schema';
