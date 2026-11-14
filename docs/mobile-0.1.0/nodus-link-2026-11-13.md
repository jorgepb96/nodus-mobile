# Nodus Link 0.1.0 — alcance de la primera versión

Decisión del propietario, 13 de noviembre de 2026. Sustituye el objetivo de
paridad de edición/generación para la primera beta. La entrega de DeepSeek del
26 de octubre es evidencia histórica, no una aprobación del candidato actual.

La primera versión es un compañero de consulta. Nodus Desktop (macOS, Windows o
Linux) conserva los datos y actúa como servidor privado. iOS/iPadOS muestra las
ideas y sus fuentes, el grafo, los mapas de argumentos, Deep Research, diccionario
y podcasts guardados. Biblioteca, búsqueda y autores apoyan la consulta. Los
mapas automáticos se calculan sobre conexiones existentes, sin invocar modelos.

## Producto y límites

- Vinculación principal del workspace completo mediante código, QR o enlace.
  Conexión directa HTTPS en LAN o VPN; sin Server/Cloud en el recorrido principal.
- Portada y navegación de consulta. Una ruta antigua de escritura vuelve a Inicio.
- Los editores, proveedores, colas y generadores previos permanecen en el código y
  sus datos no se eliminan. La versión Link bloquea nuevas escrituras/generaciones
  en las superficies compartidas y los puntos de entrada nativos; no reenvía las
  colas de edición retenidas. No se inicia extracción, indexación ni derivación.
- El diccionario permite catálogo completo, filtros, definición, evidencia,
  autores, obras, versiones y relaciones. No crea ni regenera entradas.
- Deep Research permite catálogo y lector nativo, fuentes y traducciones ya
  guardadas. No ofrece crear informes, traducciones ni recursos visuales.
- Podcasts lee los episodios actuales de Desktop, transcripción, capítulos,
  fuentes e imagen. El audio se descarga por bloques con hash verificado,
  límites de almacenamiento y archivos temporales protegidos. La reproducción
  tiene pausa, avance/retroceso, velocidad, posición local y controles multimedia.
  No se ejecuta síntesis. AAC usa AVAudioPlayer y Opus el decodificador local
  de WebKit; ambos formatos se han preparado y Opus reproducido en el simulador.
  La versión Link requiere iOS/iPadOS 18.4 o posterior para este contenedor.
- Las copias de lectura existentes se conservan. No se promete disponibilidad
  offline de todo el workspace ni sincronización de edición en esta versión.
- Windows/Linux anuncian el mismo DNS-SD sin requerir dns-sd o Avahi externos.
  El código usa descubrimiento local. Las VPN que no transportan mDNS usan el QR
  o enlace, que incluyen los orígenes directos LAN/VPN; no se introduce un relay.

## Base y cambios

Desktop integra `origin/main` `db0266174` (5.17.1) en `06f6ca08`, conservando el
core portable de Study y exponiendo su constructor de fuentes para podcasts.
Los PRs siguen siendo #1089 Desktop y #30 móvil. No se fusionan ni se ejecuta CI.

El manifiesto histórico de paridad sigue siendo inventario, no criterio de
aceptación de Link. `ios/Parity/link-release.json` registra el alcance reducido;
las filas sin prueba actual permanecen pendientes. No se usan las generaciones
históricas ni las pantallas de edición de DeepSeek para aprobar este producto.

## Validación local de esta iteración

Evidencia privada en `artifacts/link-2026-11-13/` de cada repositorio.

- Desktop: contratos de podcasts, narraciones y repositorio: 7/7 PASS, cero skips.
  Incluyen dos vaults reales aislados, contenido canónico, transcripción/fuentes,
  imagen, descarga por bloques/hash, permisos, comandos prohibidos y rutas/symlinks.
- Descubrimiento: 4/4 PASS, cero skips. Publicación portable descubierta sobre mDNS
  real en este Mac, TXT exacto y cierre; además transporte HTTPS directo y
  reconexión del servidor sin activar el servicio avanzado. No equivale a haber
  ejecutado la aplicación en Windows/Linux ni en una VPN física.
- Compilación final, reproducción nativa AAC/Opus y recorrido visual actual:
  pendientes hasta terminar los comandos y revisar los resultados.
- No se ejecuta generación de pago, iPhone físico, cámara QR real, VPN física,
  TestFlight ni App Store. No se modifica la aplicación instalada ni vaults reales.

Para cerrar la beta se requiere una lectura real con Desktop del catálogo y
contenido de las seis secciones, desconexión/reconexión, reproducción y búsqueda
por capítulos, revisión iPhone/iPad vertical/horizontal, firma y subida posterior.
No se presenta este documento como certificación del 100% de esos recorridos.

## Cierre del candidato Link

`node ios/scripts/verify-release-acceptance.mjs <campaña.json> --link` comprueba
el alcance reducido de `ios/Parity/link-release.json`. El verificador histórico
sin `--link` conserva los requisitos de la paridad anterior. No se relajan sus
controles para publicar Link ni se presentan como aprobadas funciones aplazadas.

La campaña Link exige casos XCTest concretos de código/reapertura, consulta,
grafo y mapa, diccionario/informe, reproducción/transcripción/capítulos y
reconexión. Puede reunir varias ejecuciones completas, todas sin fallos ni skips,
con recibos de compilación previos y la misma revisión exacta de fuentes y Bridge.
También exige contratos y comprobaciones de Desktop, logs con hash y la entrega
explícitamente pendiente de las pruebas del iPhone físico al propietario. Los
datos ficticios se comparan antes y después para detectar escrituras inesperadas.

Los resultados finales, capturas y fallos históricos se conservan en la carpeta
privada de evidencias; los resultados públicos actualizados se registran en los
dos PR. La disponibilidad en TestFlight requiere verificar por separado firma,
subida, procesamiento de Apple y asignación a las pruebas internas.
