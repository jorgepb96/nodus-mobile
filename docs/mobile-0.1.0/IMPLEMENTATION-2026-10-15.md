# Continuidad de implementación — 15 de octubre de 2026

El propietario ha pedido terminar la implementación y corregir la interfaz completa antes de retomar la campaña final. **No autoriza más GitHub Actions.** Los workflows permanecen intactos; los commits usan `[skip ci]`. Ambos PR siguen en borrador y sin merge.

La beta **0.1.0 (1003)** ya está disponible en TestFlight interno, según [el registro de entrega](TESTFLIGHT-2026-10-15.md). Esa beta no contiene las correcciones de interfaz ni las integraciones nuevas descritas aquí. No se declara cerrada la paridad global.

## Barras de pestañas

- Las superficies compartidas mezclaban botones táctiles de al menos 44 puntos con barras de 36. Se ha unificado la geometría de la barra, los títulos y los cierres; el grafo conserva su estado propio con la misma altura táctil.
- En iPhone vertical el documento activo usa el ancho restante y el catálogo permanece accesible. En horizontal e iPad se conserva espacio para varias pestañas. La selección se reajusta al cambiar el ancho.
- Un contenedor explícito sustituye la regla genérica que asignaba `flex:1` a cualquier `div` directo de la superficie. Las barras y los avisos no deben crecer como si fueran el documento.
- Las barras SwiftUI también reservan 44 puntos para cerrar, escalan con el texto accesible y limitan los atajos a la sección visible, evitando que una sección residente reciba Command-W.
- Desktop `a1ff170e` y `06666c21`; móvil `457442b`, `082b9c2`, `6cf19ab` y `6efd44a`. El recorrido de geometría de los componentes React reales (lectores y cabecera editorial) en Electron pasó **40 escenarios** (ancho/orientación/tema/texto ampliado), cierre, catálogo y navegación con teclado. Evidencia privada Desktop: `artifacts/interface-2026-10-15/workspace-tabs/result.json` y capturas. ESLint focalizado pasó.
- La regresión nativa `WorkspaceTabLayoutUITests` ya se compiló y ejecutó sobre el bundle preliminar integrado. Los resultados detallados aparecen abajo: el recorrido completo todavía no está aprobado. La prueba Electron no equivale a aceptación iOS.

## Integraciones activas

- **Investigación:** se ha corregido la duplicación entre resultados propios y publicados usando el recibo de publicación, y la reapertura offline de la copia propia por identidad canónica. La guía completa, estudio/docencia y genealogía ya tienen núcleos canónicos portables, selección de fuentes descargadas y recibos persistentes. Los contratos y fixtures focalizados pasan; su integración nativa y las llamadas a proveedores reales siguen pendientes. Continúa la extracción del orquestador académico con sus garantías de evidencias, cobertura y supervisión. Autónomo debe funcionar con el Mac apagado; no se acepta como solución ejecutar su algoritmo en el Mac con claves del teléfono.
- **Bases de datos:** las siete operaciones móviles que no tenían dispatcher ya disponen de transporte/autorización real en Desktop. El checkpoint móvil `616f07d` integra adjuntos persistentes por bloques de 512 KiB, selección paginada de relaciones y publicación de resultados/acciones. También están implementadas la resolución manual de efectos externos inciertos y la edición de páginas creadas autónomamente. Los archivos Swift de este bloque compilan y las pruebas Kit/SQLite enfocadas pasan; la aceptación final de la integración sigue pendiente.
- **Trabajo offline:** se ha añadido la captura de autoría de la cola nativa antes de retirar permisos. El archivo es exportable y conserva payload, identidad y recibos; no se reproduce automáticamente con una vinculación nueva. La recuperación v2 conserva registros cifrados por separado y exporta por streaming, sin cargar adjuntos completos en memoria. Los archivos históricos muestran su tamaño real y admiten eliminación explícita con bloqueo durante exportación o adopción; nunca se borran automáticamente. Commits `977d65c`, `fd3a1ff`, `de0ca0a` y `f45feac`.

## Catálogos y navegación nativa

