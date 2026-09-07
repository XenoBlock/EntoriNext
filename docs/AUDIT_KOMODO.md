# Audit Komodo Kernel — Fondasi Uinxed + Desain Hybrid

> Deliverable audit sesudah eksplorasi. Ini laporan singkat, bukan dokumen panjang.
> Basis: `/home/neoncorp/Documents/Projects/EntoriNext/Uinxed-Kernel` (+ perbandingan konsep dari `Komodo/` = microkernel Lux).
> Tanggal audit sesudah penjelajahan codebase langsung (bukan dari agent yang gagal).

## 1. Verifikasi baseline yang JALAN (sudah di-build)

- `make` **berhasil** → `UxImage` (9.6 MB static-pie ELF) + `Uinxed-x64.iso`. Build dari bersih, 237 file C, ~155k LOC.
- Toolchain host lengkap kecuali `clang-format`, `clang-tidy`, `dos2unix`, `kconfig-mconf` (opsional; `make check`/`format`/`menuconfig` belum jalan).

## 2. Struktur kernel saat ini (Uinxed)

```
kernel/    arch, cgroup, cmdline, debug, interrupt, module, process, sched, signal, syscall, timer
mem/       frame (buddy), heap, page, swap, hhdm, uaccess
fs/        core (VFS+dcache+icache+superblock+txn), tmpfs, procfs, sysfs*, devtmpfs, cpio, fatfs, extfs, ntfs, isofs, cgroupfs
net/       core, ipv4, ipv6, netlink, socket, dhcp
ipc/       epoll, futex, pipe, posix_mq, sysv_ipc
drivers/   base (device model), block (nvme/ahci/ata), net (e1000/rtl), gpu, tty, input(ps2/usb), sound, time, firmware(acpi/apic), char(tpm)
security/  seccomp
boot/      limine_module / limine_request
init/      main.c        (kernel_entry)
```

Boot order (`init/main.c kernel_entry`): `fpu → frame → page → heap → swap → lmodule → serial → vt → video → ACPI → TPM → TSC → SMP → PCI → PS2 → sched → process → signal → cgroup → syscall → VFS → tmpfs/procfs/sysfs/cgroupfs → FAT/ISO/NTFS/ext → IPC/pipe/epoll/eventfd/seccomp/timerfd/signalfd/inotify/memfd/socket/futex/netlink → sysfs kobject → device model → devtmpfs → storage/IDE/AHCI/NVMe → net/NIC → USB host → sound → cpio → sysfs population → GPU → init (PID 1) → kthreadd → drivers workers → sched_start`.

## 3. Syscall / ABI architecture

- **Nomor syscall: LINUX x86-64, tabel `syscall_table.h` — diverifikasi 36/36 cocok dengan Linux** (read=0, open=2, mmap=9, clone=56, fork=57, execve=59, exit=60, socket=41, openat=257, clone3=435, dsb).
- Entry: `SYSCALL`/`SYSRET` + `syscall_entry`× MSR (`syscall_init_cpu`), `syscall_frame_t` 6 arg dari `rdi/rsi/rdx/r10/r8/r9`, dispatch `syscall_table[num](frame->rdi,...)`.
- Return/errno: Linux semantics (nilai negatif = -errno), `syscall_dispatch()`.
- Cakupan ABI: ext4/NTFS, clone3 dengan tail-zero check (future-proofing), arch_prctl, getdents64, seccomp.
- **Unimplemented → `-ENOSYS`** (`syscall.c:5672` region).

## 4. Driver architecture

- **Device model all-Linux-style**: `bus_register`/`driver_register`/`device_model_init` (`drivers/base/device.c`).
- Kategori driver (mature vs placeholder):
  - **Storage**: NVMe, AHCI/SATA, IDE/PATA, USB-MSC (mature; gendisk registry).
  - **Net**: e1000/e1000e 8254x, RTL8139/8169 (mature, worker-thread based).
  - **GPU**: `gpu_drivers_init/probe`, VirtIO-GPU built-in, GOP framebuffer + fbcon/klogo.
  - **Audio**: SB16 + Intel HDA (ALSA ABI).
  - **Input**: PS/2, USB HID, evdev.
  - **Bus**: PCI/PCIe ECAM+legacy, USB host (UHCI/OHCI/EHCI/xHCI).
  - **Platform**: ACPI, TPM (TIS/CRB 1.2/2.0), HPET, RTC, serial 8250, parport.
- Sisi lemah: beberapa gated default off (VirtIO GPU, SB16); NTFS writer secara eksplisit tidak aman untuk data penting.

## 5. Boot / initrd architecture

