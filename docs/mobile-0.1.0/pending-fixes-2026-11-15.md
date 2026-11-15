# Correcciones acotadas posteriores a TestFlight 1006

El propietario ha autorizado la ronda final de verificaciones, la integración en main de ambos
repositorios y una nueva compilación TestFlight 0.1.0 (1007). Los resultados ejecutados se
registran por intento en `artifacts/link-review-20261115/`; no se consideran aprobadas
comprobaciones pendientes o fallidas. El iPhone físico sigue a cargo del propietario.

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
- Selección de texto: paleta contextual compartida de seis colores pastel, tanto para crear
  resaltados como para cambiar su color. Las muestras conservan el color en los menús de iOS.
- Al tocar un resaltado, «Quitar resaltado» aparece como primera acción, sin confirmación
  adicional. «Añadir comentario» vuelve al menú de selección y al de un resaltado existente.
- Comentarios: panel con alturas mediana y grande y botón «Guardar» con texto.
- Las anotaciones personales de informes (resaltados, comentarios y marcadores) constituyen
  una excepción acotada al modo consulta: requieren un vault académico vinculado y permiso
  de escritura. No habilitan edición general ni generación. La cola de este lector envía y
  reintenta exclusivamente anotaciones ya autorizadas, sin liberar otros borradores retenidos.
- El Bridge privado incorpora las anotaciones de los informes exportados de ese vault y las
  incluye en su revisión privada. La publicación pública sigue excluyendo estos datos.
- Final de scroll: navegación inferior y minirreproductor pasan a ocupar espacio real como
  hermanos del viewport, en lugar de depender de un safe-area inset exterior a NavigationStack.
  Las rutas activas e inactivas reciben la altura útil restante; el tamaño de la barra se
  calcula por su contenido, incluida orientación, tamaño de texto y presencia del reproductor.
  La corrección es común a listas, lectores, destinos abiertos y superficies web, sin añadir
  márgenes fijos distintos a cada pantalla.
- Pantalla completa del mapa de argumentos: las dos entradas móviles (mapa guardado y mapa
  abierto desde una idea) pasan el callback nativo `surfaceFullscreen`. El mapa deja de pedir
  la API de fullscreen del navegador en WKWebView, se ajusta al viewport seguro y conserva
  «Salir de pantalla completa». Cerrar/cambiar el mapa o volver al catálogo restaura los
  controles nativos; la API de Desktop se conserva. El cambio está en las fuentes compartidas
  del checkout Desktop citado abajo; su bundle iOS se regenerará en la tanda final, sin
  modificar a mano los archivos compilados.
- Temas del grafo: un único campo «Buscar ideas y temas» filtra los temas y muestra ambos
  tipos de coincidencias en el mismo desplegable, con navegación por teclado y etiquetas
  accesibles. El cambio entre lista y constelación pasa a un icono táctil de 44 puntos junto
  al buscador. Se elimina la segunda caja y la fila del botón anterior; la lista empieza tras
  los metadatos sin reservar un hueco fijo para controles inexistentes. Incluye traducciones
  en todos los idiomas del renderer compartido. Bundle iOS pendiente de la tanda final.
- Ficha de autor: los roles bibliográficos `author`/`editor` se presentan mediante las claves
  localizadas «Author»/«Editor» del catálogo nativo, en lugar de capitalizar el identificador
  recibido. La etiqueta «Not attributed» de esa misma fila también consulta el catálogo.
  No se traducen ni modifican nombres ni títulos de las obras.
- Cabecera del grafo: pantalla completa y nueva pestaña comparten geometría y aspecto móvil:
  44 puntos de ancho, altura de la fila, icono de 18 puntos, mismo fondo, borde y esquinas
  superiores. Se elimina el margen inferior y el formato de botón independiente de pantalla
  completa; en iPhone/iPad conserva su nombre accesible y tooltip, sin texto visible largo.
- Navegación iPhone: cápsula Liquid Glass mediante el material nativo compartido de Nodus,
  con fallback para versiones previas y preferencias de accesibilidad. Siempre cinco posiciones:
  Inicio, tres accesos configurables y Más. Valores iniciales: Ideas, Grafo y Deep Research.
  Más sustituye a Explorar y contiene todas las secciones académicas no fijadas, también
  Buscar, Autores, Biblioteca y Ajustes cuando corresponda.
- Biblioteca y Ajustes permanecen siempre accesibles en Más, aunque también estén fijados
  en uno de los tres accesos de la barra inferior.
