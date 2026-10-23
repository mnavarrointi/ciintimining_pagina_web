-- Fase 4: compras de oro. Migracion preparada para revision; NO aplicada a produccion.
-- Registros nuevos e independientes del balance historico.
create table if not exists public.exportacion_compras_oro (
 id uuid primary key default gen_random_uuid(),
 exportacion_id uuid not null references public.exportaciones(id),
 proveedor_id uuid references public.beneficiarios(id),
 modalidad text not null check (modalidad in ('CONTADO','CREDITO')),
 valor_total numeric(20,4) not null check (valor_total>0),
 moneda text not null check (moneda in ('COP','PEN','USD')),
 fecha_recepcion date not null,
 fecha_estimada_pago date,
 tasa_historica numeric(20,8) not null check (tasa_historica>0),
 moneda_base text not null check (moneda_base in ('COP','PEN','USD')),
 valor_base numeric(20,4) generated always as (round(valor_total*tasa_historica,4)) stored,
 movimiento_origen_id uuid unique references public.movimientos_bancarios(id),
 estado text not null default 'ACTIVA' check (estado in ('ACTIVA','ANULADA')),
 created_at timestamptz not null default now(),
 constraint compra_oro_modalidad check (
 (modalidad='CREDITO' and proveedor_id is not null and fecha_estimada_pago is not null and movimiento_origen_id is null)
 or (modalidad='CONTADO' and movimiento_origen_id is not null and fecha_estimada_pago is null)
 )
);
create table if not exists public.exportacion_pagos_credito_oro (
 id uuid primary key default gen_random_uuid(),
 compra_id uuid not null references public.exportacion_compras_oro(id),
 movimiento_bancario_id uuid not null references public.movimientos_bancarios(id),
 valor_aplicado numeric(20,4) not null check(valor_aplicado>0),
 moneda text not null check(moneda in ('COP','PEN','USD')),
 tasa_historica numeric(20,8) not null check(tasa_historica>0),
 fecha_pago date not null,
 created_at timestamptz not null default now(),
 unique(compra_id,movimiento_bancario_id)
);
create unique index if not exists exportacion_pago_credito_movimiento_unico on public.exportacion_pagos_credito_oro(movimiento_bancario_id);
create index if not exists exportacion_compras_oro_exportacion_idx on public.exportacion_compras_oro(exportacion_id);
create or replace view public.exportacion_creditos_oro_pendientes
with (security_invoker=true) as
select c.id,c.exportacion_id,c.proveedor_id,c.valor_total,c.moneda,c.fecha_recepcion,c.fecha_estimada_pago,
 c.valor_total-coalesce(sum(p.valor_aplicado),0) as saldo_pendiente
from public.exportacion_compras_oro c
left join public.exportacion_pagos_credito_oro p on p.compra_id=c.id
where c.modalidad='CREDITO' and c.estado='ACTIVA'
group by c.id
having c.valor_total-coalesce(sum(p.valor_aplicado),0)>0;
alter table public.exportacion_compras_oro enable row level security;
alter table public.exportacion_pagos_credito_oro enable row level security;
-- No se habilitan politicas ni automatismos en produccion hasta probar:
-- 1) conciliacion CONTADO -> compra unica -> inventario una sola vez;
-- 2) recepcion CREDITO -> inventario y pasivo una sola vez;
-- 3) aplicacion parcial/total -> pasivo sin inventario adicional;
-- 4) tasa historica y moneda base de la empresa;
-- 5) transacciones concurrentes, reversas, conciliaciones repetidas y
--    prohibicion de aplicar mas que el saldo pendiente;
-- 6) sincronizacion de rubro COMPRA DE MATERIAL sin doble imputacion.
-- La interfaz en desarrollo presenta la captura, pero el guardado queda
-- deshabilitado hasta habilitar un RPC transaccional autorizado y probado.