- `0e3ea46` corrige Autores, que antes solicitaba únicamente la primera página de 100 registros. Ahora permite continuar todas las páginas, detecta cambios de revisión, valida el progreso y rechaza respuestas inconsistentes sin presentarlas como un catálogo vacío.
- La búsqueda y las acciones se redistribuyen en pantallas estrechas. Las obras y los autores relacionados del dossier ya tienen enlaces reales. El callback de Ideas también abre los registros relacionados que antes descartaba por no ser ideas. El recorrido nativo de Autores→obra→autor relacionado pasó en iPhone e iPad con el bundle preliminar integrado.
- La primera prueba de paginación falló porque el fixture no incluía obras/créditos de autor, que exige la proyección real. El fixture corregido contiene 237 autores con obras y verifica tres páginas, duplicados, continuidad y cambios de revisión; pasó posteriormente. Se conserva el log fallido.

## Comprobaciones focalizadas de esta integración

- Recuperación/exportación inicial: 95 pruebas Kit en 8 suites aprobadas sobre su snapshot registrado.
- Adjuntos/acciones/relaciones y recuperación: 38 pruebas Kit en 7 suites aprobadas; los resultados se solapan con la campaña anterior y no se suman como cobertura nueva.
- Gestión de archivos históricos y paginación de Autores: 15 pruebas en 2 suites aprobadas (`recovery-storage-author-focused-01.log`), incluidos los tres casos de Autores.
- Componentes compartidos: 40 escenarios de geometría y 26 contratos UI aprobados. Son pruebas locales de componentes, no aceptación nativa iOS.
- Las fuentes de cada ejecución y sus logs están en los artefactos privados `artifacts/pairing-2026-10-15/` de cada repositorio. Cuatro compilaciones Swift integradas pasaron; la aceptación completa con recursos compartidos regenerados y E2E de las nuevas operaciones sigue pendiente.

Los checkpoints anteriores conservan sus resultados y fallos originales. Las fuentes se congelarán antes de regenerar recursos compartidos y compilar; después se realizarán las pruebas locales y simuladores de la integración completa. Las pruebas físicas siguen asignadas al propietario. La ruta real VPN permanece pendiente de una red utilizable.

