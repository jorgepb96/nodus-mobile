# Continuidad de implementación — 15 de octubre de 2026

El propietario ha pedido terminar la implementación y corregir la interfaz completa antes de retomar la campaña final. **No autoriza más GitHub Actions.** Los workflows permanecen intactos; los commits usan `[skip ci]`. Ambos PR siguen en borrador y sin merge.

La beta **0.1.0 (1003)** ya está disponible en TestFlight interno, según [el registro de entrega](TESTFLIGHT-2026-10-15.md). Esa beta no contiene las correcciones de interfaz ni las integraciones nuevas descritas aquí. No se declara cerrada la paridad global.

## Barras de pestañas

- Las superficies compartidas mezclaban botones táctiles de al menos 44 puntos con barras de 36. Se ha unificado la geometría de la barra, los títulos y los cierres; el grafo conserva su estado propio con la misma altura táctil.
- En iPhone vertical el documento activo usa el ancho restante y el catálogo permanece accesible. En horizontal e iPad se conserva espacio para varias pestañas. La selección se reajusta al cambiar el ancho.
- Un contenedor explícito sustituye la regla genérica que asignaba `flex:1` a cualquier `div` directo de la superficie. Las barras y los avisos no deben crecer como si fueran el documento.
- Las barras SwiftUI también reservan 44 puntos para cerrar, escalan con el texto accesible y limitan los atajos a la sección visible, evitando que una sección residente reciba Command-W.
- Desktop `a1ff170e`; móvil `457442b` y `082b9c2`. El recorrido de geometría del componente React real en Electron pasó **20 escenarios** (ancho/orientación/tema/texto ampliado), cierre, catálogo y navegación con teclado. Evidencia privada Desktop: `artifacts/interface-2026-10-15/workspace-tabs/result.json` y capturas. ESLint focalizado pasó.
- La regresión nativa `WorkspaceTabLayoutUITests` está preparada; **no está compilada ni ejecutada todavía**. El parseo de Swift pasó. Se ejecutará sobre el bundle integrado, junto a la revisión real de WebKit; la prueba Electron no equivale a aceptación iOS.

## Integraciones activas

- **Investigación:** se ha corregido la duplicación entre resultados propios y publicados usando el recibo de publicación, y la reapertura offline de la copia propia por identidad canónica. Siguen en implementación la guía completa canónica en ejecución local, la selección de fuentes descargadas y sus opciones. Autónomo debe funcionar con el Mac apagado; no se acepta como solución ejecutar su algoritmo en el Mac con claves del teléfono.
- **Bases de datos:** las siete operaciones móviles que no tenían dispatcher ya disponen de transporte/autorización real en Desktop. Continúan los adjuntos persistentes por bloques, la selección de relaciones y la publicación de resultados/acciones. Las pruebas SQLite enfocadas de Desktop no sustituyen la compilación/integración iOS pendiente.
- **Trabajo offline:** se ha añadido la captura de autoría de la cola nativa antes de retirar permisos. El archivo es exportable y conserva payload, identidad y recibos; no se reproduce automáticamente con una vinculación nueva. Continúa la recuperación por registros y la exportación de archivos grandes sin cargarlos íntegramente en memoria.

Los checkpoints anteriores conservan sus resultados y fallos originales. Las fuentes se congelarán antes de regenerar recursos compartidos y compilar; después se realizarán las pruebas locales y simuladores de la integración completa. Las pruebas físicas siguen asignadas al propietario. La ruta real VPN permanece pendiente de una red utilizable.

La segunda CI de Desktop ejecutó los 1.046 archivos, 5.259 pruebas aprobadas y 10 omisiones explícitas por plataforma/ABI. Su E2E de Stellar falló; la corrección posterior pasó localmente. **El PR no está verde y no se lanzará una tercera CI sin nueva autorización.** [Registro](https://github.com/jorgepb96/nodus/blob/codex/mobile-0.1.0-parity/docs/mobile-0.1.0/checkpoints/ci-corrections-2026-10-15.md).
