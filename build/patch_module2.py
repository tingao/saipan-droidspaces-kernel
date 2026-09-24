#!/usr/bin/env python3
"""
Make the symbol-CRC gate tolerant instead of fatal.

Vendor .ko files on this device were built by Motorola from kernel-mtk branch
android-12-release-s1rs32.38-20-7-16 with CONFIG_MODVERSIONS=y. The only published
branch for this train is ...-20-9, so building it (even with the *unmodified* shipped
config) yields different symbol CRCs. check_version() then rejects every module:
  logcat -> android.hardware.wifi@1.0-service-lazy: Failed to load WiFi driver
  /proc/modules -> empty  -> no wifi, no touch, no fingerprint.

CONFIG_MODVERSIONS cannot simply be turned off (default y, re-selected), so instead we keep
it - vermagic therefore stays byte-identical to stock - and turn the single mismatch path
in check_version() from a hard rejection into a one-shot warning.

check_version() outcomes:
   crc matches                   -> return 1
   symbol absent from __versions -> pr_warn_once + return 1   (already tolerant)
   crc differs                   -> pr_warn + return 0        <-- the fatal one, patched
"""
import re
import sys

PATH = "kernel/module.c"
src = open(PATH, encoding="utf-8", errors="surrogateescape").read()

if "KSU_TOLERANT_CRC" in src:
    print("  already patched")
    sys.exit(0)

pat = re.compile(
    r'bad_version:\s*\n'
    r'\s*pr_warn\("%s: disagrees about version of symbol %s\\n",\s*\n'
    r'\s*(?P<name>mod|info)->name, symname\);\s*\n'
    r'\s*return 0;'
)
m = pat.search(src)
if not m:
    print("  !! bad_version block not found")
    cm = re.search(r'static int check_version\(.*?\n\}', src, re.S)
    if cm:
        print("  --- current check_version() ---")
        for line in cm.group(0).splitlines():
            print("    " + line)
    sys.exit(1)

print("  --- original bad_version block ---")
for line in m.group(0).splitlines():
    print("    " + line)

replacement = '''bad_version:
	/*
	 * KSU_TOLERANT_CRC: tolerate a CRC mismatch instead of refusing to load.
	 *
	 * The modules in /vendor/lib/modules were built together with Motorola's -20-7-16
	 * kernel, but only the -20-9 source branch is published for this train, so CRCs
	 * legitimately differ for symbols whose headers moved between the two. Refusing to
	 * load disables wifi, touch, fingerprint and GPS outright - far worse than loading a
	 * module that may use a slightly older but compatible symbol. Warn once per symbol.
	 */
	pr_warn_once("%s: symbol %s CRC differs (module expects 0x%lX) - loading anyway\\n",
		     info->name, symname, versions[i].crc);
	return 1;'''

src = src[:m.start()] + replacement + src[m.end():]
open(PATH, "w", encoding="utf-8", errors="surrogateescape").write(src)
print("  --- patched ok ---")
