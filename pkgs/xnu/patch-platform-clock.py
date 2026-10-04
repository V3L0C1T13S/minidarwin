#!/usr/bin/env python3
"""Publish the IORTC and IONVRAM resources that IOKitInitializeTime() waits on.

bsd_init -> IOKitInitializeTime() waits up to 30 s for resourceMatching("IORTC")
and then up to 30 s for resourceMatching("IONVRAM") before it initialises the
calendar. PDACPIPlatformExpert already reads and writes the CMOS clock
(getGMTTimeOfDay/setGMTTimeOfDay) but never said so, so both waits timed out
and boot stalled for 60 s.
"""
from pathlib import Path
import sys

cpp = Path(sys.argv[1]) / 'PDACPIPlatformExpert.cpp'
hdr = Path(sys.argv[1]) / 'PDACPIPlatformExpert.h'

s = cpp.read_text()
call_old = '\tpublishPlatformUUIDFromDeviceTree();\n'
assert s.count(call_old) == 1
s = s.replace(call_old, call_old + '\tpublishClockResources();\n')

marker = '#pragma mark - SMP\n'
assert s.count(marker) == 1
func = r'''/*
 * Publish IORTC and IONVRAM.
 *
 * IOKitInitializeTime() blocks on both resources (30 s each) before it reads
 * the wall clock. On a Mac they come from AppleRTC and IODTNVRAM; here the
 * clock is the PC CMOS RTC this class already drives, so IORTC is ours to
 * publish -- but only if the RTC is really there: register 0x0D bit 7 (VRT)
 * is set while the clock has power, and an absent device floats high on some
 * buses, so also require a plausible month.
 *
 * MiniDarwin has no variable store. IONVRAM is published so the calendar
 * initialisation does not wait for a controller that will never register;
 * nothing here implements IONVRAMController, so NVRAM variables stay
 * unavailable. IOPlatformUUID is already handled by
 * publishPlatformUUIDFromDeviceTree().
 */
void PDACPIPlatformExpert::publishClockResources(void) {
	uint8_t vrt = rtcRead(0x0D);
	uint8_t month = rtcRead(RTC_MONTH);
	uint8_t statusB = rtcRead(RTC_STATUS_B);
	if (!(statusB & RTC_STATUS_B_BINARY)) month = BCD_TO_BIN(month);

	if ((vrt & 0x80) && month >= 1 && month <= 12) {
		publishResource("IORTC", this);
	} else {
		IOLog("PDACPIPlatformExpert: no valid CMOS RTC, IORTC unavailable\n");
	}
	publishResource("IONVRAM", this);
}

'''
s = s.replace(marker, func + marker)
cpp.write_text(s)

h = hdr.read_text()
old = '\tvoid publishPlatformUUIDFromDeviceTree(void);\n'
assert h.count(old) == 1
hdr.write_text(h.replace(old, old + '\tvoid publishClockResources(void);\n'))
