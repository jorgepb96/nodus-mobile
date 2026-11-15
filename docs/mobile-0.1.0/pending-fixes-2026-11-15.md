# Correcciones acotadas posteriores a TestFlight 1006

Implementadas, pendientes de la verificación final que autorice el propietario.
No se han ejecutado pruebas, compilaciones ni nuevas subidas a TestFlight para este lote.

- Menú Explorar: Deep Research usa el recurso vectorial NodusTelescope, no un nombre
  inexistente de SF Symbols.
- Filtro de informes: el Bridge privado de Desktop incorpora las marcas de lectura de los
  informes del vault, que la proyección pública excluye deliberadamente. La revisión privada
  cambia al marcar o desmarcar un informe para invalidar respuestas antiguas. La publicación
  pública conserva su exclusión de datos personales.
- Galería: permite actualizar deslizando y distingue una biblioteca vacía de un filtro sin
  resultados. Link no invita a generar informes cuando no hay coincidencias.
- Configuración semántica: Desktop valida el contrato del índice moderno en lugar de intentar
  migrarlo como metadatos antiguos. Conserva las comprobaciones de proveedor, modelo y dimensión.
- Ajustes iOS: aviso localizado, reintento y detalles técnicos plegados cuando no se puede
  consultar la configuración semántica.

Las correcciones de lectura y contratos requieren también actualizar Desktop. Están en
el checkout `/Users/jorgepb96/.codex/worktrees/8ff4/nodus/artifacts/mobile-settings-navigation`,
rama `codex/fix-mobile-settings-navigation` (PR Desktop #1355). Su commit se conserva localmente;
la subida de ese commit y sus comprobaciones quedan para la tanda final para evitar que
GitHub dispare verificaciones ahora. El laboratorio final debe compilar ese código, no el
checkout congelado utilizado para validar la beta 1006.

Pendiente al recibir el «ok»: comprobar lectura y cambios de filtro con estados reales de
Desktop, retorno desde el lector y actualización; revisar mensajes vacío/sin coincidencias;
consultar contratos modernos y antiguos sin mezclar espacios vectoriales; revisar aviso,
reintento y traducciones; compilar y distribuir una nueva beta. Ningún cambio de este lote
se presenta como validado ni como incluido en TestFlight 1006.
