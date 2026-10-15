# Alcance IA de la beta iOS

Por decisión expresa del usuario, esta beta ejecuta la IA únicamente en el Mac conectado. El modo efectivo es Live aunque exista una preferencia anterior de modo autónomo; dicha preferencia, las credenciales, los proveedores configurados, los diarios y los resultados locales se conservan para una futura reactivación. No se convierten trabajos móviles anteriores en trabajos Mac.

`BetaAIFeatures.autonomousGeneration` y `audioGeneration` están desactivados. Los ajustes no ofrecen selección autónoma ni configuración de proveedores móviles. El despacho WebKit y el proveedor nativo bloquean nuevas completions locales; el lector de claves tampoco entrega credenciales a clientes móviles. La reanudación en segundo plano de Deep Research retorna antes de modificar sus checkpoints. Sin Mac, las acciones IA deben informar que necesitan el Mac conectado, sin fallback móvil.

La consulta, la edición manual sin conexión, las copias elegidas, los documentos propios y su sincronización autorizada permanecen disponibles. Los resultados y checkpoints autónomos históricos se conservan como datos; sus pruebas anteriores no acreditan generación disponible en esta beta. La generación autónoma y la generación de audio quedan aplazadas, no aprobadas como paridad de la beta.

Validación de este cambio: parse Swift focal; nuevas aserciones de modo efectivo y preferencia conservada preparadas en SmokeTests, sin ejecución nativa durante esta edición. La prueba UI Live conserva las esperas del catálogo y del modelo real del Mac; sustituye únicamente la elección de modo por la comprobación del estado Live sin selector. La campaña nativa y los proveedores reales corresponden a la validación integrada posterior.
