# easyvm-linux

Walkthroughs, reference images and CI for **Linux** guests, driven by
[`easydev-org/easyvm`](https://github.com/easydev-org/easyvm).

## What lives here

| Directory | Distribution |
|---|---|
| `ubuntu/` | Ubuntu Desktop |
| `mint/` | Linux Mint |
| `fedora-workstation/` | Fedora Workstation |
| `kubuntu/` | Kubuntu |
| `manjaro/` | Manjaro |
| `mx/` | MX Linux |
| `nixos/` | NixOS |
| `popos/` | Pop!\_OS |
| `zorin/` | Zorin OS |
| `cachyos/` | CachyOS |
| `endeavour/` | EndeavourOS |
| `alpine-microvm/` | Alpine, as a microvm |

Each directory holds `steps/`: the `.walk` files for that distribution's stages
(`install`, `ssh`, `vm-configure`) plus the reference images those stages compare against.

## What lives elsewhere, on purpose

**The engine is not here.** `easyvm` itself - the daemon, the qemu argument builder, the walkthrough
interpreter, the OCR and image matching - lives in [`easydev-org/easyvm`](https://github.com/easydev-org/easyvm).
This repository has no Go code at all.

**The CI machinery is not here either.** Every workflow below calls
`easydev-org/easyvm/.github/workflows/stage.yml@main`, so the runner setup, the KVM probes, the
container image and the publish logic exist once and are upgraded once.

## The workflows

One file per distribution, each a serial chain of stages:

```
install  ->  ssh  ->  vm-configure
```

A stage can be run on its own with `from_tag`: it names a *published* disk and the chain starts at the
job that needs it. The earlier jobs are skipped, because a `needs` on a skipped job is satisfied.

```sh
gh workflow run ubuntu.yml -f disks_repository=easydev-org/easyvm-linux -f from_tag=linux-ubuntu-ssh
```

## Why a separate repository

A walkthrough's assets are its reference images, and a stage's failure is almost always about one of
them - a page moved, a font changed, a window resized. Those belong next to the `.walk` that uses them,
and nowhere near the interpreter that compares them.

The split also means a change to one distribution cannot break another's CI: every workflow here runs
only on paths under its own directory, and publishes to this repository's own ghcr package.
