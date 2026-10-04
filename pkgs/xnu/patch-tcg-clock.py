#!/usr/bin/env python3
"""Use firmware-calibrated TSC timing when QEMU TCG has no ratio MSRs."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
s = path.read_text()
old = '''\t\tif (cpuid_vmm_info()->cpuid_vmm_tsc_frequency &&
\t\t    cpuid_vmm_info()->cpuid_vmm_bus_frequency) {
\t\t\tbusFreq = (uint64_t)cpuid_vmm_info()->cpuid_vmm_bus_frequency * kilo;'''
new = '''\t\tuint64_t vmm_tsc = (uint64_t)cpuid_vmm_info()->cpuid_vmm_tsc_frequency * kilo;
\t\tuint64_t vmm_bus = (uint64_t)cpuid_vmm_info()->cpuid_vmm_bus_frequency * kilo;
\t\t/* MiniDarwin: TCG has no physical Intel ratio MSRs. Its TSC and
\t\t * local APIC use the nanosecond virtual clock. The EFI loader
\t\t * calibrates TSCFrequency before leaving firmware services. */
\t\tif ((!vmm_tsc || !vmm_bus) &&
\t\t    strcmp(cpuid_vmm_info()->cpuid_vmm_vendor, "TCGTCGTCGTCG") == 0) {
\t\t\tvmm_tsc = EFI_get_frequency("TSCFrequency");
\t\t\tvmm_bus = vmm_tsc;
\t\t\tif (!vmm_tsc || vmm_tsc > 100ULL * Giga) {
\t\t\t\tpanic("Invalid firmware TSCFrequency for QEMU TCG");
\t\t\t}
\t\t}
\t\tif (vmm_tsc && vmm_bus) {
\t\t\tbusFreq = vmm_bus;'''
assert s.count(old) == 1
s = s.replace(old, new)
s = s.replace('tscFreq = (uint64_t)cpuid_vmm_info()->cpuid_vmm_tsc_frequency * kilo;', 'tscFreq = vmm_tsc;')
path.write_text(s)
