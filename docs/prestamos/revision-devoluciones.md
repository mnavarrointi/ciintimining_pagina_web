# Devoluciones de préstamos — revisión en Desarrollo

Estado: interfaz y SQL preparados. La base de datos NO fue actualizada: revisión automática bloqueó el cambio sobre el proyecto compartido inti-treasury. Requiere aprobación específica antes de ejecutar el SQL.

## Uso
1. Préstamos → Abrir operación.
2. Ingresar Total a devolver y moneda, sin sustituir el capital original.
3. Guardar. Buscar pagos bancarios ya conciliados de la misma moneda.
4. Revisar beneficiario, descripción, importe y fecha. Vincular el movimiento.
5. Consultar saldo pendiente e historial. Balance de Desarrollo utiliza la fecha efectiva del banco.

No se configuró el total real de MLHN ni se vinculó el pago de Luis Navarro.

## Cambios
- admin/tesoreria/prestamos.html: edición de condiciones, búsqueda, vinculación e historial.
- admin/tesoreria/balance-general.html: lectura de nuevas funciones únicamente si están disponibles; contrapartidas emparejadas en Transferencias no operativas.
- docs/prestamos/sql/devoluciones-prestamos.sql: condiciones con RLS, validación transaccional y funciones de cálculo.
- docs/prestamos/sql/prueba-devoluciones-prestamos.sql: prueba de integración reversible que debe ejecutarse después de activar la estructura.

La clasificación anterior y el cálculo de producción se mantienen disponibles. No se modificó main.

## Valoración
Cada pago aplica capital proporcional: capital original × pago / total a devolver, con redondeo acumulado a dos decimales. Al terminar, el capital cancelado suma exactamente el original. Si las monedas difieren, el saldo se muestra tanto en moneda de devolución como en moneda original. El efecto de conversión queda separado en Diferencia cambiaria de Transferencias no operativas; no se fuerza un neto cero artificial.

## Controles
- Solo administradores pueden configurar o vincular.
- Lectura limitada a usuarios activos.
- El extracto determina fecha, moneda e importe; no los envía libremente el navegador.
- Pagos ya conciliados con Tesorería, no anulados, sin vínculo con otro préstamo, exportación o transferencia interna.
- Una contraparte bancaria no puede reutilizarse. Bloqueos transaccionales serializan vínculos.
- Condiciones inmutables tras el primer pago.
- Se rechazan pagos superiores al pendiente y saldos manuales posteriores que generarían doble amortización.
- Sin crear otro movimiento de dinero.

## Verificaciones realizadas
Sintaxis JavaScript de ambas pantallas y pruebas simuladas de apertura, configuración, búsqueda, vinculación y saldo; agrupación patrimonial con banco único, neto cero en la misma moneda y diferencia de conversión en distinta moneda. Las pruebas SQL en la base real están pendientes de aprobación/activación.
