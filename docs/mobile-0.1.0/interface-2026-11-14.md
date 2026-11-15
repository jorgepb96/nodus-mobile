# Nodus Link 0.1.0 (1006): interfaz y alcance académico

Revisión del 14 de noviembre de 2026 a partir de las capturas y pruebas del propietario
sobre la beta 1005. El [PR móvil #30](https://github.com/jorgepb96/nodus-mobile/pull/30)
registra el estado actualizado de aceptación y distribución del candidato 1006.

## Alcance de producto

Solo se muestran y abren vaults académicos. La vinculación sigue siendo del workspace
completo por código, QR o enlace; no añade una selección de permisos o bóvedas.
Los tipos de vault y sus funciones anteriores se conservan en el código y en los datos
locales, pero no aparecen en el selector, la navegación ni las tareas de consulta de Link.
La creación, edición, generación de IA y audio y los proveedores autónomos permanecen
retenidos y deshabilitados. La consulta incluye ideas, fuentes, grafo, mapas de argumentos,
Deep Research, diccionario y podcasts guardados, con biblioteca, autores y búsqueda.

## Cambios de interfaz

- iPhone: Inicio, Ideas, Explorar y Buscar en la navegación inferior. Explorar reúne
  las demás consultas. Los documentos usan una fila compacta con vuelta al catálogo,
  título, cierre y selector de documentos abiertos. No hay una hilera de pestañas largas.
- iPad: se mantiene la barra lateral y la presentación de documentos más cercana a Desktop.
- Inicio: nombre del vault, ordenador de origen, búsqueda y accesos a las seis consultas
  principales. Las tarjetas y el buscador tienen una jerarquía y medidas comunes.
- Lectura: mismo tratamiento de citas como referencias subrayadas dentro del párrafo,
  sin cápsulas coloreadas ni prefijos decorativos. Colores legibles en claro y oscuro,
  ancho acotado, párrafos justificados y tamaño de texto adaptable. Las tablas y fórmulas
  mantienen su ampliación o desplazamiento local sin ensanchar toda la página.
- Deep Research: catálogo y lectura nativos, portadas privadas en miniatura y al abrir el
  informe. No se reserva un gran bloque vacío si el informe no tiene imagen. El lector
  conserva fuentes, traducciones guardadas, copia, exportación y selección de texto.
- Podcasts: miniaturas en el catálogo, portada del episodio y reproductor de la sesión.
  Cerrar su ventana permite seguir consultando otras secciones. Un minirreproductor
  permite reabrir, pausar o detener. Se conservan posición, capítulos, transcripción,
  fuentes, velocidad y controles del sistema, con soporte de AAC y Ogg/Opus. Pausa
  y avance permanecen fuera del scroll de la portada para evitar recortes en las
  ventanas de iPad, en horizontal y con tamaños de texto accesibles.
- Imágenes: lectura por el Bridge privado y caché de memoria limitada a 20 MiB y 80 objetos.
  No se crea una copia completa del workspace ni se usan URLs públicas para las portadas.

## Recuperación y demostración

El servidor de presentación que sirve los componentes incluidos en la app es local al
propio iPhone/iPad; no es el servidor de Nodus Desktop. Ahora invalida su dirección cuando
falla o se cancela, limita el arranque a diez segundos y permite dos recuperaciones
controladas del lector. Los fallos de ese lector no se describen como una pérdida de
conexión con el ordenador. Las vistas web pesadas se liberan al dejar su sección.
El catálogo de podcasts de demostración no intenta contactar con un ordenador inexistente.

## Comprobaciones y evidencias

La aceptación usa vaults ficticios aislados y el Bridge HTTPS real. No se modifica la
aplicación instalada, ningún vault del propietario ni se compran generaciones de IA.
Las fuentes, binarios firmados, entradas XCTest y resultados se vinculan antes de ejecutar
las pruebas. Los recibos y `.xcresult` se conservan en las carpetas privadas
`artifacts/link-visual-2026-11-14/` y `artifacts/link-2026-11-13/` del Mac.

Los recorridos incluyen código y reapertura, pérdida y recuperación del Mac, selección
en grafo y mapa en ambas orientaciones, lectura de diccionario y versiones/evidencias,
informes con portada real, reproducción y búsqueda temporal, cambio de sección y segundo
plano. También se comprueban las citas en WebKit claro/oscuro, los destinos táctiles de
44 pt, documentos largos, navegación inferior y texto accesible.

Durante la iteración se conservaron los resultados fallidos. La rotación de los dos
simuladores volvió a funcionar tras reiniciarlos; no se rebajaron las aserciones. Se
corrigieron los marcos táctiles que quedaban limitados al texto del botón, la identificación
accesible del minirreproductor y el arranque de la carga de portadas sobre un contenedor
vacío. El cómputo final solo utiliza ejecuciones terminadas, sin fallos ni omisiones.

El inventario histórico de paridad no certifica estas comprobaciones. El manifiesto
`ios/Parity/link-release.json` define el alcance del candidato y sus requisitos de aceptación.
El estado y los enlaces de distribución se registran por separado en el PR.

Las pruebas físicas corresponden al propietario: cámara de QR, VPN/Tailscale real y
presentación de imagen y controles con el iPhone bloqueado no se certifican con el simulador.
Las capturas y descripciones de la ficha de App Store siguen siendo una entrega aparte.
