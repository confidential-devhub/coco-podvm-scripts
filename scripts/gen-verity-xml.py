#!/usr/bin/env python3
import sys, os

roothash = sys.argv[1]
kargs = (
    "root=/dev/mapper/root"
    " roothash=" + roothash +
    " systemd.verity_root_data=/dev/vda2"
    " systemd.verity_root_hash=/dev/vda3"
    " systemd.volatile=overlay"
    " rd.driver.pre=overlay"
    " console=ttysclp0"
    " ro rd.shell rd.debug panic=0"
)

xml = """<domain type='kvm'>
  <name>podvm-verity-test</name>
  <memory unit='MiB'>2048</memory>
  <vcpu>2</vcpu>
  <os>
    <type arch='s390x' machine='s390-ccw-virtio'>hvm</type>
    <kernel>/tmp/vmlinuz-6.12.0-211.53.1.el10_2.s390x</kernel>
    <initrd>/tmp/initramfs-6.12.0-211.53.1.el10_2.s390x.img</initrd>
    <cmdline>{kargs}</cmdline>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/home/linuxuser/rafsal/new_build/output/rhel10-s390x-base.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <readonly/>
    </disk>
    <console type='pty'>
      <target type='sclp'/>
    </console>
  </devices>
</domain>""".format(kargs=kargs)

out = "/tmp/podvm-verity.xml"
with open(out, "w") as f:
    f.write(xml)

print("Written to", out)
print("cmdline:", kargs)