- **Limine** (UEFI+Legacy), `/Uinxed-Kernel` entry, `kernel_path: boot():/EFI/Boot/UxImage`, `module_path: boot():/initramfs.cpio`, `kaslr: yes`.
- `boot/limine_module.c`: `module_request.response->modules[]` → registry `lmodule[128]` (`name` dari path, `data`, `size`).
- Initrd = **cpio** — `init_cpio()` (fs/cpio) mount awal sebelum VFS benar; `init` probed lewat `init=`, CONFIG_INIT_PATH, then `/sbin/init` etc., terakhir modul limine `init`.
- `elf_loader_load_initial_process` → PID 1; console disetup (fd0/1/2) sebelum init jalan.
- Jelas & dapat diganti tanpa mengubah kernel core (interface lewat `lmodule`+`elf_loader`).

## 6. Memory management

- **Buddy frame allocator** (`mem/frame.c`), standard 4-level paging (4K/2MiB/1GiB), HHDM direct map.
- **Page cache unified** (locking, LRU reclaim, dirty writeback, readahead, truncation) untuk anon/file (`mem/page.c`, `mem/swap.c` — anon swap area, fault handling).
- `mmap`/`munmap`/`mremap` + VMA (`process.h vm_area_t`, `process_vm`).
- `heap` + slab allocator untuk kernel.
- **uaccess**: fault-fixup `copy_{from,to}_user`, per-task `uaccess_fault_resume/nofault` (survives preemption), `user_range_ok` + `user_translate`.

## 7. Scheduler

- **EEVDF**, per-CPU runqueues, RB-tree timeline (`vruntime`/`deadline`/`vlag`/`weight`).
- SMP placement, migration, load balancing, IPI preemption; sched domains (SMT→PACKAGE→SYSTEM).
- **Priority Inheritance** (PI) untuk futex/rt_mutex (`pi_weight`, `blocked_on`, `pi_owned`), timer queue timed-waits.
- Kernel threads + user tasks dengan VMA/fd/credentials; seccomp TSYNC per-thread.

## 8. IPC

- AF_UNIX/AF_NETLINK/AF_INET6; pipes, epoll, eventfd, timerfd, signalfd, memfd, pidfd, POSIX mq, System V IPC, futex+futex2, epoll_pwait etc.
- Robust (lost-wakeup-safe two-phase waitqueues, PI).

## 9. Userspace (target & status)

- Boot Alpine 3.23 + Xfce (X11) adalah **target yang diklaim**; audit tidak menemukan distro userland di repo ini — `Userspace/` **masih kosong**.
- Arah: static Linux ELF → Komodo → executes (lihat roadmap).

## 10. Layak pindah ke userspace (masa depan, HYBRID)

- **filesystem service** (via VFS callback `vfs_regist_fs` — interface sudah ada; bfs backend bisa server IPC)
- **networking** (socket layer sudah abstrak; NIC backend bisa keluar)
- **GPU / audio / storage / logging / security service**
- Catatan penting: device model (`driver`/`bus`) & VFS sudah menawarkan **callback interface** — berarti OPSI "backend userspace" bisa ditambahkan **tanpa merombak ABI Linux** (ini justru jalan untuk hybrid asli).

## 11. Sebaiknya TETAP di kernel

- **Scheduler + EEVDF + PI** (sangat sensitif perf; jangan luar).
- **Page cache + swap + framebuffer mmap** (fundamental, tidak bisa via IPC).
- **Syscall dispatch + uaccess** (trust boundary; jangan percaya userspace).
- **Signal, futex/futex2** (per-thread state, latency).
- Driver HW yang latency-critical: interrupts, TSC/ACPI, NVMe/AHCI (jangan pindah tanpa alasan).

## 12. Bagian Lux/Komodo yang LAYAK diambil

Prioritas tinggi (aman, tanpa merusak ABI):
1. **Request/response ID + async queue** untuk syscalls eksternal — pattern untuk "syscall menunggu jawaban server userspace" tanpa block kernel. Ini **enabler utama hybrid**.
2. **`syscallVerifyPointer` seluruh argumen** sebelum dispatch (pola Komodo `dispatch.c`) — meski Uinxed sudah punya uaccess, audit cakupan syscall apakah semua arg pointer sudah lewat `copy_from_user`/`user_range_ok`.
3. **Syscall queue terpisah dari runqueue** — memisahkan "thread diblok menunggu I/O" dari scheduler (bukan preemption), mengurangi kompleksitas sched.
4. Clean `errno` di satu tempat (Uinxed sudah ada, pastikan konsisten).
5. IPC kernel ↔ userspace yang **tetap memakai ABI Linux** (misal lewat socket/unix + ioctl khusus) — bukan custom ABI.

