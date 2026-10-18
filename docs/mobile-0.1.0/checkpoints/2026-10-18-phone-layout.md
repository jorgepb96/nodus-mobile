# Interfaz de iPhone — 18 de octubre de 2026

La campaña `native-phone-ios18-interactive-consultation-01` ejecutada sobre Mobile `70c7c18` y Desktop `50e7f7d3` termina con **4 aprobadas y 2 fallidas, sin omisiones**. Las fuentes y los ejecutables no cambiaron durante la ejecución. Los resultados y capturas están en `artifacts/interface-2026-10-18/` del laboratorio local; no se han ejecutado Actions.

Pasan mapa de argumentos, conservación del borrador/teclado e historial separado del chat, selección mediante una única barra del lector y etiquetas compactas del diccionario en vertical y horizontal. El chat tarda 566 segundos por esperas de animación de XCTest; pasar las aserciones no acredita todavía una interacción fluida.

La prueba del grafo falla al comparar el frame de accesibilidad del canvas: cambia de 779 a 665 puntos de ancho, ambos mayores que la ventana de 440 puntos. Capturas, WebView y cuatro controles mantienen sus dimensiones y posiciones. La prueba se corrige para verificar ese viewport y los cuatro controles, conservando la comprobación del zoom real, los datos y la ausencia de apertura accidental de un dossier. Su repetición está pendiente.

El diccionario completa el primer recorrido y se cierra en la segunda apertura. El informe registra un acceso nulo en `runtime_issue_os_log_fault_callback` de `XCTAutomationSupport`, durante una conexión TLS; no hay frame de Nodus en ese rastro. Se conserva como fallo pendiente, sin atribuir una causa definitiva ni desactivar comprobaciones del sistema.

Las capturas del lector confirman que desaparece el falso conflicto de fuentes corregido en Desktop y que la cabecera compacta deja visible el título. Se añade color de acento explícito al menú de herramientas, cuyo icono tenía contraste insuficiente en claro. También se desmonta la animación decorativa repetida del contador cuando Inicio está inactivo o la aplicación está en segundo plano; las vistas y su estado siguen conservados. No se afirma que esa animación explique las esperas del chat. Estas dos correcciones requieren compilación y repetición visual.

Siguen pendientes edición elegida offline y sincronización con el mismo vínculo sin duplicados, generación Live restante, la campaña actual de iPad y superficies especializadas, el paquete Desktop compatible y el archivo/subida de 1004. La beta disponible continúa siendo 0.1.0 (1003); no se declara paridad completa.
