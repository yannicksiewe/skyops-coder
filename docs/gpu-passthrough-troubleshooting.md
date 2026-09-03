# When a passed-through NVIDIA GPU looks healthy but no driver can initialise it

A field guide from one long day. Symptoms, the tools that finally explained them, and the fix.

## Symptoms

```
nvidia-smi:  No devices were found
dmesg:       NVRM: GPU 0000:05:00.0: RmInitAdapter failed! (0x62:0x56:2674)   # GSP mode  = NV_ERR_RESET_REQUIRED
             NVRM: GPU 0000:05:00.0: RmInitAdapter failed! (0x25:0xffff:1636) # legacy    = NV_ERR_INVALID_DATA
/proc/driver/nvidia/gpus/*/information:  Video BIOS: ??.??.??.??.??
```

while everything the CPU can see is fine: PCI IDs, BAR0/BAR1 (8 GB) mapped, link x16, VBIOS readable and
checksum-valid from the card's own PROM window, GFW boot scratch says "completed". Driver versions 535 and 580,
proprietary and open, GSP on and off: identical result. Two different cards (GA104, TU104) in two VMs: identical.

Things that do **not** help and only cost time: guest reboot, VM stop/start, host reboot, guest PCI FLR /
secondary bus reset, driver reinstalls, a romfile, reading MMU_LOCK registers (the driver ignores them on
consumer chips: `memmgrReadMmuLock` is only wired for GA100).

## The tool that explains it: the open kernel module with debug on

```bash
apt install nvidia-dkms-580-server-open nvidia-utils-580-server     # Ubuntu 24.04
modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
modprobe nvidia NVreg_ResmanDebugLevel=0 NVreg_RmMsg=":" NVreg_EnableGpuFirmwareLogs=1
nvidia-smi; dmesg | grep NVRM | grep -viE "VM:|ioctl"
```

The first real error appears:

```
NVRM: kgspExecuteFwsec_TU102: failed to execute FWSEC for FRTS: no initialized WPR2 found
NVRM: kgspExecuteFwsec_TU102: (note: VBIOS version 94.04.67.00.3C)
NVRM: kgspGetWprEndMargin_IMPL: Adding margin of 0xca00000 bytes after the end of WPR2      <- retry
NVRM: _kgspPrepareScrubberImageIfNeeded: pre-scrubbed memory: 0x10000000, needed: 0x19500000 <- retry overflow
NVRM: Assertion failed: pBinArchive != NULL @ kernel_gsp_booter.c:487 -> NV_ERR_NOT_SUPPORTED
NVRM: RmInitAdapter: Cannot initialize GSP firmware RM
```

Reading `open-gpu-kernel-modules` (branch 580):

* the driver extracts the FWSEC ucode from the VBIOS (works: it prints the version), puts code and data in
  **system memory** (`kernel_gsp_fwsec.c`, `ADDR_SYSMEM`), and starts the GPU's secure falcon with a boot loader that
  **DMAs the ucode from that memory** (`kernel_gsp_falcon_tu102.c`: `ctxDma = 4 /* PHYS_SYS_NCOH */`,
  `codeDmaBase = sysmem PA`);
* the falcon halts with no FRTS error code and WPR2 unprogrammed: the ucode never arrived;
* every retry shifts the WPR region down; on GA10x/TU10x `kgspGetPrescrubbedTopFbSize` is a constant 256 MB and
  `kgspIsScrubberImageSupported` is false, so after a couple of retries you get the scrubber assertion. That
  assertion is a *symptom of retries*, not the cause.

CPU -> GPU register access works. GPU -> guest RAM DMA does not. That is an IOMMU / vfio DMA-mapping problem, and
it is invisible from inside the guest.

## Root cause in our case: two hypervisor layers

```
bare metal (intel_iommu=on, real DMAR)  ->  Proxmox VM running nova-compute (emulated BOCHS IOMMU)  ->  instance
```

The inner, emulated IOMMU cannot map the instance's memory into the physical IOMMU, so device DMA targets the wrong
addresses. Nested vfio passthrough of a GeForce card is not a working configuration. The instance reported itself
as "OpenStack Nova" while the operator managed it as a Proxmox VM; that mismatch was the first clue.

**Fix:** attach the GPU to a VM that runs directly on the bare-metal host (Q35, OVMF, `hostpci0: <bdf>,pcie=1`,
both PCI functions, vfio-pci bound at boot). Same cards, same driver: works on the first try.

## Checklist for the host operator

```bash
systemd-detect-virt                          # 'none' on the machine that has the GPU in lspci, or it is nested
cat /proc/cmdline                            # intel_iommu=on iommu=pt
lspci -nnk -s <gpu>; lspci -nnk -s <audio>   # both bound to vfio-pci
dmesg | grep -iE "DMAR|AMD-Vi|vfio"          # DMA faults naming the GPU = IOMMU problem
tools/gpu_passthrough_check.sh               # from this repo: virt type, bindings, reset, register sanity
```

## Useful guest-side probes (no driver needed)

```python
# read GPU registers straight from BAR0 (run as root)
import mmap, struct
with open('/sys/bus/pci/devices/0000:05:00.0/resource0','r+b') as f:
    m = mmap.mmap(f.fileno(), 0x1000000); r = lambda o: struct.unpack_from('<I', m, o)[0]
    print(hex(r(0x0)))        # PMC_BOOT_0: chip id (0x174000a1 = GA104-A1)
    print(hex(r(0x118234)))   # GFW boot scratch: low byte 0xff = firmware boot completed
    print(r(0x1183a4))        # usable FB size in MB (Ampere)
    prom = m[0x300000:0x400000]   # on-card VBIOS via PROM window; 0x55 0xAA header, "K7400" signature
```

Note: `cat /sys/bus/pci/devices/<bdf>/rom` stops at the PCI "last image" flag (~150 KB on these cards). That is
not a truncated ROM; do not send your provider on a romfile chase because of it.