Prioritas menengah:
6. O_CLOFORK / close-on-fork hardening (`fork.c` Komodo) sebagai suplemen `O_CLOEXEC`.
7. Logging awal yang jelas (Komodo `logger.h`) untuk debug boot.

## 13. Bagian yang JANGAN diambil

- ❌ **Custom ABI Lux/Komodo** (67 syscall — TABEL SENDIRI). Ini justru yang bikin Linux biner gagal jalan. **Tidak pernah**.
- ❌ Server routing berbasis custom kernel socket (`servers/handle.c`) — ganti ABI; kalau perlu IPC kernel↔user, pakai AF_UNIX/AF_NETLINK/UIO yang sudah Linux ABI.
- ❌ Ramdisk **USTAR** Komodo — Uinxed sudah cpio via Limine; jangan balik.
- ❌ Async syscall penuh gaya microkernel (semua syscall done melalui lumen) — memakai hybrid secukupnya, bukan memaksa semua keluar kernel.

## 14. Dependency & conflict map

- ABI Linux adalah **hujau yang musti tetap**. Semua perubahan yang menyentuh syscall numbers/calling convention → **tabu**.
- Scheduler depend pada timer/IRQ/smp; VM depends pada IOMMU/paging; VFS depends pada page cache.
- Driver worker-thread (e1000, USB, video-refresh) harus tetap "kernel-side" atau punya antarmuka yang tetap Linux ABI.
- Conflict terbesar: **custom ABI vs Linux ABI** — yang kita pilih Linux, jadi seluruh microkernel Lux yang custom syarat-nya buang.

## 15. Roadmap implementasi (bertahap, setiap langkah build+boot test)

**Fase 0 — Baseline (SEKARANG):** build bersih + boot `make run` untuk reference. ✅ (kita sudah build OK).

**Fase 1 — Audit keamanan syscall + missing uaccess.** (PRIORITAS #1, akar hybrid)
- Sebenarnya kita **sudah** punya uaccess matang di Uinxed. Jadi fase 1 = **audit**: pasang "user access checks" untuk semua argumen syscall yang belum lewat `copy_from_user`/`user_range_ok`.
- Tambal syscall yang masih pakai pointer mentah/patern `copy_path_from_user` di `syscall.c`.
- Deliverable: daftar syscall + status uaccess coverage; patcher yang aman (tidak mengubah ABI).
- Test: `make run` boot OK; loop `sys_` stub misal `sys_brk` dll tetap benar.

**Fase 2 — Request/response ID + kernel-side async queue (lepas dari scheduler).**
- Tambahkan `struct syscall_req`/queue yang SEJAJAR ke syscall, ID random non-zero (seperti Komodo) untuk syscalls yang butuh bolak-balik ke userspace service.
- Ini tidak mengubah ABI — internal kernel hanya menambah "pending reply" state untuk IPC yang menunggu.
- Test: unit module (kernel-side) + boot.

**Fase 3 — VFS service backend pertama (hybrid, OPSIONAL FUNGSIONAL).**
- Pilih satu backend VFS (misal tmpfs atau di atas cpio) yang bisa "dilayani" dari userspace helper service (af_unix socket service) lewat `vfs_regist_fs` callback.
- Ini bukti konsep hybrid PALING AMAN: satu VFS entrypoint, kernel tetap punya jalur fallback.

**Fase 4 — Userspace Komodo (`Userspace/`).**
- init/PID 1 minimal static (ELF) — kompatibel sama limine initramfs.
- mlibc minimal + shell (mawk/busybox static) kalau kompatibel.
- Jalur ke dynamic linking & musl port (bukan blocker).

**Fase 5 — Tata nama + dokumen kompat.**
- Verifikasi kompatibilitas Linux dengan **test program nyata** (bukan klaim): fork/clone/execve/futex/mmap/epoll socket, dst.

**Kriteria tiap fase:**
- Build bersih.
- Boot QEMU `make run` (video + serial).
- Regression: CLI syscall smoke test.
- Jangan hapus working functionality tanpa pengganti.
- Jangan massive rewrite.

## Prioritas konflik

```
ABI Linux > correctness/security > existing working functionality
    > clean architecture > experimental hybrid
```

---
Kesimpulan: **Uinxed adalah basis yang kuat dan matang** (ABI betul-betul Linux, uaccess & EEVDF berkelas). Komodo layak jadi "improved fork" dengan menambahkan: ~audit/coverage uaccess yang lengkap, request/response async infra untuk IPC kernel↔userspace, dan opsi hybrid VFS service — **tanpa pernah** membuang ABI Linux. Langkah pertama yang paling aman = **Fase 1: audit uaccess syscall + menutup celah**, lalu Fase 2 infra async, dan seterusnya.