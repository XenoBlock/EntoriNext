# EntoriNext — Komodo Hybrid Kernel

**630.0.0 · x86-64 · Limine (UEFI + Legacy) · BusyBox**

Komodo is a **Linux-compatible hybrid kernel** for x86-64, written in C from scratch and part of the EntoriNext superproject. It boots a BusyBox initramfs via Limine, brings up SMP + 4-level paging, and exposes the Linux 6.12 syscall ABI (0–462).

---

## One-line pitch

A from-scratch hybrid kernel that boots Linux userspace (BusyBox) on real hardware — fast core stays monolithic, drivers/filesystems can move to userspace services.

---

## Versioning — `Komodo/versioning.md`

```
(total-commit).(changes).(updates)  —  current: 630.0.0
```

| Field | Meaning | Source |
|-------|---------|--------|
| `total` | Total Komodo commits | `git rev-list --count HEAD` |
| `changes` | Feature bumps since last update | Manual |
| `updates` | Hotfixes / docs / packaging | Manual, resets `changes` |

`KERNEL_VERSION` in `include/kernel/komodo.h` tracks this. `uname -r` reports `KERNEL_VERSION` (630.0.0). Boot banner: `Komodo version 630.0.0`.

---

## Architecture — hybrid

```
Limine
  ↓
Early init (FPU, frame, paging, heap) → Platform (ACPI → SMP → PCI → drivers)
VFS (tmpfs/procfs/sysfs + ext/FAT/NTFS/ISO9660) + Kernel services (sched, IPC, syscalls, signals)
  ↓
sched_start() → /sbin/init (PID 1, BusyBox)
```

**Monolithic core:** scheduler (EEVDF), VM (frame/buddy/HHDM/page cache/swap), VFS, IPC, syscall dispatch — in kernel for speed.

**Optional userspace services:** drivers & filesystem backends can run as services behind callback interfaces. Kernel ↔ service messaging uses async request/response queues (enabler for hybrid, from `AUDIT_KOMODO.md`).

Ready: PCI/serial/SMP, e1000, IDE/AHCI, simpledrm/KMS, IPv4/6+TCP, pipes/epoll/eventfd/etc, PTYs, cgroups, ptrace, seccomp.

---

## Quick start

```bash
# Clone (submodules: Komodo, limine, busybox)
git clone --recursive https://github.com/XenoBlock/EntoriNext
cd EntoriNext

# Build kernel only
make -C Komodo              # → Komodo/KomImage

# Build ISO + initramfs and boot
make                         # → Komodo-x64.iso
make run                     # QEMU: -m 2G -serial stdio --enable-kvm

# Inside VM
uname -a                     # Komodo localhost 630.0.0 ...
cat /proc/sys/kernel/osrelease

# Debug logs: add sysdbg=1 to limine.conf cmdline
# cmdline: console=ttyS0 sysdbg=1
```

Requires: `gcc`, `make`, `qemu-system`, `xorriso`, `clang-format`, `clang-tidy`, `kconfig-frontends`, `libncurses-dev`, `dos2unix`. Config via `make -C Komodo menuconfig` (`.config` / `.config-default`).

---

## Repo layout

```
EntoriNext/                  ← superproject (this repo)
├── Komodo/                  ← kernel submodule (COXKPER/Komodo)
│   ├── versioning.md        ← version policy (with kernel)
│   ├── include/kernel/komodo.h  (KERNEL_VERSION)
│   ├── init/  kernel_entry() → swapper_run_init() (tries /sbin/init, /bin/sh…)
│   ├── mem/   frame/buddy/page/heap/slab/pagecache/swap/uaccess/hhdm
│   ├── kernel/{process,sched,signal,syscall,arch,cgroup}
│   ├── fs/    VFS + procfs/sysfs/tmpfs/…
│   ├── ipc/   pipes/futex/epoll/…
│   ├── net/   ipv4/ipv6/tcp/udp/…
│   ├── drivers/  PCI/USB/DRM/net/block/…
│   └── Makefile → KomImage
├── limine/                  ← bootloader submodule (upstream)
├── busybox/                 ← busybox submodule (upstream)
├── Userspace/rootfs/        ← initramfs staging
│   ├── bin/busybox (+ applet symlinks, generated)
│   ├── etc/{inittab,init.d/rcS,hosts,hostname,fstab,passwd,…}
│   └── dev/proc/sys/tmp     ← mount points
├── boot-komodo/limine.conf  ← ISO limine config
├── Makefile                 ← ISO + initramfs + QEMU
└── docs/AUDIT_KOMODO.md     ← audit & hybrid roadmap
```

---

## Userspace — initramfs facts

- **Init:** `Komodo/init/main.c:swapper_run_init` probes `/sbin/init` → `/bin/sh` → bootloader `init` module.
- **BusyBox init:** `/etc/inittab` (`::sysinit:/etc/init.d/rcS`, serial `ttyS0` auto-login `root` via `login -f root`, `tty1` via `getty`).
- **`rcS`:** mounts `proc`/`sysfs`/`devtmpfs`/`devpts`, runs `mdev -s`, prints `Welcome to Komodo 630.0.0 (hybrid)`.
- **No password:** `passwd: root:x:0:0:…` + no `shadow`. Serial (`console=ttyS0`) goes straight to `root@localhost:~#`.
- **Build:** `make` copies host `busybox` → `rootfs/bin/busybox`, installs 260+ applet symlinks, packs `initramfs.cpio` (newc).

Serial gate: `exec-dbg` (PATH probe) and `sys-dbg` (slow syscall) only when `sysdbg=1` on cmdline.

---

## Recent changes (Sep 2026)

| Commit | Area | What |
|--------|------|------|
| `663aaac8` | mem/mm/uaccess | Critical fixes: `uaccess` fault return, bitmap, hhdm NUL, slab ctor/dtor, pagecache races, frame/vma/mmap |
| `cace32ba` | syscall | `exec-dbg` gated behind `sysdbg=1` |
| `a7c57cd5` | versioning | Move `versioning.md` into Komodo, `uname -r` → `KERNEL_VERSION`, README `monolithic→hybrid` |
| `347c73f` | userspace | Proper `rootfs` (inittab/rcS/hosts/etc), fix build |
| `40b5f32` | userspace | Auto-login `root` on `ttyS0` |

---

## Roadmap (from `docs/AUDIT_KOMODO.md`)

1. Syscall + `uaccess` audit (done — Fase 1)
2. Async request/response infra for kernel↔userspace
3. First VFS service backend (hybrid proof-of-concept, with fallback)
4. Driver service backends (optional, incremental)

> Komodo is a development kernel — GPU/VirtIO/audio and parts of the ABI may still be stubs. See `Komodo/README.md` for the full feature list.
