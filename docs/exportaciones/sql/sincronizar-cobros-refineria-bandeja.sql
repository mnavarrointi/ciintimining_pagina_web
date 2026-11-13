create or replace function public.conciliar_cobro_refineria(p_exportacion_id uuid,p_tipo text,p_movimiento_bancario_id uuid)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare l public.exportacion_liquidaciones_refineria; b public.movimientos_bancarios%rowtype; v uuid; previo uuid; importe numeric; texto text; codigo_exportacion text;
begin
 if not exists(select 1 from public.usuarios_app where user_id=auth.uid() and activo and rol='admin') then raise exception 'Sin permisos para conciliar.'; end if;
 select * into l from public.exportacion_liquidaciones_refineria where exportacion_id=p_exportacion_id for update;
 if not found then raise exception 'Registra primero la liquidación.'; end if;
 importe:=case when p_tipo='ANTICIPO' then l.anticipo_usd when p_tipo='BALANCE' then l.balance_usd else null end;
 if importe is null or importe<=0 then raise exception 'El concepto debe ser anticipo o balance con importe positivo.'; end if;
 select * into b from public.movimientos_bancarios where id=p_movimiento_bancario_id for update;
 if not found or b.naturaleza<>'CREDITO' or trim(b.moneda)<>'USD' or b.valor<>importe or b.estado_conciliacion='IGNORADO' then raise exception 'El ingreso bancario no coincide con la liquidación o no está disponible.'; end if;
 select id,movimiento_bancario_id into v,previo from public.exportacion_cobros_refineria where exportacion_id=p_exportacion_id and tipo=p_tipo;
 if found then
  if previo<>p_movimiento_bancario_id then raise exception 'Este concepto ya está conciliado con otro ingreso.'; end if;
 else
  insert into public.exportacion_cobros_refineria(exportacion_id,tipo,movimiento_bancario_id,monto_usd)
  values(p_exportacion_id,p_tipo,p_movimiento_bancario_id,importe) returning id into v;
 end if;
 if exists(select 1 from public.conciliaciones c where c.movimiento_bancario_id=b.id and c.estado='CONFIRMADA'
 and (c.criterio->>'cobro_refineria_id' is distinct from v::text or c.movimiento_tesoreria_id is not null)) then raise exception 'El ingreso tiene otra conciliación confirmada; revisa el vínculo antes de continuar.'; end if;
 select codigo into codigo_exportacion from public.exportaciones where id=p_exportacion_id;
 texto:=case when p_tipo='ANTICIPO' then 'Anticipo de refinería' else 'Cobro del balance de refinería' end||' — '||codigo_exportacion||'. Vinculado desde Exportaciones; sin duplicar el ingreso ni el reconocimiento contable.';
 update public.conciliaciones set estado='RECHAZADA',updated_at=now() where movimiento_bancario_id=b.id and estado='PROPUESTA';
 if not exists(select 1 from public.conciliaciones c where c.movimiento_bancario_id=b.id and c.estado='CONFIRMADA' and c.criterio->>'cobro_refineria_id'=v::text) then
  insert into public.conciliaciones(movimiento_bancario_id,movimiento_tesoreria_id,estado,metodo,confianza,criterio,comentario,created_by,confirmada_by,confirmada_at)
  values(b.id,null,'CONFIRMADA','MANUAL',1,jsonb_build_object('tipo_resolucion','COBRO_REFINERIA','cobro_refineria_id',v,'exportacion_id',p_exportacion_id,'exportacion',codigo_exportacion,'tipo_cobro',p_tipo,'impacto_pyg_directo',false),texto,auth.uid(),auth.uid(),now());
 end if;
 update public.movimientos_bancarios set estado_conciliacion='CONCILIADO',naturaleza_patrimonial=case when p_tipo='ANTICIPO' then 'EXPORTACION' else 'TRANSFERENCIA_INTERNA' end,explicacion_automatica=texto,updated_at=now() where id=b.id;
 return v;
end $$;