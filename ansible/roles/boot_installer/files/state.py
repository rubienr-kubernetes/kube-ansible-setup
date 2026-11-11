"""Read-only installed/live preflight. Also used by controller reconnection probes."""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def mount_at(path):
    return json.loads(run('findmnt', '--json', '--target', path,
                          '--output', 'TARGET,SOURCE,FSTYPE,UUID,FSROOT'))['filesystems'][0]


def read(path):
    return Path(path).read_text().strip()


def identity(disk, serial, mac):
    device = os.path.realpath(disk)
    require(re.fullmatch(r'/dev/nvme[0-9]+n[0-9]+', device), 'Unsupported installation disk')
    observed = run('lsblk', '--nodeps', '--noheadings', '--output', 'SERIAL', device)
    require(observed == serial, 'Disk serial does not match inventory')
    nics = json.loads(run('ip', '-j', 'address', 'show'))
    matches = [nic for nic in nics if nic.get('address', '').lower() == mac.lower()]
    require(len(matches) == 1, 'Management MAC does not match inventory')
    addresses = [a['local'] for a in matches[0].get('addr_info', [])
                 if a['family'] == 'inet' and a.get('scope') == 'global']
    require(addresses, 'Management NIC has no global IPv4 address')
    return device, addresses


def check_live(data, old_boot, expected_sha512, expected_hostname):
    require(data['hostname'] == expected_hostname, 'Live hostname does not match the requested installer identity')
    require(data['boot_id'] != old_boot, 'Still on the previous boot')
    require(data['root_fstype'] == 'overlay', 'Live root is not overlay')
    require('copytoram=y' in data['cmdline'].split(), 'copytoram=y is missing')
    require(data['copy_fstype'] == 'tmpfs' and data['cow_fstype'] == 'tmpfs',
            'Live image and writable state must both reside in RAM')
    require(not data['disk_mounts'] and not data['holders'] and not data['swap'],
            'Installation disk is still in use')
    require(not data['source_mounts'], 'Source ISO mount is still present')
    require(data['loops'] and all(path.startswith('/run/archiso/copytoram/')
                                 for path in data['loops']), 'Loop device still depends on disk')
    require(data['sha512'] == expected_sha512, 'RAM filesystem checksum mismatch')


def inspect(mode, disk, serial, mac, *extra):
    require(os.geteuid() == 0, 'Root SSH is required')
    device, addresses = identity(disk, serial, mac)
    root = mount_at('/')
    result = dict(hostname=socket.gethostname(), boot_id=read('/proc/sys/kernel/random/boot_id'),
                  kernel=run('uname', '-r'), addresses=addresses, cmdline=read('/proc/cmdline'),
                  root_fstype=root['fstype'])
    if mode == 'installed':
        require(not Path('/run/archiso').exists(), 'Already running ArchISO; use install-iso instead')
        require('archisobasedir=' not in result['cmdline'], 'Already booted as an installer')
        require(root['fstype'] == 'btrfs' and root['fsroot'] == '/@', 'Expected installed Btrfs @ root')
        require(os.path.realpath(root['source'].split('[')[0]) == device + 'p2',
                'Installed root does not belong to the inventory OS partition')
        require(re.fullmatch(r'[0-9a-fA-F-]{36}', root['uuid'] or ''), 'Invalid root filesystem UUID')
        require(Path('/sys/firmware/efi').is_dir(), 'UEFI boot is required')
        require(read('/sys/kernel/kexec_loaded') == '0', 'Another kexec target is already loaded')
        require(read('/proc/sys/kernel/kexec_load_disabled') == '0', 'Kexec loading is disabled')
        lockdown = Path('/sys/kernel/security/lockdown')
        require(not lockdown.exists() or '[none]' in lockdown.read_text(), 'Kernel lockdown is enabled')
        require(not run('swapon', '--noheadings', '--show'), 'Active swap is outside the approved baseline')
        require(not Path('/etc/kubernetes/kubelet.conf').exists(),
                'Cluster member: drain/recovery orchestration is not implemented')
        for unit in ('kubelet', 'etcd'):
            require(subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode != 0,
                    f'{unit} is running; cluster maintenance is not implemented')
        for directory in ('/var/lib/etcd', '/etc/kubernetes/manifests'):
            path = Path(directory)
            require(not path.exists() or not any(path.iterdir()), 'Retained cluster state needs a recovery plan')
        require('BootNext:' not in run('efibootmgr'), 'Pending BootNext would make recovery ambiguous')
        for path in ('/boot/EFI/GRUB/grubx64.efi', '/boot/grub/grub.cfg',
                     '/boot/vmlinuz-linux', '/boot/initramfs-linux.img'):
            require(Path(path).is_file() and Path(path).stat().st_size > 0, f'Recovery boot file missing: {path}')
        require(os.path.realpath('/root') == '/root' and mount_at('/root')['target'] == '/',
                'Staging requires /root on the installed root filesystem')
        stage = Path('/root/kube-boot-installer')
        require(not stage.is_symlink(), 'Staging path must not be a symlink')
        if stage.exists():
            require(stage.is_dir() and stage.stat().st_uid == 0 and stage.stat().st_mode & 0o077 == 0,
                    'Existing staging directory is not root-private')
        size = int(extra[0])
        memory = int(re.search(r'^MemAvailable:\s+(\d+)', read('/proc/meminfo'), re.M)[1]) * 1024
        require(memory >= size * 2 + 3 * 1024**3, 'Insufficient available RAM for installer and recovery margin')
        fs = os.statvfs('/root')
        require(fs.f_bavail * fs.f_frsize >= size * 2 + 1024**3, 'Insufficient staging disk space')
        result.update(uuid=root['uuid'], available_ram=memory, disk_free=fs.f_bavail * fs.f_frsize)
    elif mode == 'live':
        require(Path('/run/archiso').is_dir(), 'No ArchISO runtime marker')
        lines = run('findmnt', '--raw', '--noheadings', '--output', 'TARGET,SOURCE').splitlines()
        topology = json.loads(run('lsblk', '--json', '--output', 'NAME,MOUNTPOINTS', device))
        def mounted_devices(devices):
            for entry in devices:
                if any(entry.get('mountpoints') or []):
                    yield entry['name']
                yield from mounted_devices(entry.get('children', []))
        disk_mounts = list(mounted_devices(topology['blockdevices']))
        result.update(copy_fstype=mount_at('/run/archiso/copytoram')['fstype'],
                      cow_fstype=mount_at('/run/archiso/cowspace')['fstype'],
                      disk_mounts=disk_mounts + [line for line in lines if device in line],
                      source_mounts=[line for line in lines if line.split()[0] in
                                     ('/run/archiso/img_dev', '/run/archiso/bootmnt')],
                      holders=[str(p) for p in Path('/sys/class/block').glob(Path(device).name + '*/holders/*')],
                      swap=run('swapon', '--noheadings', '--show'),
                      loops=[entry['back-file'] for entry in json.loads(run('losetup', '--json', '--list',
                                                                                  '--output', 'BACK-FILE'))['loopdevices']],
                      sha512=run('sha512sum', '/run/archiso/copytoram/airootfs.sfs').split()[0])
        check_live(result, *extra)
        for unit in ('sshd', 'systemd-networkd', 'avahi-daemon'):
            require(subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0,
                    f'{unit} is not active')
    else:
        raise ValueError('Unknown inspection mode')
    return result


if __name__ == '__main__':
    try:
        print(json.dumps(inspect(*sys.argv[1:])))
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, IndexError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
