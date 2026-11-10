import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Services

@Suite struct AvatarStoreTests {
    /// A 2×2 PNG.
    static func png() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("jit-avatars-\(UUID().uuidString)")
    }

    /// Waits for the store to announce a change or for `condition` to hold (no fixed sleeps).
    @MainActor static func wait(_ store: AvatarStore, until condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func hashIsTheSha256OfTheTrimmedLowercasedEmail() {
        // Gravatar's documented example address.
        let expected = "84059b07d4be67b806386c0aad8070a23f18836bbaae342275dc0a83414c32ee"
        #expect(AvatarStore.hash(email: "MyEmailAddress@example.com ") == expected)
        #expect(
            AvatarStore.url(email: "myemailaddress@example.com")?.absoluteString
                == "https://gravatar.com/avatar/\(expected)?s=96&d=404")
    }

    @MainActor @Test func nothingIsFetchedWithoutAFetcherOrWhenSwitchedOff() async {
        let calls = Mutex(0)
        let store = AvatarStore(cacheDirectory: nil)
        #expect(store.image(for: "ada@example.com") == nil)
        store.fetcher = { _ in
            calls.withLock { $0 += 1 }
            return (nil, true)
        }
        store.isEnabled = { false }
        #expect(store.image(for: "ada@example.com") == nil)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(calls.withLock { $0 } == 0)
    }

    @MainActor @Test func aPictureIsFetchedOnceAndAnnounced() async throws {
        let data = try Self.png()
        let calls = Mutex(0)
        let store = AvatarStore(cacheDirectory: nil)
        store.fetcher = { _ in
            calls.withLock { $0 += 1 }
            return (data, true)
        }
        #expect(store.image(for: "Ada@Example.com") == nil)
        #expect(store.image(for: "ada@example.com") == nil)  // same author, still loading: no second request
        await Self.wait(store) { store.revision > 0 }
        #expect(store.revision == 1)
        #expect(store.image(for: "ada@example.com")?.width == 2)
        #expect(calls.withLock { $0 } == 1)
    }

    @MainActor @Test func authorsWithoutAPictureAreNotAskedAgain() async {
        let calls = Mutex(0)
        let store = AvatarStore(cacheDirectory: nil)
        store.fetcher = { _ in
            calls.withLock { $0 += 1 }
            return (nil, true)
        }
        _ = store.image(for: "nobody@example.com")
        await Self.wait(store) { calls.withLock { $0 } == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(store.image(for: "nobody@example.com") == nil)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(calls.withLock { $0 } == 1)
        #expect(store.revision == 0)
    }

    @MainActor @Test func aFailedLookupIsNotRetriedInTheSameRun() async {
        let calls = Mutex(0)
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AvatarStore(cacheDirectory: directory)
        store.fetcher = { _ in
            calls.withLock { $0 += 1 }
            return (nil, false)
        }
        _ = store.image(for: "offline@example.com")
        await Self.wait(store) { calls.withLock { $0 } == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        _ = store.image(for: "offline@example.com")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(calls.withLock { $0 } == 1)
        // A failure is not remembered on disk: the next launch may try again.
        let marker = directory.appendingPathComponent(AvatarStore.hash(email: "offline@example.com") + ".none")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor @Test func theDiskCacheAnswersTheNextRunWithoutTheNetwork() async throws {
        let data = try Self.png()
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AvatarStore(cacheDirectory: directory)
        first.fetcher = { url in
            url.absoluteString.contains(AvatarStore.hash(email: "ada@example.com")) ? (data, true) : (nil, true)
        }
        _ = first.image(for: "ada@example.com")
        _ = first.image(for: "nobody@example.com")
        await Self.wait(first) { first.revision > 0 }
        let marker = directory.appendingPathComponent(AvatarStore.hash(email: "nobody@example.com") + ".none")
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: marker.path) {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let calls = Mutex(0)
        let second = AvatarStore(cacheDirectory: directory)
        second.fetcher = { _ in
            calls.withLock { $0 += 1 }
            return (nil, false)
        }
        _ = second.image(for: "ada@example.com")
        _ = second.image(for: "nobody@example.com")
        await Self.wait(second) { second.revision > 0 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(second.image(for: "ada@example.com") != nil)
        #expect(calls.withLock { $0 } == 0)
    }

    @MainActor @Test func addressesThatAreNotEmailsAreIgnored() {
        let store = AvatarStore(cacheDirectory: nil)
        store.fetcher = { _ in (nil, true) }
        #expect(store.image(for: "") == nil)
        #expect(store.image(for: "no-at-sign") == nil)
    }
}
