#!/usr/bin/env python3
"""Turn a distro's ssh.walk into the seeded shape: boot, wait, prove, power off, publish.

WHY THIS IS A SCRIPT AND NOT NINE HAND EDITS
    Nine files carry the same seventeen-to-sixty step login-and-install sequence, and the seeded
    shape is the same in all of them: the disk already has an ssh server, so there is nothing to
    type. Doing it by hand invites the one thing this repository has been bitten by repeatedly -
    a lost character in a copy, which then reads as a different bug.

WHAT IS KEPT FROM EACH FILE
    - everything before the first `step` (walkthrough line, resolution, user, password, vars)
    - the `boot` step, byte for byte: its qemu arguments are per-distro and are not touched
    - the trailing steps from `wait for sshd` on, which are already the right shape

WHAT IS REPLACED
    every step between the boot and `wait for sshd`, which is the login, the terminal and the
    package install.
"""
import pathlib
import re
import sys

TAIL = '''step "wait for sshd"
  repeat
    until machine_ssh
    max 60
    pause 10


step "prove the kernel over ssh"
  ssh "uname -a"
  timeout 120


step "prove the account over ssh"
  ssh "id -un; hostname"
  timeout 120


step "ask the guest to power off"
  ssh "printf '%s\\\\n' '{{ password }}' | sudo -S -p '' poweroff"
  timeout 300


step "wait for the machine to stop"
  wait_until stopped
  timeout 300


step "publish the disk"
    save "{{ out }}"
'''

NOTE = '''# THERE IS NO LOGIN, NO TERMINAL AND NO install HERE, AND THAT IS THE POINT.
#
# This stage used to type its way through a greeter and a dozen commands in a terminal, and
# MEASURED over ten runs of its sibling zorin the virtual keyboard drops and doubles characters
# at line boundaries - one lost `'` leaves bash at a `>` prompt that swallows every later
# command, so `wait for sshd` ran against a machine whose install had never executed.
#
# The disk this leg pulls has had an ssh server put into it BEFORE its first boot, by
# `scripts/seed-ssh.sh` (see the `seed` row in the workflow), together with the offline half of
# vm-configure: hostname, time zone, locale, automatic login and the screen-lock settings.
#
# So the only work left is to boot it and to check that the promise holds: a session, a kernel,
# an account. Not one keystroke.


'''


def convert(path, write=True):
    src = pathlib.Path(path)
    s = src.read_text()
    lines = s.split("\n")

    # 1. the header: everything up to the first `step`
    first_step = next((i for i, l in enumerate(lines) if l.startswith("step ")), None)
    if first_step is None:
        raise SystemExit("%s: no steps" % path)
    header = "\n".join(lines[:first_step]).rstrip()

    # 2. the boot step: from `step "boot` up to the next `step `
    boot_start = next((i for i, l in enumerate(lines)
                       if l.startswith('step ') and '"boot' in l), None)
    if boot_start is None:
        raise SystemExit("%s: no boot step" % path)
    boot_end = next((i for i in range(boot_start + 1, len(lines)) if lines[i].startswith("step ")),
                    len(lines))
    boot = "\n".join(lines[boot_start:boot_end]).rstrip()

    if write:
        src.write_text(header + "\n\n\n" + NOTE + boot + "\n\n\n" + TAIL)
    return len(re.findall(r"^step ", s, re.M))


if __name__ == "__main__":
    for p in sys.argv[1:]:
        before = convert(p)
        after = len(re.findall(r"^step ", pathlib.Path(p).read_text(), re.M))
        print("%-40s %2d -> %2d steps" % (p, before, after))
