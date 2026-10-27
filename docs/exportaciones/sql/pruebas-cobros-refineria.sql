begin;

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"da5cf891-7571-46b2-8056-be9d40499108","role":"authenticated"}',true);
do $test$
declare e uuid; e2 uuid; a uuid; z uuid; old_balance numeric; new_balance numeric;
begin
 select id into e from public.exportaciones where codigo='AXP-026';
 select id into e2 from public.exportaciones where codigo='AXP-027';
 select sum(valor_usd) into old_balance from public.obtener_balance_fecha_integrado('2026-10-06');
 insert into public.exportacion_liquidaciones_refineria(exportacion_id,fecha_liquidacion,valor_total_metal_usd,costo_total_refineria_usd,anticipo_usd,balance_usd)
 values(e,'2026-10-06',522165.47,0,495000,27165.47),(e2,'2026-10-06',522165.47,0,495000,27165.47);
 if (select count(*) from public.buscar_cobros_refineria(e,'ANTICIPO','DILLON'))<>1 then raise exception 'Prueba candidatos anticipo';end if;
 begin
 perform public.conciliar_cobro_refineria(e,'ANTICIPO','25250289-7172-4315-8bc9-b8ba9576b140');
 raise exception 'TEST: permitió valor incorrecto';
 exception when others then if SQLERRM like 'TEST:%' then raise;end if;end;
 a:=public.conciliar_cobro_refineria(e,'ANTICIPO','b9154789-c276-4b73-b793-84161e4e24c2');
 if public.conciliar_cobro_refineria(e,'ANTICIPO','b9154789-c276-4b73-b793-84161e4e24c2')<>a then raise exception 'Prueba idempotencia';end if;
 if exists(select 1 from public.buscar_cobros_refineria(e2,'ANTICIPO','DILLON') where id='b9154789-c276-4b73-b793-84161e4e24c2') then raise exception 'Prueba reutilización';end if;
 begin
 perform public.conciliar_cobro_refineria(e2,'ANTICIPO','b9154789-c276-4b73-b793-84161e4e24c2');
 raise exception 'TEST: permitió ingreso ocupado';
 exception when others then if SQLERRM like 'TEST:%' then raise;end if;end;
 z:=public.conciliar_cobro_refineria(e,'BALANCE','25250289-7172-4315-8bc9-b8ba9576b140');
 begin
 update public.exportacion_liquidaciones_refineria set anticipo_usd=494999,balance_usd=27166.47 where exportacion_id=e;
 raise exception 'TEST: permitió editar importe conciliado';
 exception when others then if SQLERRM like 'TEST:%' then raise;end if;end;
 select sum(valor_usd) into new_balance from public.obtener_balance_fecha_integrado('2026-10-06');
 if old_balance is distinct from new_balance then raise exception 'Prueba cambió el Balance';end if;
end $test$;
select tipo,monto_usd from public.exportacion_cobros_refineria order by tipo;
rollback;