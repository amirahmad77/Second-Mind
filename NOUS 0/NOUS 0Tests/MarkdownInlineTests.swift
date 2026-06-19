import Testing
@testable import NOUS_0

// MarkdownInline.plain produces the Stream row one-liner: first non-empty line,
// block prefixes + inline markers stripped, wikilinks aliased. These guard the
// preview from leaking raw markdown.
struct MarkdownInlineTests {

    @Test("plain takes the first non-empty line")
    func firstNonEmptyLine() {
        #expect(MarkdownInline.plain("first\nsecond") == "first")
        #expect(MarkdownInline.plain("\n\n   \nreal content") == "real content")
    }

    @Test("plain strips heading prefixes")
    func stripsHeadings() {
        #expect(MarkdownInline.plain("# Heading") == "Heading")
        #expect(MarkdownInline.plain("### Deep heading") == "Deep heading")
    }

    @Test("plain strips checklist and bullet prefixes")
    func stripsListPrefixes() {
        #expect(MarkdownInline.plain("- [ ] task item") == "task item")
        #expect(MarkdownInline.plain("- [x] done item") == "done item")
        #expect(MarkdownInline.plain("- bullet") == "bullet")
    }

    @Test("plain strips numbered-list prefixes")
    func stripsNumberedList() {
        #expect(MarkdownInline.plain("12. numbered") == "numbered")
    }

    @Test("plain returns empty for blank input")
    func blankInput() {
        #expect(MarkdownInline.plain("") == "")
        #expect(MarkdownInline.plain("   \n  ") == "")
    }
}
