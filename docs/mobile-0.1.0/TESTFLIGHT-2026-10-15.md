# Beta de trabajo — 15 de octubre de 2026

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
- Disponibilidad en TestFlight: **pendiente del procesamiento de Apple y asignación al grupo interno**. No se presenta la carga como una beta ya instalable.
- Las pruebas del iPhone físico corresponden al usuario después de recibirla. La campaña completa de aceptación continúa pendiente.

El primer archive detectó errores de tipos en los helpers nuevos. Se corrigieron de forma acotada en `9698599`, `97be1b6` y `49043a0`; el segundo archive pasó. Los registros y `.xcresult` se conservan fuera de Git en `artifacts/testflight-0.1.0/2026-10-15` y el directorio privado del archivo.
