# Lectura sin el Mac — 18 de octubre de 2026

La campaña continúa en local, sin GitHub Actions. La única beta entregada sigue siendo 0.1.0 (1003); 1004 no está subida. La IA autónoma y la generación de audio siguen deshabilitadas, con su implementación conservada. El iPhone físico lo verificará el propietario.

## Corrección y evidencia ejecutada

La compilación nativa de `f93f1b1` pasó. Las pruebas focalizadas de buscador, chat de página, almacenamiento, cola, figuras y documento pasaron: 46 pruebas lógicas, 47 ejecuciones por parametrización, cero fallos y cero omisiones. Recibos privados: `artifacts/interface-2026-10-18/native-live-beta-focal-unit-01-*`.

La prueba posterior de figuras descargadas y PDF, con el Mac propietario realmente inaccesible, falló con `SIGABRT`. El informe de cierre identifica `CorpusNames.__deallocating_deinit`, liberado por `SpaceSession` al destruir el manejador WebKit del documento, en `swift::TaskLocal::StopLookupScope`. No se contabiliza ese intento como aprobado.

Se declara explícitamente la destrucción no aislada de `CorpusNames` y `SpaceSession`, que no requieren operaciones de actor al destruirse. La regresión libera sincrónicamente 50 sesiones y sus cachés dentro de un ámbito `TaskLocal` y exige que desaparezcan ambas referencias débiles. Pasan esa regresión, la anterior del buscador/invitación y las cuatro pruebas de lectura acotada de figuras: **6 PASS, 0 fallos, 0 omisiones** (`native-reader-session-lifetime-unit-02.xcresult`).

La repetición real **`native-old-mac-figures-offline-02.xcresult` pasa**: verifica que la dirección del Mac propietario devuelve un fallo de conexión real, lee los activos cifrados descargados, comprueba sus hashes, exporta un PDF A4 y exige más de 10.000 píxeles verdes de la figura real. Sus fuentes y ejecutables permanecen iguales durante la ejecución. Los recibos incluyen los hashes de las correcciones aún sin commit al compilar; este checkpoint se añade después de ejecutar, y las siguientes pruebas UI requieren una compilación vinculada al nuevo commit.

Se han renderizado e inspeccionado las cinco páginas del PDF exportado: portada, índice, resumen y cuerpo legibles, figura verde con ruido determinista visible y póster histórico conservado, sin recortes ni superposiciones. Son datos ficticios explícitos de aceptación, descargados del laboratorio anterior antes de su retirada. No se ha utilizado un servidor nuevo para simular que el propietario seguía disponible.

## Continuación pendiente

El laboratorio nuevo es una copia aislada de 12 vaults de nueve tipos, con identidad y puerto diferentes al Mac de la descarga anterior. El catálogo real del Mac confirma Gemini 2.5 Flash. Diccionario y grafo cuentan con expectativas verificadas por SQLite de sólo lectura; una relación manual de diccionario se ha añadido únicamente a la copia mediante el Bridge canónico, sin IA.

Continúan pendientes la campaña UI del bundle actual en iPhone e iPad, vinculación desde dispositivo limpio, edición elegida offline y sincronización/replay sin duplicados con el mismo grant, generación Live restante, paquete Desktop compatible y archivo/subida de 1004. Este resultado de PDF no acredita esas operaciones ni la paridad global. VPN/Tailscale sigue sin verificarse por falta de ese entorno; no se presenta como aprobado.
