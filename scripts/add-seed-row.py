#!/usr/bin/env python3
"""Add the `seed` and `seed-family` rows to a distro's ssh workflow."""
import pathlib
import re
import sys

FAMILY = {
    "mint": "apt", "popos": "apt", "kubuntu": "apt", "zorin": "apt", "mx": "apt",
    "ubuntu": "apt",
    "cachyos": "pacman", "manjaro": "pacman", "endeavour": "pacman",
}

for distro in sys.argv[1:]:
    p = pathlib.Path(".github/workflows/%s-ssh.yml" % distro)
    if not p.exists():
        print("%-10s no workflow" % distro)
        continue
    s = p.read_text()
    if '"seed"' in s:
        print("%-10s already seeded" % distro)
        continue
    # insert after the `publish` line of the single stage row
    m = re.search(r'^(\s*)"publish":\s*"[^"]+",\s*$', s, re.M)
    if not m:
        print("%-10s no publish row found" % distro)
        continue
    indent = m.group(1)
    fam = FAMILY.get(distro, "apt")
    ins = '%s"seed": "true",\n%s"seed-family": "%s",\n' % (indent, indent, fam)
    s = s[:m.end()] + ins + s[m.end():]
    p.write_text(s)
    print("%-10s seeded (%s)" % (distro, fam))
