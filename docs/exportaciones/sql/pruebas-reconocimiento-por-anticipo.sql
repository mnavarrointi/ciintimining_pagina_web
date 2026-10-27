begin;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"da5cf891-7571-46b2-8056-be9d40499108","role":"authenticated"}',true);
do $test$
declare e uuid; x uuid; z uuid; n numeric;
begin
 select id into e from exportaciones where codigo='AXP-026';
 x:=conciliar_cobro_refineria(e,'ANTICIPO','b9154789-c276-4b73-b793-84161e4e24c2');
 if (select valor_original from obtener_balance_fecha_integrado('2026-10-05') where codigo='ACT_ORO_PEN')<>1704516 then raise exception 'Inventario anterior alterado';end if;
 if (select valor_original from obtener_balance_fecha_integrado('2026-10-06') where codigo='ACT_ORO_PEN')<>0 then raise exception 'No salió inventario';end if;
 if (select valor_original from obtener_balance_fecha_integrado('2026-10-06') where codigo like 'CREDITO_ORO_%')<>1513873.80 then raise exception 'Se perdió deuda material';end if;
 if (select valor_original from obtener_balance_fecha_integrado('2026-10-06') where codigo like 'CXC_REFINERIA_%')<>27165.47 then raise exception 'Falta CXC';end if;
 if (select sum(valor_original) from obtener_balance_fecha_integrado('2026-10-06') where codigo='PAS_PROSEGUR' or codigo like 'CXP_COSTO_EXPORT_%')<>22500 then raise exception 'Prosegur duplicado/incorrecto';end if;
 if conciliar_cobro_refineria(e,'ANTICIPO','b9154789-c276-4b73-b793-84161e4e24c2')<>x then raise exception 'No idempotente';end if;
 if (select count(*) from exportacion_reconocimientos where exportacion_id=e)<>1 then raise exception 'Reconocimiento duplicado';end if;
 begin
 update exportacion_liquidaciones_refineria set valor_total_metal_usd=valor_total_metal_usd+1,balance_usd=balance_usd+1 where exportacion_id=e;
 raise exception 'TEST: cambió saldo reconocido';
 exception when others then if SQLERRM like 'TEST:%' then raise;end if;end;
 z:=conciliar_cobro_refineria(e,'BALANCE','25250289-7172-4315-8bc9-b8ba9576b140');
 if (select valor_original from obtener_balance_fecha_integrado('2026-10-08') where codigo like 'CXC_REFINERIA_%')<>27165.47 then raise exception 'CXC anulada antes';end if;
 if (select valor_original from obtener_balance_fecha_integrado('2026-10-09') where codigo like 'CXC_REFINERIA_%')<>0 then raise exception 'CXC no cancelada';end if;
 select sum(valor) into n from obtener_partidas_exportacion_fecha('2026-10-09');
 if n<>0 then raise exception 'Cobro balance duplicó utilidad';end if;
end $test$;
select jsonb_build_object(
 'balance_06',(select jsonb_agg(x)from(select codigo,nombre,valor_original,moneda from obtener_balance_fecha_integrado('2026-10-06') where codigo='ACT_ORO_PEN' or codigo='PAS_PROSEGUR' or codigo like 'CREDITO_ORO_%' or codigo like 'CXP_COSTO_EXPORT_%' or codigo like 'CXC_REFINERIA_%')x),
 'partidas_06',(select jsonb_agg(x)from obtener_partidas_exportacion_fecha('2026-10-06')x),
 'resultado_06_usd',(select sum(p.valor/case when p.moneda='USD' then 1 else (select unidades_por_usd from tasas_cambio_diarias t where trim(t.moneda)=p.moneda and t.fecha<='2026-10-06' order by t.fecha desc limit 1)end) from obtener_partidas_exportacion_fecha('2026-10-06')p),
 'variacion_06',(select jsonb_agg(x)from(select codigo,cambio_moneda_original,impacto_patrimonio_usd from obtener_variacion_balance_fecha_integrado('2026-10-06') where codigo like 'CXC_REFINERIA_%' or codigo like 'CXP_COSTO_EXPORT_%' or codigo='ACT_ORO_PEN')x)
) prueba;
rollback;