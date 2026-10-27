# Exportaciones — Fase 1: modelo de causación (borrador técnico)

Estado: diseño en rama desarrollo. NO ejecutado sobre Supabase ni conectado todavía al Balance General.

## Reglas confirmadas
1. Las solicitudes de pago causan únicamente al pasar a APROBADO. Un borrador no causa.
2. En la entrega oficial del oro a refinería se recibe anticipo, sale el inventario y se reconoce la operación completa usando una venta provisional ajustable.
3. Los costos proyectados creados manualmente dentro de la exportación no causan en balance antes de esa entrega. Después se convierten en solicitud sin crear un segundo costo.
4. Pagos y cobros cancelan obligaciones o derechos; nunca vuelven a causar el mismo costo/ingreso.
5. La métrica gerencial 'utilidad + pagos previos' es un ajuste de presentación del reporte diario, NO un asiento adicional al patrimonio.

## Inventario de tablas existentes verificadas
- exportaciones: id, codigo, estado, fecha_causacion, moneda_resultado, pen_por_usd.
- solicitud_pago_items: id, solicitud_id, estado, naturaleza_economica, exportacion_id, rubro_exportacion, moneda, valor.
- solicitudes_pago: id, estado, aprobada_at, fecha_solicitud.
- movimientos_tesoreria: id, solicitud_item_id, exportacion_id, rol_exportacion, rubro_exportacion, fecha_causacion, fecha_pago.
- movimientos_bancarios: id, fecha_movimiento, estado_conciliacion, naturaleza, moneda, valor.
- exportacion_imputaciones: exportacion_id, rubro, origen, solicitud_item_id, movimiento_bancario_id, moneda, monto, signo. Esta tabla representa imputaciones para rubros; NO constituye por sí sola un libro contable.
- balance_posiciones: catálogo de posiciones de balance, no libro de partidas dobles.

## Modelo objetivo (pendiente de migración y pruebas)
- exportacion_costos: id, exportacion_id, rubro, beneficiario_id opcional, concepto, moneda, monto_proyectado, monto_definitivo, estado (PROYECTADO/CAUSADO/DEFINITIVO/ANULADO), fecha_causacion, solicitud_item_id UNIQUE nullable, created_at, updated_at. Un costo = un ID estable.
- exportacion_eventos: id, exportacion_id, tipo (RECEPCION_ORO/APROBACION_SOLICITUD/ENTREGA_REFINERIA/ANTICIPO/COBRO_SALDO/PAGO_PROVEEDOR/AJUSTE), fecha_efectiva, origen_tipo, origen_id, idempotency_key UNIQUE, metadata, created_at. Evento inmutable; correcciones por reversión.
- exportacion_liquidaciones: id, exportacion_id, version, moneda, valor_venta, tipo (PROVISIONAL/DEFINITIVA), fecha_efectiva, observacion, UNIQUE(exportacion_id,version).
- exportacion_inventario_movimientos: id, exportacion_id, tipo (ENTRADA/SALIDA/AJUSTE), fecha, moneda, costo, referencia_origen, idempotency_key UNIQUE. Entradas a crédito crean CxP; al contado aplican banco.
- exportacion_partidas: id, evento_id, posicion_balance_id, empresa_id, moneda, debe, haber, fecha, reversa_de_id. Validar sum(debe)=sum(haber) por evento/moneda; no duplicar con el balance existente.
- exportacion_aplicaciones: id, costo_id o liquidacion_id, movimiento_bancario_id, monto_aplicado, moneda, UNIQUE por vínculo lógico; permite pagos parciales.

## Invariantes de implementación
- Ningún cambio de estado a APROBADO puede generar doble asiento si se reintenta.
- La fecha de aprobación es la fecha de causación para solicitudes aprobadas, salvo regla explícita de negocio posterior.
- Un costo proyectado vinculado a solicitud aprobada pasa a causado y no se replica.
- Una conciliación bancaria aplica pagos a la obligación existente; no crea un costo nuevo.
- La entrega a refinería es transacción atómica: inventario, venta provisional, anticipo, CxC, costos pendientes y asientos balanceados.
- Los cambios posteriores de liquidación o costos producen asientos diferenciales con trazabilidad.
- Mantener montos originales y tasas históricas; pen_por_usd es tasa gerencial por exportación, no sustituye tasa contable por fecha.
- Nunca modificar balances históricos ni el ajuste provisional de oro del 30/09/2026 sin revisión específica.

## Orden de ejecución
1. Revisar funciones, triggers, estados y políticas RLS existentes, especialmente sincronizar_imputacion_solicitud y registrar_imputacion_conciliada.
2. Preparar migración aditiva con índices, restricciones y RLS; probar en entorno aislado.
3. Crear consultas de validación de idempotencia, partida doble y consistencia con imputaciones existentes.
4. Integrar flujo de aprobación y costos proyectados en desarrollo.
5. Integrar evento de entrega, ajustes y Balance General; validar con caso de exportación de prueba antes de producción.

## Riesgo detectado
El trigger actual de exportacion_imputaciones puede registrar SOLICITUD antes de aprobación y reinsertar una imputación tras conciliación. Antes de activar causaciones nuevas, revisar y corregir el origen de verdad y la exclusión de duplicados.
