# Integración de compras AXP-026 — revisión Go Live

Estado: preparado en desarrollo; SQL probado con ROLLBACK; no aplicado a producción.

## Resultado validado al 06/10/2026
- Compra de Material contado (Oro Sur): PEN 190642.20, dos pagos conciliados del 30/09.
- Compra de Material crédito (New Company Mocha): PEN 1513873.80, recepción 29/09.
- Inventario PEN: 1704516.00.
- Cuenta por pagar Mocha: PEN 1513873.80.

## Cambios
- docs/exportaciones/sql/integracion-compras-material.sql crea una vista con security_invoker que unifica imputaciones bancarias de compras conciliadas y compras a crédito activas.
- obtener_balance_fecha incorpora inventario y pasivo desde esa fuente, por fecha. obtener_variacion_balance_fecha incluye posiciones derivadas sin exigir una fila manual en balance_posiciones.
- Se cargan dos imputaciones bancarias de Oro Sur, vinculadas a los movimientos existentes, sin crear nuevos pagos.
- El snapshot manual del 30/09 de PEN 190677.71 se convierte a residual cero y su valor anterior se documenta en el comentario: las compras sustituyen ese saldo.
- Se corrige la mención AXP-025 en el concepto de detracción de Oro Sur.
- balance-general.html deja de sumar créditos en el navegador: evita duplicar el nuevo cálculo SQL.
- exportaciones.html usa la fuente compartida para material y presenta el detalle. Se preservan las imputaciones de solicitudes que ya existan fuera del flujo bancario.

## Verificación
- Ejecución SQL completa dentro de transacción revertida.
- Repetición del script dos veces: dos líneas de contado y una de crédito, sin duplicación.
- Cortes: 28/09 inventario PEN 0; 29/09 PEN 1513873.80; 30/09 y 06/10 PEN 1704516.00.
- Variación reconoce la deuda Mocha el 29/09 y no crea un nuevo incremento el 06/10.
- Cero diferencias en los otros saldos comparados (28/09, 29/09, 30/09 y 06/10).
- Usuario admin autenticado obtiene los totales correctos; usuario autenticado sin acceso obtiene cero filas de compras.
- JavaScript: sintaxis válida; cálculo de Compra de Material -1704516 PEN sin sumar dos veces las imputaciones de banco.

## Publicación coordinada
Requiere aplicar el SQL junto con los cambios de ambas pantallas: el frontend anterior duplicaría Mocha después del cambio de la función.
No mezclar toda la rama desarrollo en main: contiene cambios de refinería ajenos a esta entrega.
Las pestañas abiertas deben recargarse tras publicar.

## Alcance pendiente
No registra una venta, liquidación, baja de inventario, amortización de Mocha ni modifica tasas de cambio. La futura salida de material y pago del crédito requieren su propio flujo.