- Personalización: chinchetas independientes en la esquina de las tarjetas de Inicio y en la
  cabecera de cada sección. Fijar una cuarta pide elegir cuál sustituir; desfijar deja un
  acceso «Fijar» para escoger otra sección, manteniendo cinco posiciones. Preferencia guardada
  con SyncedDefaults, saneada contra rutas admitidas y sincronizada entre dispositivos; no
  cambia el contenido ni los permisos del vault. iPad conserva la navegación lateral.
- La barra adapta icono/etiqueta a vertical y horizontal y mantiene objetivos táctiles de al
  menos 44 puntos. El footer sigue reservando su altura real, incluido el minirreproductor.
- Reproductor de podcasts: menú superior con icono de puntos de 18 puntos, color primario
  dinámico y objetivo de 44 puntos, en lugar del círculo de bajo contraste. Carátula y
  transporte comparten un flujo de contenido con separación acotada, sin un ScrollView
  flexible entre ambos que empuje los controles al pie. Horizontal ancho: carátula y controles
  lado a lado; alturas pequeñas/texto accesible: transporte desplazable completo. Títulos de
  hasta tres líneas (sin límite en accesibilidad), carátula adaptativa y símbolo Nodus si
  falta imagen. Se conservan identificadores, seek, controles y reproducción en segundo plano.
- Buscar: campo único, sin selector Texto/Semántica. Muestra primero los resultados textuales,
  los amplía con relacionados, fusiona por identidad canónica y rango (sin comparar cosenos con
  posiciones textuales), conserva filtros por tipo y el origen de los pasajes. Las peticiones
  canceladas o de una consulta antigua no reemplazan la actual ni su indicador de carga.
- Búsqueda vinculada: nuevo POST privado `search/related` con permiso corpus y límite de
  consulta/resultados. Reutiliza la búsqueda semántica canónica de Desktop bajo el contexto
  explícito del vault vinculado, con sus proveedores e índice activo. iOS no necesita ni usa
  sus claves para este camino. No permite iniciar preparación/activación/indexación. Se
  clasifica como lectura en ambos extremos, sin cola de edición ni resultados semánticos
  inventados sin conexión. Si falla o falta la actualización de Desktop, conserva búsqueda
  textual y muestra un aviso localizado. La implementación previa con modos se conserva para
  sus otros consumidores; el lector móvil usa la operación unificada.
- Iconos en menús oscuros: las acciones superiores (Comandos, Actualizar, Tema y Ajustes)
  usan una etiqueta compartida con icono resuelto para el tema y aplanado como imagen original,
  evitando que la conversión de Label a una acción UIKit conserve una plantilla negra.
  Aplica también a los menús Más/Fijar y a Exportar audio, incluido el recurso del telescopio.
  Texto, nombres accesibles y acciones se conservan; blanco en oscuro y negro en claro.
- Selector de espacios tras desconexión: timeouts/pérdidas de red dejan de generar el aviso
  global permanente «Trabajo local conservado». Se conserva el vínculo y se indica que el
  ordenador no está disponible en sus tarjetas; el estado se limpia tras una respuesta
  autenticada de ese ordenador. La reconexión también limpia su aviso de conexión antiguo.
- Los errores reales de recuperación se separan por vínculo y origen (catálogo, revocación,
  limpieza de credenciales). Una recuperación completa limpia sólo su propio aviso; otro Mac
  no puede borrarlo por reconectar. Botón Cerrar en esos avisos: oculta la misma incidencia
  repetida sin borrar trabajo, claves o pendientes ni detener los reintentos. Las cancelaciones
  no se presentan como fallo, y los problemas de certificados/permisos no se ocultan como
  simples fallos de red.
- Biblioteca: selector ordenado como Obras a la izquierda y Documentos a la derecha,
  conservando la asociación de cada pestaña con su contenido.

