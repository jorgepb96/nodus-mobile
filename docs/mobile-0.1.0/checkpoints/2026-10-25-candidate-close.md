# Cierre del candidato — 25 de octubre de 2026

Estado: **listo para revisión de Codex**, no aprobado ni publicado. Este documento
acompaña al PR móvil #30 y al PR Desktop #1089.

## Qué se corrigió en esta sesión

- **Live Activities (Xcode 27.1 / Swift 6.4).** El compilador rechazaba enviar el
  `Activity` aislado al main actor a los métodos `@concurrent` de ActivityKit. El
  controlador conserva sólo el identificador `Sendable` y resuelve el activity dentro
  de una tarea detached; actualizaciones y cierre comparten una única cadena ordenada.
  Evidencia de compilación: `native-basics-build-24` y `native-basics-build-25`.
- **Superficies compartidas de Desktop 5.16.1.** `ios/Nodus/Resources/SharedDesktop`
  se regeneró desde `de3866f2` (merge de main 5.16.1) y el manifiesto de paridad se
  regeneró; el inventario sólo cataloga las nuevas operaciones de Desktop, no las
  declara implementadas en móvil.
- **Línea temporal genealógica.** La vista tenía dos modificadores `.sheet` en la
  misma vista y SwiftUI sólo conservaba uno: pulsar un evento no abría el dossier.
  Ahora hay una sola ranura de presentación y el identificador está en el botón del
  evento, no en el contenedor que heredaba también el enlace de la persona.
- **Base de datos tipada.** El inspector tenía cuatro `.sheet` en la misma vista (el
  de iPhone nunca se presentaba) y los campos no tenían nombre accesible. Se unificó
  la presentación, se etiquetaron los controles por propiedad, los controles de
  sistema se miden por su fila de 44 pt y el nombre del archivo adjunto ya se muestra.
- **Pruebas de interfaz.** Se ajustaron al contrato real de accesibilidad (identifier
  heredado del campo de búsqueda, botón interno del `DatePicker` compacto,
  placeholders como valor, dossier acotado a la hoja y paneo en dos ejes del árbol).

## Resultado nativo en simuladores iOS 26.5

- iPhone (`583952CD-D248-4FAE-8F9F-4EA635703918`):
  - Vinculación real por código y reapertura sin otro código: **pasa**
    (`iphone-pairing-02`, 47,9 s).
  - Cronología con detalle y evidencia: **pasa** (`iphone-specialized-02`, 50,8 s).
  - Árbol: **falla** al hacer hittable el nodo del pedigree en el lienzo de dos ejes
    (`iphone-specialized-03`); el árbol y el dossier sí cargan.
  - Base de datos 29 propiedades: **falla** al presentar el inspector compacto
    (`iphone-specialized-03`), pendiente de diagnóstico.
- iPad (`2D6C613F-0B15-4C2E-BB82-1ACC5353F412`):
  - Vinculación real por código: **pasa** (`ipad-pairing-02`, 51,6 s).
  - Árbol con 18 personas, 29 relaciones, búsqueda, parentesco, pedigree y dossier:
    **pasa** (`ipad-specialized-10`, 69,9 s).
  - Cronología, detalle, cita y localización: **pasa** (`ipad-specialized-10`, 51,2 s).
  - Base de datos: las 29 propiedades, enlaces, archivo, rotación y apertura de la
    página pasan; **falla** al leer el cuerpo de la página porque la superficie
    compartida se queda en «Cargando página…» (`ipad-specialized-09`). Es un defecto
    real conservado, no un fallo de la prueba.

## Pendiente y no aprobado

- Cinco flujos reales de generación desde el móvil (diccionario, inmersión, mejora de
  nota QA, taller y Deep Research) **no se ejecutaron** en este relevo.
- Cuerpo de página de una fila tipada (superficie compartida) sigue sin cargar.
- Árbol en iPhone y presentación del inspector compacto siguen fallando.
- Prueba física, VPN/Tailscale real, cámara de QR y TestFlight corresponden al
  propietario; no se hicieron.
- No se ejecutaron Actions, no se fusionó ningún PR y no se publicó ninguna beta.
