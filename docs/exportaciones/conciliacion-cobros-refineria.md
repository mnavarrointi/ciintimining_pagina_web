# Liquidación de refinería y conciliación de cobros
Implementado exclusivamente en la interfaz de desarrollo. Main no se modifica.

- Al iniciar se cargan liquidaciones y vínculos persistidos.
- Al guardar aparece una sección separada con fecha, valor del metal, costo, anticipo y balance.
- Anticipo y balance tienen estado independiente: No conciliado / Conciliado.
- El administrador puede abrir Conciliar y seleccionar manualmente un ingreso USD por el mismo valor; buscar por descripción, referencia, banco o cuenta.
- La ventana muestra fecha, banco/cuenta, descripción/referencia y valor.
- Un ingreso ya vinculado, imputado a otra exportación, aplicado a préstamo o transferencia interna no es candidato.
- La conciliación crea solo un vínculo exportación/concepto/ingreso. No crea ni modifica movimientos de dinero, PyG, inventario o Balance.
- Se conserva la conciliación bancaria anterior del ingreso: conciliación bancaria y vinculación a exportación son procesos distintos.
- El servidor valida los importes y la disponibilidad, bloquea duplicados y cambios en importes conciliados.
- Un balance cero o negativo no ofrece vinculación de un ingreso positivo.
- Consulta y tesorería pueden consultar; guardar y conciliar mantienen permisos de administrador.

## Archivos
- admin/tesoreria/exportaciones.html: formulario, sección persistida, modal y búsqueda.
- docs/exportaciones/sql/conciliacion-cobros-refineria.sql: tabla con RLS, consulta de disponibles, RPCs y validaciones.
- docs/exportaciones/sql/pruebas-cobros-refineria.sql: pruebas con ROLLBACK (requieren datos existentes indicados).

## Verificaciones
Pruebas SQL como admin autenticado: guardado de liquidación, coincidencia exacta, rechazo por valor incorrecto, vínculos de anticipo y balance, reintento idempotente, pago ocupado no reutilizable y rechazo de edición de importe conciliado. El Balance integrado no cambió.
Las pruebas se revirtieron. No se guardaron liquidaciones ni conciliaciones reales.
Usuario sin autorización: cero filas visibles.
JavaScript: sintaxis verificada.
