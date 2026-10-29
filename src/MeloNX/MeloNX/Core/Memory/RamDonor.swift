import Foundation

/// Controls the iOS RAM-donor helper. The native implementation is intentionally
/// isolated here so the emulator can continue to run normally when the helper
/// extension is unavailable.
enum RamDonor {
    private static let mib: UInt64 = 1024 * 1024

    static var isEnabled: Bool {
        get { NativeSettingsManager.shared.setting(forKey: "donateGuestMemory", default: true).value }
        set { NativeSettingsManager.shared.setting(forKey: "donateGuestMemory", default: true).value = newValue }
    }

    private(set) static var region: UnsafeMutableRawPointer?
    private(set) static var regionSize: UInt64 = 0
    private(set) static var lastStatus = "Not attempted yet"

    private static var nativeError: String? {
        guard let raw = mlx_ram_donor_last_error() else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    private static func fail(_ reason: String) -> Bool {
        lastStatus = [reason, nativeError].compactMap { $0 }.joined(separator: ": ")
        print(lastStatus)
        return false
    }

    @discardableResult
    static func prepare(bytes: UInt64) -> Bool {
        guard bytes > 0 else { return fail("Asked for no memory") }
        guard isEnabled else { return fail("Memory donation is disabled") }
        guard mlx_ram_donor_is_available() != 0 else { return fail("The RAM helper is missing from this build") }
        guard region == nil else { return true }

        mlx_ram_donor_set_kill_after_mapping(1)
        var granted: UInt64 = 0
        let minimum = min(bytes, 256 * mib)

        guard let mapped = mlx_ram_donor_acquire_up_to(bytes, minimum, &granted), granted > 0 else {
            mlx_ram_donor_shutdown()
            return fail("Could not acquire donor memory")
        }

        region = mapped
        regionSize = granted
        offer_donated_memory(mapped, granted)
        lastStatus = "Guest RAM donation: \(granted / mib) MiB"
        print(lastStatus)
        return true
    }

    static func teardown() {
        guard let mapped = region else { return }
        withdraw_donated_memory()
        mlx_ram_donor_release(mapped)
        mlx_ram_donor_shutdown()
        region = nil
        regionSize = 0
        lastStatus = "Donor released"
    }
}
