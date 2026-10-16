import Testing
@testable import MuDoCore

@Suite struct SSEParserTests {
    private func parse(_ chunks: [String]) -> [SSEEvent] {
        var p = SSEParser()
        return chunks.flatMap { p.feed(Array($0.utf8)) }
    }

    @Test func singleEvent() {
        #expect(parse(["event: upsert\ndata: {\"a\":1}\n\n"]) == [SSEEvent(event: "upsert", data: "{\"a\":1}")])
    }

    @Test func partialChunks() {
        #expect(parse(["eve", "nt: ping\nda", "ta: x", "\n", "\n"]) == [SSEEvent(event: "ping", data: "x")])
    }

    @Test func multiLineDataJoinedWithNewline() {
        #expect(parse(["data: a\ndata: b\n\n"]) == [SSEEvent(event: "message", data: "a\nb")])
    }

    @Test func crlfAndBareCR() {
        #expect(parse(["event: a\r\ndata: 1\r\n\r\n", "event: b\rdata: 2\r\r"]) == [
            SSEEvent(event: "a", data: "1"),
            SSEEvent(event: "b", data: "2"),
        ])
    }

    @Test func crlfSplitAcrossChunks() {
        #expect(parse(["data: 1\r", "\n\r", "\n"]) == [SSEEvent(event: "message", data: "1")])
    }

    @Test func commentsAndUnknownFieldsIgnored() {
        #expect(parse([": keep-alive\nid: 7\nretry: 100\nevent: x\ndata: y\n\n"]) == [SSEEvent(event: "x", data: "y")])
    }

    @Test func noSpaceAfterColonAndEmptyData() {
        #expect(parse(["data:z\n\n", "data:\n\n"]) == [
            SSEEvent(event: "message", data: "z"),
            SSEEvent(event: "message", data: ""),
        ])
    }

    @Test func blankLineWithoutDataDispatchesNothingAndResetsEvent() {
        #expect(parse(["event: lost\n\n", "data: kept\n\n"]) == [SSEEvent(event: "message", data: "kept")])
    }

    @Test func utf8SplitAcrossChunks() {
        let bytes = Array("data: héllo\n\n".utf8)
        var p = SSEParser()
        let first = p.feed(bytes[0..<8])
        let second = p.feed(bytes[8...])
        #expect(first.isEmpty)
        #expect(second == [SSEEvent(event: "message", data: "héllo")])
    }
}