Las correcciones de lectura y contratos requieren también actualizar Desktop. Están en
el checkout `/Users/jorgepb96/.codex/worktrees/8ff4/nodus/artifacts/mobile-settings-navigation`,
rama `codex/link-reading-downloads-1007` (PR Desktop #1356; #1355 ya se integró).
La CI de Desktop está autorizada. No se deben ejecutar Actions del repositorio móvil. El laboratorio final debe compilar ese código, no el
checkout congelado utilizado para validar la beta 1006.

Campaña de verificación autorizada: comprobar lectura y cambios de filtro con estados reales de
Desktop, retorno desde el lector y actualización; revisar mensajes vacío/sin coincidencias;
consultar contratos modernos y antiguos sin mezclar espacios vectoriales; revisar aviso,
reintento y traducciones; seleccionar los seis colores, cambiar y quitar resaltados, guardar
y reabrir comentarios y comprobar sincronización en ambos sentidos, incluida la recuperación
tras reconectar sin enviar otros trabajos retenidos; llegar al último párrafo, fila y control
en lectores, diccionario, listas y destinos abiertos, en iPhone/iPad, ambas orientaciones y
tamaños de texto, con y sin minirreproductor; compilar y distribuir una nueva beta.
También: entrar y salir de pantalla completa en mapas guardados y abiertos desde una idea,
conservar selección y cámara, cambiar/cerrar el mapa y comprobar ambos temas y orientaciones.
Buscar temas e ideas desde el campo único, abrir cada tipo de resultado, limpiar la búsqueda
y alternar lista/constelación desde el icono, con teclado y VoiceOver y sin desbordar la fila.
Fijar, desfijar y reemplazar accesos; comprobar cinco posiciones, secciones de Más, indicador
de selección, reapertura, cambio de vault y adopción de preferencias remotas, además del
material claro/oscuro, reducción de transparencia y orientación horizontal.
Revisar también icono superior y distribución del reproductor en ambas orientaciones, con
carátula/sin imagen, títulos largos y tamaños accesibles, hasta alcanzar todos los controles.
Buscar un término literal y un sinónimo desde el campo único; comprobar resultados parciales,
fusión sin duplicados, procedencia, filtros, escritura rápida/borrado/salida y respuestas fuera
de orden. Probar Desktop actualizado/antiguo, índices ausentes o incompatibles, desconexión,
permisos entre vaults y ausencia de indexación/escrituras o llamadas a proveedores desde iOS.
Abrir los menús superior, Más, Fijar y de audio en ambos temas, cambiar el tema y reabrirlos,
incluido tema del sistema y reducción de transparencia, para comprobar el contraste de iconos.
Perder conexión, provocar timeout, volver a la misma red y cambiar de red: comprobar tarjetas,
reconexión y retirada del aviso anterior, también con dos ordenadores vinculados y en demo.
Cerrar un aviso real y repetir la misma incidencia; comprobar que una incidencia diferente se
muestra y que los datos de recuperación permanecen intactos.
Los cambios de este lote no están incluidos en TestFlight 1006. La distribución de 1007
requiere superar las verificaciones y comprobar la firma y la configuración Release.


Descargas y selector de espacios:

- Ocho secciones académicas con copias completas seleccionadas: ideas, autores, diccionario,
  Deep Research, grafo, mapa de argumentos, biblioteca y catálogo de podcasts. Cada copia
  se sustituye atómicamente, cifrada, durante 30 días, con los límites existentes de 50 MiB
  por descarga y presupuesto compartido por ordenador. No se descargan índices vectoriales,
  documentos originales, grabaciones ni audio como parte de una sección.
- Audio y carátula por episodio descargables por separado. Eliminar descarga detiene el
  episodio activo cuando corresponda y elimina únicamente sus archivos locales, sin mutaciones
  canónicas. El catálogo descargado no implica que el audio esté disponible sin conexión.
- Estado circular: verde en directo, verde descargado y actualizado, naranja si hay cambios;
  estados grises expresos sin conexión o durante la comprobación. El naranja actualiza al tocar.
  Una lectura desde caché no acredita conexión. La comprobación exige HEAD autenticado.
- La consulta de copias seleccionadas solo se activa ante errores de transporte. Respuestas
  de permisos, autenticación o certificados nunca se sustituyen por contenido antiguo.
  La retirada o caducidad del manifiesto invalida también el lector en memoria. Las tablas
  completas más recientes conservan las eliminaciones frente a otras secciones antiguas.
- El selector de vaults es un popover compacto anclado a la cabecera. Cambiar de vault no
  exige abandonar la navegación. «Gestionar conexiones» abre deliberadamente el gestor completo.
- Las anotaciones personales se encolan en orden y solo se envía su tabla autorizada. La
  consulta no libera notas, documentos u otros trabajos retenidos de funciones deshabilitadas.

Evidencias iniciales de implementación: NodusKit 580/580 y dos pruebas nuevas de secciones;
Desktop: ocho proyecciones de sección, revisiones estables, HEAD sin cuerpo y cero llamadas
IA. Los intentos nativos de compilación se conservan, incluidos los errores corregidos; la
aceptación visual y offline requiere sus propios resultados finales en el directorio citado.
