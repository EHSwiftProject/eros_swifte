import EHModels
import Testing

@Suite struct TagTranslationTests {
    @Test(arguments: [
        ("![图](https://example.invalid/a.png) 长示例", "长示例"), ("示例标签", "示例标签"),
        ("![](https://example.invalid/a.png) a ![x](https://example.invalid/b.png) b", "a b"),
    ])
    func plainNameDropsMarkdownImages(_ name: String, _ plain: String) {
        let tag = TagTranslation(namespace: "female", key: "fake tag", name: name, intro: "", links: "")
        #expect(tag.plainName == plain)
    }
}
