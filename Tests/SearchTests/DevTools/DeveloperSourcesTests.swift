import XCTest
@testable import Search

final class DeveloperSourcesTests: XCTestCase {
    // MARK: Helpers

    private func pieces(_ text: String, _ language: SourceLanguage) -> [(String, SourceTokenKind)] {
        let units = Array(text.utf16)
        return SourceHighlighter.tokens(text, language: language).map {
            (String(decoding: units[$0.start..<$0.end], as: UTF16.self), $0.kind)
        }
    }

    private func kind(of piece: String, in text: String, _ language: SourceLanguage, occurrence: Int = 0) -> SourceTokenKind? {
        pieces(text, language).filter { $0.0 == piece }.dropFirst(occurrence).first?.1
    }

    private func format(_ text: String, _ language: SourceLanguage) -> String {
        SourceFormatter.format(text, language: language).text
    }

    /// The formatter may only change whitespace.
    private func assertOnlyWhitespaceChanged(_ input: String, _ language: SourceLanguage, file: StaticString = #filePath, line: UInt = #line) {
        let output = format(input, language)
        let squeeze = { (s: String) in s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined() }
        XCTAssertEqual(squeeze(output), squeeze(input), "non-whitespace changed", file: file, line: line)
    }

    // MARK: JavaScript tokens

    func testInlineValuesShowOnlyBindingsUsedOnEachLineThroughThePause() {
        let source = """
            function previous(n) { use(n); }
            function current(n) {
              obj.n; const shape = { n: "n" }; // n
              use(n, n, unavailable);
              { let n = 9; use(n, total); }
              use(total);
            }
            """
        let starts = SourceLexing.lineStarts(source)
        let request = SourceInlineValues.Request(displayID: 0, start: starts[1], throughLine: 5, jsx: false, bindings: [
            "n": [.init(start: starts[4], value: "9"), .init(start: starts[1], value: "2")],
            "total": [.init(start: starts[1], value: "11")],
        ])
        XCTAssertEqual(request.annotations(in: source, lineStarts: starts), [
            2: "n = 2", 4: "n = 2", 5: "n = 9, total = 11",
        ])
    }

    func testInlineValuesSkipParametersOfNestedFunctions() {
        let source = """
            function outer(x) {
              list.map(x => x + 1);
              list.forEach(function (x) { use(x); });
              return x;
            }
            """
        let starts = SourceLexing.lineStarts(source)
        let request = SourceInlineValues.Request(displayID: 0, start: 0, throughLine: 4, jsx: false, bindings: [
            "x": [.init(start: 0, value: "1")],
            "list": [.init(start: 0, value: "Array(2)")],
        ])
        XCTAssertEqual(request.annotations(in: source, lineStarts: starts), [
            1: "x = 1", 2: "list = Array(2)", 3: "list = Array(2)", 4: "x = 1",
        ])
    }

    func testInlineValuesInAnAuthoredFileUseTheNamesItsMapGives() throws {
        // function f(user) {          →  function f(e){return e+t}
        //   return user + count;
        let generated = "function f(e){return e+t}"
        let map = try DeveloperSourceMap(text: """
            {"version":3,"sources":["a.js"],"names":["user","count"],"mappings":"WAAWA,UACFA,EAAOC"}
            """, mapURL: nil, scriptURL: "https://example.test/app.js")
        let source = try XCTUnwrap(map.sources.first)
        let names = SourceInlineValues.authoredNames(map: map, generated: generated, source: source,
                                                     from: (0, 0), throughLine: 1)
        XCTAssertEqual(names, ["user": "e", "count": "t"])
        // The runtime's `e` and `t` show as `user` and `count`; its own
        // `count` (some other variable) doesn't, and `e` isn't itself.
        let bindings = SourceInlineValues.authored([
            "e": [.init(start: 0, value: "\"Ada\"")], "t": [.init(start: 0, value: "2")],
            "count": [.init(start: 0, value: "99")],
        ], names: names)
        XCTAssertEqual(bindings, ["user": [.init(start: 0, value: "\"Ada\"")], "count": [.init(start: 0, value: "2")]])
        XCTAssertEqual(SourceInlineValues.authoredNames(map: map, generated: generated, source: source,
                                                        from: (1, 0), throughLine: 1),
                       ["user": "e", "count": "t"])
        XCTAssertEqual(SourceInlineValues.authoredNames(map: map, generated: generated, source: source,
                                                        from: (0, 0), throughLine: 0), ["user": "e"])
    }

