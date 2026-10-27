# Reconocimiento de exportación al conciliar anticipo
Implementado para revisión en desarrollo. Main conserva su código y sus funciones anteriores.

## Disparador
El vínculo de tipo ANTICIPO crea un único reconocimiento por exportación. Su fecha efectiva es la del movimiento bancario, no la fecha del clic ni la de registro de la liquidación.
Se guardan copias de material recibido a esa fecha, costos proyectados existentes, anticipo y balance pendiente.

## Balance integrado
- Retira del inventario las compras reconocidas; no borra compras de Exportaciones.
- Conserva la deuda de compras a crédito.
- Reconoce cuenta por cobrar de refinería por balance pendiente.
- Reconoce cuentas por pagar por costo proyectado y beneficiario; las cuentas anteriores permanecen.
- Excluye costos ya vinculados explícitamente a una posición existente mediante metadata costo_id o costo_proyectado_id.
- El cobro del BALANCE cancela la CXC desde la fecha bancaria; no vuelve a reconocer ingresos económicos.
- Un balance negativo requiere definir devolución; el reconocimiento se bloquea con mensaje específico.

## Cambio patrimonial
El anticipo bancario aparece una sola vez como positivo Exportación. Se agregan salida de inventario negativa, CXC positiva y costos negativos.
Se reclasifica para presentación el ingreso bancario vinculado; no se crea otro banco ni otro movimiento de tesorería.
La sección presenta ingresos, salidas y resultado por exportación.
Cobro posterior: banco positivo y cancelación CXC negativa, neto cero.

## Verificación
SQL autenticado con ROLLBACK: cortes antes y después del 06/10; inventario 1704516 PEN a cero; Mocha conserva 1513873.80 PEN; CXC 27165.47 USD; Prosegur existente 15000 USD más costo nuevo 7500 USD.
Reintento de conciliación idempotente: un reconocimiento.
Cobro 09/10: CXC cero y efecto económico neto cero.
Resultado simulado: 11561.57 USD usando la tasa PEN/USD actualmente disponible (aproximadamente 3.388).
JavaScript: sintaxis y prueba funcional de clasificación, signos, banco único y cálculo de resultado.
No se dejaron cobros ni reconocimientos de prueba.

## Archivos
- admin/tesoreria/balance-general.html: lectura de partidas reconocidas y resultado por operación.
- admin/tesoreria/exportaciones.html: aviso de efecto del anticipo antes de vincular.
- docs/exportaciones/sql/reconocimiento-por-anticipo.sql: esquema, disparador y consultas aplicadas.
- docs/exportaciones/sql/pruebas-reconocimiento-por-anticipo.sql: regresión transaccional.

## Límites de esta etapa
La copia captura los costos proyectados al conciliar; cambios posteriores no reescriben ese cierre automáticamente.
El pago posterior de pasivos de material/costos y la reversión de reconocimientos necesitan sus propios flujos.
Las tasas de cambio existentes no se modificaron.
