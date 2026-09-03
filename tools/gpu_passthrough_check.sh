#!/usr/bin/env bash
# Run as root on the BARE-METAL host that owns the RTX 3070, with the VM stopped.
# Shows whether the card can be reset and whether the MMU_LOCK leftover state clears.
set -u
GPU=$(lspci -Dn | awk '$3=="10de:2488"{print $1; exit}')
AUD=$(lspci -Dn | awk '$3=="10de:228b"{print $1; exit}')
[ -n "$GPU" ] || { echo "no 10de:2488 on this machine -> this is not the bare-metal host (nested?)"; exit 1; }
echo "GPU=$GPU  AUDIO=${AUD:-none}"
echo "virt: $(systemd-detect-virt 2>/dev/null || echo unknown)   (must be 'none' for a real reset)"
for d in $GPU $AUD; do [ -n "$d" ] && echo "$d driver: $(basename "$(readlink /sys/bus/pci/devices/$d/driver 2>/dev/null)" 2>/dev/null || echo NONE)"; done
echo "reset_method: $(cat /sys/bus/pci/devices/$GPU/reset_method 2>&1)"
echo "iommu group: $(basename "$(readlink /sys/bus/pci/devices/$GPU/iommu_group)") members: $(ls /sys/bus/pci/devices/$GPU/iommu_group/devices | tr '\n' ' ')"
readlock() {
python3 - "$GPU" <<'PY'
import mmap,struct,sys
p=f'/sys/bus/pci/devices/{sys.argv[1]}/resource0'
with open(p,'r+b') as f:
    m=mmap.mmap(f.fileno(),0x1000000); r=lambda o: struct.unpack_from('<I',m,o)[0]
    lo=((r(0x1fa82c)>>4)&0x0fffffff)<<12; hi=((r(0x1fa830)>>4)&0x0fffffff)<<12
    print(f"  BOOT0=0x{r(0):08x}  GFW=0x{r(0x118234):08x}  usableFB={r(0x1183a4)} MB  MMU_LOCK {lo>>20} MB .. {hi>>20} MB -> {'LOCKED (bad)' if hi>=lo and lo < 7000<<20 else 'normal'}")
PY
}
echo "before reset:"; readlock
echo "issuing PCI reset..."; echo 1 > /sys/bus/pci/devices/$GPU/reset 2>&1 && echo "  reset write OK" || echo "  reset write FAILED"
dmesg | tail -5 | grep -iE "vfio|$GPU|reset" || true
sleep 3
echo "after reset:"; readlock
echo "Expected after a real reset: MMU_LOCK 'normal'. If still LOCKED, the card's own firmware sets it -> test card on bare metal with nvidia-smi."
