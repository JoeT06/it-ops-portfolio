# QNAP RAID recovery on Linux

**Status:** Runbook\
**My role:** Built the lab and wrote the runbook\
**Stack:** Ubuntu Server, mdadm, LVM, smartmontools, ClamAV, rsync, Hyper-V, ProBox USB DAS enclosure

## Goal

Get the data off a QNAP NAS without booting the NAS or writing to its drives. The drives go into a USB enclosure on an isolated Linux box, the RAID is assembled and mounted read-only, and the data is checked before it's copied anywhere.

## Lab

| Box | Role |
|---|---|
| Recovery box | Old laptop running Ubuntu Server with no GUI. Assembles the RAID and copies the data out. Comes off the network once the tools are installed. |
| Clean box | Intel NUC running a Windows 11 VM on Hyper-V. Recovered files are opened here to check that they aren't infected. Kept separate from the recovery box. |
| Enclosure | ProBox DAS in JBOD mode, so Linux sees each drive on its own. |

## Rules for the whole job

- Don't format or initialize the drives, on the Linux box or in the enclosure.
- Don't use the enclosure's RAID mode.
- Don't mount a member disk directly.
- Don't mount the array read-write.
- Don't change the array config by guesswork.
- Don't run anything from the recovered data.

## Steps

### 1. Build the recovery box

Install Ubuntu Server on an old laptop, get it on the network, and update it. Then install the tools:

```bash
sudo apt update
sudo apt install mdadm lvm2 smartmontools clamav
```

Verify the installs. ClamAV pulls signatures on install, and the date at the end of `clamscan --version` is the signature date.

```bash
mdadm --version
lvm version
smartctl --version
clamscan --version
```

Disconnect the box from the network before any NAS drive touches it.

### 2. Build the clean box

On the NUC, enable Hyper-V and create a Windows 11 VM:

- Attach the Windows 11 ISO to the VM's DVD drive.
- In the VM firmware, set the boot order to DVD drive, hard drive, network adapter.
- Add a virtual hard disk if Windows setup shows no drive.
- Finish Windows setup.

### 3. Prep the drives

- Leave the QNAP powered off.
- Label each drive with its original slot number.
- Set the ProBox to JBOD (individual disk) mode.

### 4. Move the drives

Move the drives into the ProBox in slot order, then connect the ProBox to the recovery box.

### 5. Find the drives and lock them read-only

```bash
lsblk
```

The member disks show up as devices like `/dev/sdb` through `/dev/sde`. Set the disks and their partitions read-only at the block layer, so nothing can write to them by mistake:

```bash
sudo blockdev --setro /dev/sd[b-e]*
```

### 6. Check drive health

Check health before assembling the array, so a failing drive isn't worked harder than it has to be:

```bash
sudo smartctl -a /dev/sdb
sudo smartctl -a /dev/sdc
sudo smartctl -a /dev/sdd
sudo smartctl -a /dev/sde
```

Reallocated or pending sectors mean the drive is failing. Image it with `ddrescue` and work from the image.

### 7. Assemble the RAID read-only

```bash
cat /proc/mdstat
```

Ubuntu may assemble the arrays on its own when the drives connect. If they're missing, assemble them read-only:

```bash
sudo mdadm --assemble --scan --readonly
```

If they're already listed, set the data array read-only:

```bash
sudo mdadm --readonly /dev/md124
```

On this NAS the large RAID 5 array (`md124`) held the data. The small arrays (`md125`, `md126`, `md127`) are QNAP system partitions. Array numbers can differ on another system.

### 8. Mount the data array read-only

```bash
sudo mkdir /mnt/recovery
sudo mount -o ro,noload /dev/md124 /mnt/recovery
ls /mnt/recovery
```

`noload` skips the ext4 journal. A plain `ro` mount still replays a dirty journal, and that writes to the disk.

If the array won't mount, the volume may sit on LVM:

```bash
sudo vgscan
sudo vgchange -ay
lsblk
```

Then mount the logical volume that holds the data, read-only, the same way.

### 9. Review the data

- Browse the folders and check that files look normal.
- Look for ransom notes, and for files that are encrypted or renamed with an unfamiliar extension.
- Don't modify anything on the mounted source.

### 10. Scan for malware

```bash
clamscan -r -i /mnt/recovery
```

`-i` prints only infected files. For a large dataset, copy it first and scan the copy on a clean target.

### 11. Copy the data out

```bash
rsync -avh /mnt/recovery/ /path/to/backup/
```

`rsync` over `cp -r`: if the copy is interrupted, rerunning the same command skips the files that already made it.

### 12. Check the files on the clean box

Open the copied files in the Windows VM on the NUC to check that they aren't infected.

## Command reference

```bash
lsblk
sudo blockdev --setro /dev/sd[b-e]*
sudo smartctl -a /dev/sdX
cat /proc/mdstat
sudo mdadm --assemble --scan --readonly
sudo mdadm --readonly /dev/md124
sudo mkdir /mnt/recovery
sudo mount -o ro,noload /dev/md124 /mnt/recovery
sudo vgscan
sudo vgchange -ay
clamscan -r -i /mnt/recovery
rsync -avh /mnt/recovery/ /path/to/backup/
```
