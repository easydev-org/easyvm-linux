#!/usr/bin/env python3
"""linux-ubuntu — the ssh stage, as a Python walkthrough.

WHAT THIS REPLACES, AND WHY IT IS SHORTER

    `sd-linux/ubuntu/steps/ssh.walk` was twenty steps of YAML. Seven of them were login, terminal
    and `apt-get install openssh-server` typed into a desktop, and every one of those was removed
    when the disk began arriving with sshd already in it (`scripts/seed-ssh.sh`). What is left is
    the same seven things this file does, and the only real difference is that the checks are
    `assert` statements a reader can follow.

THE ARGUMENTS ARE COPIED, NOT DERIVED

    `UBUNTU_ARGS` is the `args:` array from the walk, flattened from `[["-f","v"], ...]` to
    `["-f","v", ...]`. It is copied on purpose: Phase 1 has no argument derivation, so a list that
    was measured on this guest stays exactly the list that was measured. When `launch` grows a
    spec-to-args helper, this constant is what it has to reproduce.
"""

from __future__ import annotations

import os
import pathlib
import sys

from easyvm import SSH

# `file=disk.qcow2` IS REWRITTEN TO AN ABSOLUTE PATH, and the reason is measured: with
# `overlay=False` the daemon passes `args` through untouched, and qemu resolves a relative `file=`
# against the daemon's own working directory. A walk could rely on that; a Python script that also
# runs against a daemon in another container cannot.
def ubuntu_args(disk: str) -> list[str]:
    return [
        "-machine", "q35,accel=kvm,vmport=off",
        "-display", "none",
        "-serial", "file:console.log",
        "-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd",
        "-drive", "if=pflash,format=raw,file=OVMF_VARS.fd",
        "-m", "4096",
        "-chardev", "socket,id=qga0,path=qga.sock,server=on,wait=off",
        "-device", "virtio-serial",
        "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0",
        "-device", "VGA,xres=1920,yres=1080,vgamem_mb=32",
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-tablet,bus=xhci.0",
        "-device", "usb-kbd,bus=xhci.0",
        # THE DISK IS THE ONE LINE THAT NAMES ITSELF, so `launch(disk=...)` and the vector cannot
        # disagree about which file is being started.
        "-drive", "file=%s,if=none,format=qcow2,discard=unmap,id=target" % disk,
        "-device", "virtio-blk-pci,drive=target,bootindex=0",
        "-audiodev", "none,id=snd0",
        "-device", "ich9-intel-hda",
        "-device", "hda-duplex,audiodev=snd0",
        "-netdev", "tap,id=net0,ifname=qemutap0,script=no,downscript=no",
        "-device", "virtio-net-pci,netdev=net0,mac=52:54:00:56:4d:01,romfile=,host_mtu=1450",
    ]


def run(vm, work: pathlib.Path) -> None:
    """The seven things the walk did, in the order it did them."""
    disk = work / "disk.qcow2"
    if not disk.exists():
        raise SystemExit("no disk at %s - the pull step must run first" % disk)

    # `out` IS A NAME, NOT A PATH, and it is joined to THIS side's work directory: `vm.compress`
    # runs qemu-img in the job's container, where the shared directory has the job's own name.
    # Everything SENT to the daemon goes through `vm.remote_path`, so the same file is named `/work`
    # on that side - see the two names in `stage-python.yml`.
    out = work / os.environ.get("out", "linux-ubuntu-ssh.qcow2")
    video = work / "ssh.mp4"

    # THE RECORDING IS THE DAEMON'S, AND IT STARTS BEFORE THE MACHINE DOES so the boot is in it.
    # A seed that failed somewhere before launch is exactly the case a video is wanted for.
    # THE CREDENTIALS ARE THE STAGE'S, SENT ON EVERY CALL. The daemon has no account of its own;
    # the `ssh=` on `launch` is only so the readiness probe can answer `state()["ssh_ready"]`.
    creds = SSH(user=os.environ.get("user", "vmuser"),
                password=os.environ.get("password", "admin1"))
    # THE DAEMON'S SPELLING IS NOT THIS SIDE'S. `ubuntu_args` builds `file=<the disk this process
    # sees>`; `launch` translates the whole vector, so the guest is pointed at the daemon's `/work`.
    vm.launch(disk=str(disk), args=ubuntu_args(str(disk)), overlay=False, timeout_sec=900, ssh=creds)
    vm.start_recording(str(video))

    try:
        # TWENTY-FIVE MINUTES, AND THE NUMBER IS MEASURED. A freshly seeded Ubuntu with GNOME,
        # snapd and packagekit was seen answering on 22 only after the ten minutes the old walk
        # allowed, while the host diagnosis at the moment it gave up showed the port OPEN.
        vm.wait_ssh(timeout=1500)

        kernel = vm.ssh("uname -a", ssh=creds)
        assert kernel.ok, "uname failed: %s" % kernel.output
        assert "Linux" in kernel.output, "not a Linux guest: %r" % kernel.output

        who = vm.ssh("id -un", ssh=creds)
        assert who.ok and who.output.strip() == "vmuser", \
            "the session is not vmuser: %r" % who.output

        boot = vm.ssh("hostname", ssh=creds)
        print("guest: %s / %s" % (boot.output.strip(), kernel.output.split()[2]))

        # POWER OFF OVER SSH, AND WAIT FOR THE MACHINE TO BE GONE. A stage that stops at
        # `poweroff` and returns leaves qemu holding /dev/kvm for the next leg.
        # THE `%s` INSIDE `printf '%s\n'` IS LITERAL. `%`-formatting this line needs the first one
        # escaped, which reads as a typo; concatenation is unambiguous.
        vm.ssh("printf '%s\\n' '" + creds.password + "' | sudo -S -p '' poweroff",
               ssh=creds, timeout=300)
        vm.wait_stopped(timeout=300)
    finally:
        rec = vm.stop_recording()
        print("recording: %s (%d frames, %.0fs)" % (rec.path, rec.frames, rec.seconds))

    # THE DISK IS COMPRESSED HERE, NOT IN THE DAEMON. It is the pipeline's artefact now.
    print("compressing %s -> %s" % (disk, out))
    vm.compress(str(disk), str(out))
    print("published disk: %s (%.1f MiB)" % (out, out.stat().st_size / 2**20))
