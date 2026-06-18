import Testing
@testable import NOUS_0

// TagNormalizer is the last-resort filter that keeps atom tags specific and
// retrieval-friendly. These pin the contract documented in CLAUDE.md:
// lowercase, hyphenate whitespace, strip non-[a-z0-9-], dedupe, drop blocklisted
// generics, cap at 4.
struct TagNormalizerTests {

    @Test("normalizeOne lowercases and hyphenates whitespace")
    func hyphenatesWhitespace() {
        #expect(TagNormalizer.normalizeOne("Hello World") == "hello-world")
        #expect(TagNormalizer.normalizeOne("Supabase   RLS") == "supabase-rls")
    }

    @Test("normalizeOne strips leading hashes and punctuation")
    func stripsNoise() {
        #expect(TagNormalizer.normalizeOne("#supabase") == "supabase")
        #expect(TagNormalizer.normalizeOne("openai-board!!") == "openai-board")
        #expect(TagNormalizer.normalizeOne("  --edge--case-- ") == "edge-case")
    }

    @Test("normalizeOne collapses hyphen runs and trims edges")
    func collapsesHyphens() {
        #expect(TagNormalizer.normalizeOne("a   b   c") == "a-b-c")
        #expect(TagNormalizer.normalizeOne("-leading and trailing-") == "leading-and-trailing")
    }

    @Test("normalize drops blocklisted generic tags")
    func dropsBlocklisted() {
        let out = TagNormalizer.normalize(["ai", "notes", "supabase-rls", "productivity"])
        #expect(out == ["supabase-rls"])
    }

    @Test("normalize dedupes and caps at 4")
    func dedupesAndCaps() {
        let out = TagNormalizer.normalize([
            "alpha", "alpha", "beta", "gamma", "delta", "epsilon"
        ])
        #expect(out == ["alpha", "beta", "gamma", "delta"])
        #expect(out.count <= 4)
    }

    @Test("normalize returns empty for all-blocklisted/empty input")
    func emptyWhenAllFiltered() {
        #expect(TagNormalizer.normalize(["ai", "notes", "", "   "]).isEmpty)
    }
}