La segunda CI de Desktop ejecutó los 1.046 archivos, 5.259 pruebas aprobadas y 10 omisiones explícitas por plataforma/ABI. Su E2E de Stellar falló; la corrección posterior pasó localmente. **El PR no está verde y no se lanzará una tercera CI sin nueva autorización.** [Registro](https://github.com/jorgepb96/nodus/blob/codex/mobile-0.1.0-parity/docs/mobile-0.1.0/checkpoints/ci-corrections-2026-10-15.md).

Los pushes usan `[skip ci]` y no han iniciado otra CI de compilación/pruebas. GitHub sí ejecutó automáticamente los controles de metadatos `PR checks` y CLA de tipo `pull_request_target` sobre Desktop `6b2900fe`; ya habían terminado cuando se consultó su estado. Los workflows permanecen intactos.

## Comprobaciones nativas y correcciones posteriores

- `native-integration-build-{01,02,03,04}.xcresult`: cuatro builds de pruebas locales correctas. En cada compilación se registraron las fuentes antes y después sin cambios durante el proceso. Estos bundles todavía contienen los recursos WebKit anteriores; no son aceptación final de las superficies nuevas.
- La primera ejecución de iPhone detectó cuatro fallos: teclado horizontal y propagación de identificadores de accesibilidad, corregidos en `2c33e7f`. Los callbacks de navegación de cuatro lectores WebKit también se ajustaron a la firma real del SDK en `7748c61`.
- La segunda ejecución aprobó chat completo en ambos temas (teclado, giro, historial y borrador durable), navegación Autores→obra→autor relacionado y pestañas con tamaño de texto accesible. El cuarto caso detectó un bloqueo real SQLite al reabrir Ideas; se conserva el fallo completo.
- `0801eb8` corrige esa contención con WAL y espera acotada. Once pruebas de MirrorStore pasaron, incluidas tres con varios handles, lecturas e importación reales; las importaciones conservan su atomicidad.
- La tercera ejecución vuelve a aprobar los tres recorridos anteriores. El último caso se detuvo ante `43.99999999999994` frente a 44 puntos. Se corrigió la tolerancia de medida a 0,01 puntos en el test. No se redujo el tamaño de los controles. La repetición completa pasó posteriormente en `native-tabs-iphone-05.xcresult`.
- Los cinco contratos HTTP del nuevo host web pasaron dentro del simulador. El smoke separado con la fuente Swift exacta pasó en macOS contra HTTPS real (HTML, JSON, redirect, cancelación y límite de cuerpo); no acredita todavía tráfico iOS. Los dos contratos de embeddings propios del móvil también pasaron en el paquete NodusAI.
- `5b620b2` corrige otra integración: los accesos a Deep Research enviaban el modo autónomo vinculado al formulario nativo anterior. Ambos accesos usan ahora el espacio completo, con desmontaje y configuración explícita al cambiar de modo. Esta corrección de ruta queda pendiente de la compilación final y su prueba visual.

Las ejecuciones fallidas se mantienen en `artifacts/interface-2026-10-15/`, junto con `.xcresult`, capturas exportadas, hashes de fuentes y de los ejecutables. Ninguna de ellas se contabiliza como una aprobación global.

## Integración posterior al cuarto build

- `native-integration-source-04.json` registra 504 fuentes antes y después de compilar, sin cambios durante el build. Los ejecutables tienen hashes en `native-tabs-artifacts-04.json`. Incluye `eed11b4`, la ruta autónoma de investigación corregida y el ajuste de Autores; todavía usa el bundle compartido anterior.
- La ejecución `native-tabs-iphone-04.xcresult` pasó Autores pero agotó dos esperas de orientación. Se conserva completa. Después de reiniciar únicamente el simulador aislado de esta campaña, **los mismos ejecutables** pasaron los tres casos en `native-tabs-iphone-05.xcresult`: Autores→obra→autor relacionado, Ideas con texto accesible y cuatro secciones × dos temas × ambas orientaciones (16 capturas de pestañas, más dos accesibles). No se cambió el producto ni se retiró ninguna aserción para esa repetición.
- `9d453c5` mantiene al menos 220 puntos para el título de Biblioteca y permite desplazar únicamente su tabla en iPad cuando el sidebar reduce el espacio. Corrige también los separadores verticales del cuaderno de notas.
- `d4d4d36` evita resultados atrasados al buscar/ordenar el espejo, valida continuidad y revisión en la paginación y mantiene notas/carpetas en una publicación coherente. Los errores ofrecen reintento y no aparecen como un catálogo vacío. La continuación visible se vuelve a solicitar al cambiar el número de filas.
- `dfd94e1` redistribuye las siete acciones de Biblioteca cuando no caben en una fila. Preparación de archivos y sincronización Zotero se identifican como operaciones de Desktop; el companion no inicia extracción/indexación. `32922d3` añade el recorrido nativo específico de controles y desplazamiento local de tabla. Estos cambios posteriores al build 04 conservan parse/diff-check correctos; su compilación y ejecución están pendientes del siguiente build.
- Los checkpoints coherentes se han subido a ambos PR con `[skip ci]`. El push de Desktop inició automáticamente dos controles de metadatos `pull_request_target` (38765347186 y 38765346898); se solicitó su cancelación al detectarlos. No se lanzó otra CI de compilación/pruebas ni se desactivaron workflows.

El recorrido de iPad del build 04 también pasó sus tres casos completos en `native-tabs-ipad-01.xcresult`: ambas orientaciones/temas de las cuatro secciones, texto accesible y navegación de Autores. Sus ejecutables conservan los hashes de build 04. Se exportaron y revisaron capturas actuales de iPhone e iPad. El nuevo caso de Biblioteca y la campaña con los recursos WebKit regenerados se registrarán al completarse. Esta sección no acredita aún esa aceptación final ni una nueva beta de TestFlight.
