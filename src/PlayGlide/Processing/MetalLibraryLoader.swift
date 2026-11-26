import Foundation
import Metal
import Synchronization

/// Loads a precompiled `default.metallib` when bundled and enabled (`PLAYGLIDE_PRECOMPILED_METALLIB=0` forces
/// runtime MSL source compilation for A/B comparison), validating that every required shader entry point is present
/// before falling back cleanly to embedded MSL source.
enum MetalLibraryLoader {
    static var precompiledMetallibEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_PRECOMPILED_METALLIB"] != "0"
    }

    private final class LibraryBox: @unchecked Sendable {
        let library: any MTLLibrary
        init(_ library: any MTLLibrary) { self.library = library }
    }

    private static let cachedDefaultLibraries = Mutex<[UInt64: LibraryBox]>([:])

    static func loadLibrary(
        device: any MTLDevice,
        requiredFunctions: [String],
        fallbackSource: String,
        usePrecompiled: Bool = precompiledMetallibEnabled,
        bundle: Bundle = .main,
        metallibURL: URL? = nil
    ) throws -> (library: any MTLLibrary, precompiled: Bool) {
        if usePrecompiled,
            let library = resolvePrecompiledLibrary(device: device, bundle: bundle, metallibURL: metallibURL),
            hasRequiredFunctions(library, names: requiredFunctions)
        {
            return (library, true)
        }
        return (try device.makeLibrary(source: fallbackSource, options: nil), false)
    }

    private static func resolvePrecompiledLibrary(
        device: any MTLDevice, bundle: Bundle, metallibURL: URL?
    ) -> (any MTLLibrary)? {
        if let metallibURL {
            return try? device.makeLibrary(URL: metallibURL)
        }
        if bundle === Bundle.main,
            let cached = cachedDefaultLibraries.withLock({ $0[device.registryID] })
        {
            return cached.library
        }
        let candidate: (any MTLLibrary)?
        if let url = bundle.url(forResource: "default", withExtension: "metallib"),
            let loaded = try? device.makeLibrary(URL: url)
        {
            candidate = loaded
        } else if let loaded = try? device.makeDefaultLibrary(bundle: bundle) {
            candidate = loaded
        } else {
            candidate = nil
        }
        if let candidate, bundle === Bundle.main {
            let box = LibraryBox(candidate)
            cachedDefaultLibraries.withLock { $0[device.registryID] = box }
        }
        return candidate
    }

    private static func hasRequiredFunctions(_ library: any MTLLibrary, names: [String]) -> Bool {
        let available = Set(library.functionNames)
        return names.allSatisfy { available.contains($0) }
    }
}
