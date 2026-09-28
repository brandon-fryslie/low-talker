import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The app has no way to fetch a model, read off the dependency graph and not off its
/// call sites: no product the app template links reaches `ModelInstall`, while the
/// CLI's does. A call site is a fact about today's code; the graph is what a future
/// call site would first have to change, and this is what would fail when it did.
/// [LAW:one-way-deps]
@Suite struct AppLinksNoInstallerTests {
    static let installer = "ModelInstall"

    /// Each target Package.swift declares, to the package targets its `dependencies`
    /// name. Read by balancing parentheses over the manifest with its comments removed,
    /// so a `.product(...)` inside the list cannot end a declaration early and hide the
    /// dependency after it, and a parenthesis in a comment cannot unbalance one.
    static func packageGraph() throws -> [String: Set<String>] {
        let manifest = try String(contentsOf: repository.appending(path: "Package.swift"), encoding: .utf8)
        let code = manifest.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { line[..<$0.lowerBound] } ?? line }
            .joined(separator: "\n")
        var declarations: [String] = []
        var search = code.startIndex
        while let opening = code.range(of: #"\.(target|executableTarget|testTarget)\("#, options: .regularExpression, range: search..<code.endIndex) {
            var depth = 0
            var end = opening.lowerBound
            scan: for index in code[opening.lowerBound...].indices {
                switch code[index] {
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 {
                        end = code.index(after: index)
                        break scan
                    }
                default: break
                }
            }
            try #require(end > opening.lowerBound, "unbalanced parentheses after \(code[opening])")
            declarations.append(String(code[opening.lowerBound..<end]))
            search = end
        }
        let quoted = declarations.map { $0.matches(of: /"([^"]*)"/).map { String($0.1) } }
        let names = Set(quoted.compactMap(\.first))
        try #require(names.contains("LowTalkerCore"), "read no targets out of Package.swift: \(names)")
        return Dictionary(uniqueKeysWithValues: quoted.map { ($0[0], Set($0.dropFirst()).intersection(names)) })
    }

    /// The products the app template links, as xcodegen reads them: every `product:`
    /// under `Installation:` in `targetTemplates:`, up to the next template.
    static func appProducts() throws -> [String] {
        let lines = try String(contentsOf: repository.appending(path: "project.yml"), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        let templates = try #require(lines.firstIndex(of: "targetTemplates:"))
        let installation = try #require(lines[templates...].firstIndex(of: "  Installation:"))
        let block = lines[(installation + 1)...].prefix { $0.isEmpty || $0.hasPrefix("    ") }
        let products = block.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("product: ") ? String(trimmed.dropFirst("product: ".count)) : nil
        }
        try #require(products.contains("LowTalkerCore"), "read no products off the app template: \(products)")
        return products
    }

    /// Every target reached from `roots`, themselves included.
    static func reach(_ roots: [String], in graph: [String: Set<String>]) -> Set<String> {
        var reached = Set<String>()
        var pending = roots
        while let next = pending.popLast() {
            if reached.insert(next).inserted { pending.append(contentsOf: graph[next] ?? []) }
        }
        return reached
    }

    @Test func theAppReachesNoInstaller() throws {
        let graph = try Self.packageGraph()
        let products = try Self.appProducts()
        try #require(graph[Self.installer] != nil, "Package.swift declares no \(Self.installer) target")
        // A product name is its target's name here; one that is not would make this read
        // pass over nothing, so it is refused rather than skipped. [LAW:no-silent-failure]
        for product in products {
            try #require(graph[product] != nil, "\(product) is a product the app links but not a target Package.swift declares")
        }
        let reached = Self.reach(products, in: graph)
        #expect(!reached.contains(Self.installer), "the app reaches \(Self.installer) through \(reached.sorted())")
    }

    /// The same read finds the installer beneath the CLI, so the read above is not blind.
    @Test func theCLIReachesIt() throws {
        #expect(Self.reach(["lowtalker"], in: try Self.packageGraph()).contains(Self.installer))
    }
}
