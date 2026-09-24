#!/usr/bin/env python3
"""
Patch kernel/module.c so vendor modules built against a sibling source revision
still load.

Why this is needed here:
  Motorola shipped this device from kernel-mtk branch android-12-release-s1rs32.38-20-7-16.
  The only published branch for this train is ...-20-9 (one patch level newer).
  The vendor .ko files in /vendor/lib/modules were built against the -20-7-16 tree with
  CONFIG_MODVERSIONS=y, so they carry symbol CRCs and a vermagic of
  "4.14.186+ SMP preempt mod_unload modversions aarch64".

  Building -20-9 with CONFIG_MODVERSIONS=y and the *unmodified* shipped config still
  produces a different __crc_module_layout, so the kernel rejects EVERY vendor module
  ("Failed to load WiFi driver") - no wifi, no touch, no fingerprint.

Fix (two parts):
  1. CONFIG_MODVERSIONS=n  -> check_version() is compiled out, so CRCs are not compared.
     struct module is NOT affected by CONFIG_MODVERSIONS (include/linux/module.h never
     references it), so this does not itself change the module ABI.
  2. make same_magic() ignore the optional "modversions" token, because that token is
     part of VERMAGIC_STRING: vendor modules say "... mod_unload modversions aarch64"
     while our kernel now says "... mod_unload aarch64". Without this the vermagic gate
     rejects them instead.
"""
import re
import sys

PATH = "kernel/module.c"

NEW_FUNC = r'''static inline int same_magic(const char *amagic, const char *bmagic,
			    bool has_crcs)
{
	if (has_crcs) {
		amagic += strcspn(amagic, " ");
		bmagic += strcspn(bmagic, " ");
	}

	if (strcmp(amagic, bmagic) == 0)
		return 1;

	/*
	 * Tolerate the optional "modversions" token being present on only one side.
	 * It is part of VERMAGIC_STRING, and vendor modules are prebuilt against a
	 * sibling source revision that had CONFIG_MODVERSIONS=y while this kernel
	 * does not. Comparing the remaining tokens in order keeps the check
	 * meaningful for everything else (SMP/preempt/mod_unload/arch).
	 */
	while (*amagic && *bmagic) {
		size_t an = strcspn(amagic, " ");
		size_t bn = strcspn(bmagic, " ");

		if (an == 11 && !strncmp(amagic, "modversions", 11)) {
			amagic += an;
			amagic += strspn(amagic, " ");
			continue;
		}
		if (bn == 11 && !strncmp(bmagic, "modversions", 11)) {
			bmagic += bn;
			bmagic += strspn(bmagic, " ");
			continue;
		}
		if (an != bn || strncmp(amagic, bmagic, an))
			return 0;
		amagic += an;
		amagic += strspn(amagic, " ");
		bmagic += bn;
		bmagic += strspn(bmagic, " ");
	}
	return *amagic == '\0' && *bmagic == '\0';
}'''

src = open(PATH, encoding="utf-8", errors="surrogateescape").read()

if "modversions\" token being present on only one side" in src:
    print("  already patched")
    sys.exit(0)

# locate the existing same_magic() definition
m = re.search(r'static inline int same_magic\(const char \*amagic, const char \*bmagic,\s*\n?\s*bool has_crcs\)\s*\n?\{', src)
if not m:
    print("  !! could not locate same_magic() - aborting")
    sys.exit(1)

start = m.start()
# walk to the matching closing brace
i = src.index('{', m.start())
depth = 0
end = None
while i < len(src):
    if src[i] == '{':
        depth += 1
    elif src[i] == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
    i += 1
if end is None:
    print("  !! could not find end of same_magic() - aborting")
    sys.exit(1)

old = src[start:end]
print("  --- original same_magic() ---")
for line in old.splitlines():
    print("    " + line)

src = src[:start] + NEW_FUNC + src[end:]
open(PATH, "w", encoding="utf-8", errors="surrogateescape").write(src)
print("  --- patched ok ---")
