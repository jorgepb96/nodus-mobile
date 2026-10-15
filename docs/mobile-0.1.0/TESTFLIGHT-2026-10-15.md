# Beta de trabajo — 15 de octubre de 2026

## Actualización de conexión — 0.1.0 (1003)

**Disponible en TestFlight interno.** El navegador integrado confirma «En pruebas» para la build **1003**, añadida a **Nodus interno** (un tester: el propietario). Las notas de pruebas están guardadas. No se ha enviado a la App Store ni a grupos externos.

- App y extensión: **0.1.0 (1003)**; firma estricta verificada en ambas.
- Archive Release desde móvil `d51aa71aae1f4450efe6e2293d3dc635b760c165`; fuentes sin cambios durante la compilación. Las superficies compartidas mantienen la procedencia Desktop `80c54bd09e0aa8d85f96b1978f05094fe7d2316f` de la beta 1002.
- Xcode confirma `ARCHIVE SUCCEEDED`, `Upload succeeded` y `EXPORT SUCCEEDED`. Apple terminó de procesarla; ID de build `37aaf608-8715-4c26-8e7a-d01e1065be18`.
- Ejecutable de la app: SHA-256 `3310725215c5b550f7a4632e1a29fbb3840db92dcff69215599ebeb8e65e340a`; extensión: `198119619b0da97df2a479b84fce472d363117905a2270caa64ffc0b98ee6f4a`.
- [Build 1003 en App Store Connect](https://appstoreconnect.apple.com/teams/36804ede-f0b5-4cd2-a273-c619feb6168f/apps/6820425852/testflight/ios/37aaf608-8715-4c26-8e7a-d01e1065be18).

Incluye redetección del Mac por Bonjour con certificado e identidad verificados, credenciales canónicas, recuperación de modelos y estado semántico, y ajustes de renovación/revocación. El [checkpoint de conexión](checkpoints/pairing-reconnection-2026-10-15.md) conserva las pruebas reales de código/HTTPS, iPhone/iPad Simulator, reinicios, puerto ocupado, vaults añadidos/eliminados, controles nativos y Desktop firmado. Cada ejecución mantiene sus revisiones reales: el archive no sustituye la aceptación funcional ni convierte pruebas históricas en pruebas del HEAD de documentación.

**Requiere el Desktop compatible del PR #1089.** Instalar esta beta no actualiza el Nodus ya instalado. Se ha preparado y probado un paquete privado firmado de Desktop; la instalación normal permanece intacta. Tailscale/VPN real y cámara/iPhone físico siguen pendientes (el físico corresponde al propietario). La paridad global continúa incompleta; se mantienen las limitaciones de la primera beta descritas abajo.

Evidencias privadas: `artifacts/testflight-0.1.0/2026-10-15-1003/` contiene recibo de fuentes, verificación de firmas, logs de archive/carga, resultado de entrega y capturas actuales de App Store Connect. La gestión de Apple se realizó en el navegador integrado.

## Registro de la primera beta — 1002

El usuario solicita expresamente subir el estado actual a TestFlight para probarlo desde su móvil. Esta instrucción sustituye la secuencia anterior de esperar a cerrar toda la paridad antes de entregar la primera beta. La paridad completa continúa pendiente: no se declara aprobada por publicar esta compilación.

- Versión preparada: **0.1.0 (1002)**, app y extensión.
- Ficha Apple: Nodus Research Workspace, ID `6820425852`.
- Bundle: `com.drakonis96.nodus.ios`; equipo `6RPLS9EA4X`.
- Distribución solicitada: **solo TestFlight interno**, para el propietario. No App Store ni pruebas externas.
- App Store Connect se gestiona en el navegador integrado; el archivo firmado se envía mediante la herramienta de carga de Xcode.
- Los PR continúan abiertos y sin merge. No se ejecutan ni modifican workflows de GitHub Actions.

## Qué probar

Vinculación por código/enlace/QR al Mac, navegación y lectura de los vaults, informes/diccionario, grafos y mapas, chat e historial, Scriptor y descargas disponibles. Revisar teclado, selección de texto y distribución en vertical y horizontal.

## Limitaciones conocidas

Deep Research todavía tiene pendientes la guía completa, fuentes descargadas elegidas para generación autónoma, opciones visuales y ajustes de galería/publicación. Las últimas variantes requieren validación con proveedores reales. Adjuntos, relaciones y acciones IA/botones de bases de datos tienen integraciones incompletas; algunos controles pueden devolver un error explícito. La campaña completa de sincronización, revocación y revisión visual sigue pendiente.

Los detalles y evidencias anteriores permanecen en [STATUS-2026-10-13.md](STATUS-2026-10-13.md) y sus checkpoints. La publicación de esta beta no convierte esas comprobaciones pendientes en resultados satisfactorios.

## Entrega

- Archive Release: **correcto**, firmado y verificado; app/extensión 0.1.0 (1002).
- Fuentes del archivo: móvil `bd1f0081214bf90847c4714f4942dafc88c0b14f`; superficies Desktop `80c54bd09e0aa8d85f96b1978f05094fe7d2316f`.
- Carga a Apple: **correcta**, `Upload succeeded` / `EXPORT SUCCEEDED`.
- Disponibilidad en TestFlight: **confirmada**. Apple terminó de procesar la build y muestra **«En pruebas»** para 0.1.0 (1002), asignada a **Nodus interno** (un tester: el propietario).
- Las notas de pruebas y limitaciones están guardadas en TestFlight. La distribución automática permanece desactivada; no hay grupos externos.
- [Compilación en App Store Connect](https://appstoreconnect.apple.com/teams/36804ede-f0b5-4cd2-a273-c619feb6168f/apps/6820425852/testflight/ios/3d7bb84e-38a4-4c63-afa0-3eea964c91ea). La aceptación de la invitación e instalación en el iPhone quedan a cargo del usuario.
- Las pruebas del iPhone físico corresponden al usuario después de recibirla. La campaña completa de aceptación continúa pendiente.

El primer archive detectó errores de tipos en los helpers nuevos. Se corrigieron de forma acotada en `9698599`, `97be1b6` y `49043a0`; el segundo archive pasó. Los registros y `.xcresult` se conservan fuera de Git en `artifacts/testflight-0.1.0/2026-10-15` y el directorio privado del archivo.
