using System;
using System.Runtime.InteropServices;
using Ryujinx.Memory;

namespace Ryujinx.Headless.SDL2
{
    internal static class DonorExports
    {
        [UnmanagedCallersOnly(EntryPoint = "offer_donated_memory")]
        public static void OfferDonatedMemory(nint baseAddress, ulong size)
        {
            if (OperatingSystem.IsIOS()) DonatedMemory.Offer(baseAddress, size);
        }

        [UnmanagedCallersOnly(EntryPoint = "withdraw_donated_memory")]
        public static void WithdrawDonatedMemory()
        {
            if (OperatingSystem.IsIOS()) DonatedMemory.Withdraw();
        }

        [UnmanagedCallersOnly(EntryPoint = "report_memory_pressure")]
        public static void ReportMemoryPressure(byte critical)
        {
            // Kept as a stable native entry point for the iOS host. GPU eviction is added separately.
        }

        [UnmanagedCallersOnly(EntryPoint = "offer_donated_gpu_memory")]
        public static byte OfferDonatedGpuMemory(nint address, ulong size) => 0;

        [UnmanagedCallersOnly(EntryPoint = "withdraw_donated_gpu_memory")]
        public static byte WithdrawDonatedGpuMemory() => 1;
    }
}
