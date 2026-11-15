import Testing
@testable import Nodus

@Suite("Rich report source and stable references")
@MainActor
struct RichCorpusProseTests {
    @Test("A formatted report retains all block boundaries and literal code")
    func sourcePreservation() {
        let source = """
        ## Fórmulas y datos

        | Año | Valor | Unidad | Fuente |
        | --- | ---: | --- | --- |
        | 2026 | $x^2$ | m² | nodus://idea/source-1 |

        ```markdown
        #### Encabezado literal
        nodus://idea/not-a-citation
        ```

        `nodus://idea/inline-literal` y nodus://idea/source-2
        """
        let actual = CorpusProse.linkifyRichText(source, labels: ["nodus://idea/source-1": "Fuente 🌊", "nodus://idea/source-2": "Segunda fuente"])
        #expect(actual.contains("#### Encabezado literal\nnodus://idea/not-a-citation"))
        #expect(actual.contains("`nodus://idea/inline-literal`"))
        #expect(actual.contains("| 2026 | $x^2$ | m² | [Fuente 🌊](nodus://idea/source-1) |"))
        #expect(actual.contains("[Segunda fuente](nodus://idea/source-2)"))
        #expect(actual.components(separatedBy: "\n").count == source.components(separatedBy: "\n").count)
        #expect(RichCorpusProse.isRequired(source))
    }
    @Test("Plain mobile prose retains TextKit while existing math and figures use full rendering")
    func readerChoice() {
        #expect(!RichCorpusProse.isRequired("Una frase con **énfasis** y [una cita](nodus://idea/one)."))
        #expect(RichCorpusProse.isRequired("La ecuación $E = mc^2$ conserva su formato."))
        #expect(RichCorpusProse.isRequired("$$\n\\sum_{i=1}^{n} x_i\n$$"))
        #expect(RichCorpusProse.isRequired("<img src='nodus-library://attachment/document/asset' alt='Figura'>"))
    }
}