    func testInlineValuesStaySingleLineAndFitTheAnnotationBudget() {
        let source = "value"
        let request = SourceInlineValues.Request(displayID: 0, start: 0, throughLine: 1, jsx: false, bindings: [
            "value": [.init(start: 0, value: "title\n" + String(repeating: "x", count: 100))],
        ])
        let text = request.annotations(in: source, lineStarts: [0])[1]
        XCTAssertEqual(text?.count, 80)
        XCTAssertTrue(text?.hasPrefix("value = title x") == true)
        XCTAssertTrue(text?.hasSuffix("…") == true)
    }

    func testJavaScriptTokenKinds() {
        let text = #"function add(a,b){return a+b} // sum"# + "\n" + #"const x = "hi", n = 0x1F, re = /a\/b[/]c/gi, t = `v=${x + 1}`; obj.prop = true; null"#
        XCTAssertEqual(kind(of: "function", in: text, .js), .keyword)
        XCTAssertEqual(kind(of: "add", in: text, .js), .definition)
        XCTAssertEqual(kind(of: "return", in: text, .js), .keyword)
        XCTAssertEqual(kind(of: "// sum", in: text, .js), .comment)
        XCTAssertEqual(kind(of: "\"hi\"", in: text, .js), .string)
        XCTAssertEqual(kind(of: "0x1F", in: text, .js), .number)
        XCTAssertEqual(kind(of: #"/a\/b[/]c/gi"#, in: text, .js), .stringSpecial)
        XCTAssertEqual(kind(of: "`v=${", in: text, .js), .string)
        XCTAssertEqual(kind(of: "}`", in: text, .js), .string)
        XCTAssertEqual(kind(of: "prop", in: text, .js), .property)
        XCTAssertEqual(kind(of: "true", in: text, .js), .atom)
        XCTAssertEqual(kind(of: "null", in: text, .js), .atom)
        XCTAssertEqual(kind(of: "x", in: text, .js), .definition)
    }

    func testDivisionIsNotARegex() {
        let text = "a = b / c / d; e = (f) / 2 / g; h = i[0] / j / k"
        XCTAssertFalse(pieces(text, .js).contains { $0.1 == .stringSpecial })
        XCTAssertEqual(kind(of: "/x/g", in: "if (s.match(/x/g)) return /x/g", .js, occurrence: 1), .stringSpecial)
    }

    func testTemplateExpressionsAreCode() {
        let text = "`a ${ {b: 1}.b } c ${`nested ${d}`} e`"
        let found = pieces(text, .js)
        XCTAssertEqual(found.first?.0, "`a ${")
        XCTAssertTrue(found.contains { $0.0 == "b" && $0.1 == .property })
        XCTAssertTrue(found.contains { $0.0 == "1" && $0.1 == .number })
        XCTAssertTrue(found.contains { $0.0 == "`nested ${" && $0.1 == .string })
        XCTAssertEqual(found.last?.0, "} e`")
    }

    func testKeywordsAfterADotAreProperties() {
        XCTAssertEqual(kind(of: "default", in: "e.default.delete()", .js), .property)
        XCTAssertEqual(kind(of: "delete", in: "e.default.delete()", .js), .property)
    }

    func testTypeScriptAndJSX() {
        let ts = SourceLanguage.javascript(typescript: true, jsx: false)
        XCTAssertEqual(kind(of: "interface", in: "interface Foo { a: string }", ts), .keyword)
        XCTAssertEqual(kind(of: "Foo", in: "interface Foo { a: string }", ts), .type)
        XCTAssertEqual(kind(of: "string", in: "interface Foo { a: string }", ts), .type)
        XCTAssertNil(kind(of: "interface", in: "var interface = 1", .js))

        let jsx = SourceLanguage.javascript(typescript: false, jsx: true)
        let text = #"const el = <div className="x" onClick={() => go(1)}>Don't {name}</div>;"#
        XCTAssertEqual(kind(of: "<div", in: text, jsx), .tag)
        XCTAssertEqual(kind(of: "className", in: text, jsx), .attribute)
        XCTAssertEqual(kind(of: "\"x\"", in: text, jsx), .attributeValue)
        XCTAssertEqual(kind(of: "</div>", in: text, jsx), .tag)
        XCTAssertEqual(kind(of: "1", in: text, jsx), .number)
        // The apostrophe in the text doesn't start a string.
        XCTAssertFalse(pieces(text, jsx).contains { $0.1 == .string && $0.0.hasPrefix("'") })
    }

    // MARK: CSS, HTML, JSON tokens

    func testCSSTokenKinds() {
        let text = "@media (max-width:600px){.a:hover>#b,div[data-x=\"1\"]{color:#fff!important;margin:0 auto;background:url(a.png)}} /* c */"
        XCTAssertEqual(kind(of: "@media", in: text, .css), .keyword)
        XCTAssertEqual(kind(of: "max-width", in: text, .css), .property)
        XCTAssertEqual(kind(of: "600px", in: text, .css), .number)
        XCTAssertEqual(kind(of: ".a", in: text, .css), .type)
        XCTAssertEqual(kind(of: ":hover", in: text, .css), .variableSpecial)
        XCTAssertEqual(kind(of: "#b", in: text, .css), .definition)
        XCTAssertEqual(kind(of: "div", in: text, .css), .tag)
        XCTAssertEqual(kind(of: "data-x", in: text, .css), .attribute)
        XCTAssertEqual(kind(of: "color", in: text, .css), .property)
        XCTAssertEqual(kind(of: "#fff", in: text, .css), .atom)
        XCTAssertEqual(kind(of: "!important", in: text, .css), .keyword)
        XCTAssertEqual(kind(of: "auto", in: text, .css), .atom)
        XCTAssertEqual(kind(of: "a.png", in: text, .css), .string)
        XCTAssertEqual(kind(of: "/* c */", in: text, .css), .comment)
    }

    func testHTMLTokenKinds() {
        let text = "<!DOCTYPE html><!-- hi --><p class=\"x\" hidden>t</p><script>var a = 'b'</script><style>p{color:red}</style>"
        XCTAssertEqual(kind(of: "<!DOCTYPE html>", in: text, .html), .meta)
        XCTAssertEqual(kind(of: "<!-- hi -->", in: text, .html), .comment)
        XCTAssertEqual(kind(of: "<p", in: text, .html), .tag)
        XCTAssertEqual(kind(of: "class", in: text, .html), .attribute)
        XCTAssertEqual(kind(of: "\"x\"", in: text, .html), .attributeValue)
        XCTAssertEqual(kind(of: "hidden", in: text, .html), .attribute)
        XCTAssertEqual(kind(of: "</p", in: text, .html), .tag)
        XCTAssertEqual(kind(of: "var", in: text, .html), .keyword)
        XCTAssertEqual(kind(of: "'b'", in: text, .html), .string)
        XCTAssertEqual(kind(of: "color", in: text, .html), .property)
    }

    func testJSONTokenKinds() {
        let text = #"{"name":"perch","n":-1.5e3,"ok":true,"none":null,"list":[1,"two"]}"#
        XCTAssertEqual(kind(of: "\"name\"", in: text, .json), .property)
        XCTAssertEqual(kind(of: "\"perch\"", in: text, .json), .string)
        XCTAssertEqual(kind(of: "1.5e3", in: text, .json), .number)
        XCTAssertEqual(kind(of: "true", in: text, .json), .atom)
        XCTAssertEqual(kind(of: "null", in: text, .json), .atom)
        XCTAssertEqual(kind(of: "\"two\"", in: text, .json), .string)
    }

    func testLanguageDetection() {
        XCTAssertEqual(SourceLanguage.detect(url: "https://a.com/app.min.js?v=2", type: "Script", text: ""), .js)
        XCTAssertEqual(SourceLanguage.detect(url: "https://a.com/x.tsx", type: "Script", text: ""), .javascript(typescript: true, jsx: true))
        XCTAssertEqual(SourceLanguage.detect(url: "https://a.com/style", type: "Stylesheet", text: ""), .css)
        XCTAssertEqual(SourceLanguage.detect(url: "https://a.com/", type: "Document", text: "<html>"), .html)
        XCTAssertEqual(SourceLanguage.detect(url: "https://a.com/api", type: "Fetch", text: "  {\"a\":1}"), .json)
        XCTAssertEqual(SourceLanguage.detect(url: "https://a.com/api", type: "XHR", text: "hello"), .plain)
    }

    func testMinifiedHeuristic() {
        XCTAssertTrue(SourceLexing.looksMinified(String(repeating: "a=1;", count: 400)))
        XCTAssertFalse(SourceLexing.looksMinified(String(repeating: "let a = 1;\n", count: 400)))
        XCTAssertFalse(SourceLexing.looksMinified("short"))
    }

    func testLineStartsMatchTextViewLineBreaks() {
        XCTAssertEqual(SourceLexing.lineStarts("a\nb\r\nc\rd\u{2028}e"), [0, 2, 5, 7, 9])
    }

    // MARK: Formatting JavaScript

    func testFormatsMinifiedJavaScript() {
        let input = #"function f(a,b){if(a>b){return a-b}else{return-1}}var x={a:1,b:[1,2,3],c:function(){}};for(var i=0;i<3;i++)f(i,x);"#
        XCTAssertEqual(format(input, .js), """
        function f(a, b) {
            if (a > b) {
                return a - b
            } else {
                return -1
            }
        }
        var x = {
            a: 1,
            b: [1, 2, 3],
            c: function() {}
        };
        for (var i = 0; i < 3; i++) f(i, x);
        """)
    }

    func testFormatsSequencesTernariesAndSwitch() {
        let input = #"!function(){a(),b?c():d();switch(e){case 1:f();break;default:g()}}();"#
        XCTAssertEqual(format(input, .js), """
        !function() {
            a(),
            b ? c() : d();
            switch (e) {
                case 1:
                    f();
                    break;
                default:
                    g()
            }
        }();
        """)
    }

    func testFormatterKeepsLiteralsWhole() {
        let input = #"var s="a{b;c}",t='x,y',r=/[{;}]+\/,/g,u=`p{${q?1:2};}`;/* {;} */x=1//{;}"#
        let output = format(input, .js)
        XCTAssertTrue(output.contains(#""a{b;c}""#))
        XCTAssertTrue(output.contains("'x,y'"))
        XCTAssertTrue(output.contains(#"/[{;}]+\/,/g"#))
        XCTAssertTrue(output.contains("`p{${q ? 1 : 2};}`"))
        XCTAssertTrue(output.contains("/* {;} */"))
        XCTAssertTrue(output.contains("//{;}"))
        assertOnlyWhitespaceChanged(input, .js)
    }

    func testFormatterKeepsAuthorsLineBreaks() {
        let input = "let a = 1\nlet b = 2\n\n\n\nreturn\nc"
        XCTAssertEqual(format(input, .js), "let a = 1\nlet b = 2\n\nreturn\nc")
    }

    func testFormatterHandlesModernSyntax() {
        let input = #"const g=async(a,...b)=>{await a?.b??c;for(const[k,v]of Object.entries(o)){x**=2}};class A extends B{#p=1;static m(){return super.m()}}"#
        XCTAssertEqual(format(input, .js), """
        const g = async(a, ...b) => {
            await a?.b ?? c;
            for (const [k, v] of Object.entries(o)) {
                x **= 2
            }
        };
        class A extends B {
            #p = 1;
            static m() {
                return super.m()
            }
        }
        """)
    }

    func testFormattedLinesRememberWhereTheyCameFrom() {
        let input = "a();{b()}"
        let result = SourceFormatter.format(input, language: .js)
        XCTAssertEqual(result.text, "a();\n{\n    b()\n}")
        XCTAssertEqual(result.origins, [0, 4, 5, 8])
        XCTAssertEqual(result.text.components(separatedBy: "\n").count, result.origins.count)
    }

    func testFormattingLargeMinifiedBundleIsFastAndLossless() {
        let chunk = #"function n(e,t){var r=e.length,o=/[a-z]+\d*/gi;if(!r)return t?`${e}:${t}`:"none";for(var i=0;i<r;i++){switch(e[i]){case 1:t+=e[i]*2;break;default:t={k:"v",n:[1,2,{x:!0}]}}}return t}"#
        var input = ""
        while input.utf16.count < 500_000 { input += chunk }
        let started = Date()
        let result = SourceFormatter.format(input, language: .js)
        let formatTime = Date().timeIntervalSince(started)
        let tokensStarted = Date()
        let tokens = SourceHighlighter.tokens(input, language: .js)
        let tokenTime = Date().timeIntervalSince(tokensStarted)
        print("500 KB minified: format \(Int(formatTime * 1000)) ms, \(result.origins.count) lines; tokenize \(Int(tokenTime * 1000)) ms, \(tokens.count) tokens")
        XCTAssertGreaterThan(result.origins.count, 10_000)
        XCTAssertEqual(result.text.components(separatedBy: "\n").count, result.origins.count)
        XCTAssertFalse(tokens.isEmpty)
        let squeeze = { (s: String) in s.utf16.filter { $0 != 32 && $0 != 10 } }
        XCTAssertEqual(squeeze(result.text), squeeze(input))
    }

    // MARK: Formatting CSS, JSON, HTML

    func testFormatsMinifiedCSS() {
        let input = #"a,b>c{color:red;background:url("x;y.png") no-repeat}@media (max-width:600px){.d:hover{margin:0 auto}}"#
        XCTAssertEqual(format(input, .css), """
        a, b>c {
            color: red;
            background: url("x;y.png") no-repeat
        }
        @media (max-width:600px) {
            .d:hover {
                margin: 0 auto
            }
        }
        """)
    }

    func testCSSSelectorSpacingIsKept() {
        XCTAssertEqual(format("a :hover{x:1}", .css), "a :hover {\n    x: 1\n}")
    }

    func testFormatsJSON() {
        let input = #"{"a":1,"b":[true,null,{"c":"d,e"}],"f":{},"g":[]}"#
        XCTAssertEqual(format(input, .json), """
        {
            "a": 1,
            "b": [
                true,
                null,
                {
                    "c": "d,e"
                }
            ],
            "f": {},
            "g": []
        }
        """)
    }

    func testFormatsHTMLWithEmbeddedScriptAndStyle() {
        let input = #"<!DOCTYPE html><html><head><style>p{color:red}</style><script>if(a){b()}</script></head><body><p>Hi  there<br>you</p><pre>  keep"# + "\n" + #"  me</pre></body></html>"#
        XCTAssertEqual(format(input, .html), """
        <!DOCTYPE html>
        <html>
            <head>
                <style>
                    p {
                        color: red
                    }
                </style>
                <script>
                    if (a) {
                        b()
                    }
                </script>
            </head>
            <body>
                <p>
                    Hi there
                    <br>
                    you
                </p>
                <pre>  keep
          me</pre>
            </body>
        </html>
        """)
    }
}
