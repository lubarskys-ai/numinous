import Foundation

/// A tiny zero-dependency assertion harness, standing in for XCTest/swift-testing
/// (neither of which ships with a Command-Line-Tools-only toolchain).
final class Harness {
    private(set) var passed = 0
    private(set) var failed = 0
    private var currentGroup = ""

    func group(_ name: String, _ body: () -> Void) {
        currentGroup = name
        print("\n▸ \(name)")
        body()
    }

    func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        if condition {
            passed += 1
            print("  ✓ \(message)")
        } else {
            failed += 1
            print("  ✗ \(message)  (line \(line))")
        }
    }

    func eq(_ a: Double, _ b: Double, _ message: String, tol: Double = 0.0001, line: UInt = #line) {
        check(abs(a - b) <= tol, "\(message)  [got \(a), expected \(b)]", line: line)
    }

    func eq<T: Equatable>(_ a: T, _ b: T, _ message: String, line: UInt = #line) {
        check(a == b, "\(message)  [got \(a), expected \(b)]", line: line)
    }

    func summarize() -> Int {
        print("\n" + String(repeating: "─", count: 40))
        let total = passed + failed
        if failed == 0 {
            print("✅ All \(total) checks passed")
        } else {
            print("❌ \(failed) of \(total) checks FAILED")
        }
        return failed == 0 ? 0 : 1
    }
}
