"""Offline routing and fail-closed acceptance tests. Never SSH to inventory hosts."""
import copy
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml
from jinja2 import StrictUndefined, Template

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / 'roles/boot_installer/files'
spec = importlib.util.spec_from_file_location('boot_state', FILES / 'state.py')
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)
spec_return = importlib.util.spec_from_file_location('boot_reconnect', FILES / 'reconnect.py')
reconnect = importlib.util.module_from_spec(spec_return)
spec_return.loader.exec_module(reconnect)


class LiveAcceptance(unittest.TestCase):
    def setUp(self):
        self.data = dict(hostname='kube1-installer', boot_id='new', root_fstype='overlay', cmdline='archisobasedir=arch copytoram=y',
                         copy_fstype='tmpfs', cow_fstype='tmpfs', disk_mounts=[], holders=[], swap='',
                         source_mounts=[], loops=['/run/archiso/copytoram/airootfs.sfs'], sha512='a' * 128)

    def test_accept_ram_only(self):
        state.check_live(self.data, 'old', 'a' * 128, 'kube1-installer')

    def test_reject_each_unsafe_state(self):
        cases = dict(hostname='kube-installer', boot_id='old', root_fstype='btrfs', cmdline='copytoram=n',
                     copy_fstype='btrfs', cow_fstype='btrfs', disk_mounts=['/dev/nvme0n1p2'],
                     holders=['dm-0'], swap='/dev/zram0', source_mounts=['/run/archiso/img_dev'],
                     loops=['/root/staged.iso'], sha512='b' * 128)
        for key, value in cases.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                data = copy.deepcopy(self.data)
                data[key] = value
                state.check_live(data, 'old', 'a' * 128, 'kube1-installer')

    def test_wrong_hardware_is_rejected(self):
        with patch.object(state, 'run', return_value='wrong-serial'):
            with self.assertRaisesRegex(ValueError, 'serial'):
                state.identity('/dev/nvme0n1', 'expected', '00:00:00:00:00:01')
        with patch.object(state, 'run', side_effect=['expected', json.dumps([
                {'address': '00:00:00:00:00:02', 'addr_info': []}])]):
            with self.assertRaisesRegex(ValueError, 'MAC'):
                state.identity('/dev/nvme0n1', 'expected', '00:00:00:00:00:01')


class Reconnection(unittest.TestCase):
    def arguments(self, timeout='60'):
        return ['reconnect.py', '--state-script', str(FILES / 'state.py'),
                '--candidates', '["192.0.2.1", "live.example"]',
                '--disk', '/dev/nvme0n1', '--serial', 'expected',
                '--mac', '00:00:00:00:00:01', '--old-boot', 'old',
                '--sha512', 'a' * 128, '--hostname', 'kube1-installer', '--timeout', timeout]

    def test_wrong_node_is_skipped_and_sessions_are_fresh(self):
        responses = [subprocess.CompletedProcess([], 1, '', 'Disk serial does not match inventory'),
                     subprocess.CompletedProcess([], 0, '{"boot_id":"new"}', '')]
        with patch.object(reconnect.subprocess, 'run', side_effect=responses) as calls, \
             patch('sys.argv', self.arguments()), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(reconnect.main(), 0)
        report = json.loads(output.getvalue())
        self.assertEqual(report['verified_endpoint'], 'live.example')
        first, second = [call.args[0] for call in calls.call_args_list]
        self.assertIn('ControlPath=none', first)
        self.assertNotEqual(next(a for a in first if a.startswith('UserKnownHostsFile=')),
                            next(a for a in second if a.startswith('UserKnownHostsFile=')))
        self.assertIn(' live /dev/nvme0n1 expected ', first[-1])
        self.assertEqual(shlex.split(first[-1])[-1], 'kube1-installer')

    def test_timeout_does_not_attempt_installation(self):
        with patch('sys.argv', self.arguments('0')), patch.object(reconnect.subprocess, 'run') as calls, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(reconnect.main(), 1)
        calls.assert_not_called()
        self.assertIn('Do not run installation', output.getvalue())


class Routing(unittest.TestCase):
    def test_wrapper(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / 'iso').mkdir()
            (work / 'export.sh').write_text('')
            (work / 'archiso.sh').write_text((ROOT / 'archiso.sh').read_text())
            (work / 'archiso.sh').chmod(0o700)
            iso = work / 'iso/test-kube-installer.iso'
            iso.write_bytes(b'fixture')
            import hashlib
            sidecar = Path(str(iso) + '.sha256')
            sidecar.write_text(hashlib.sha256(iso.read_bytes()).hexdigest() + '  ' + iso.name + '\n')
            source = (ROOT / 'ansible.sh').read_text().rsplit('\nmain "$@"', 1)[0]
            line = next(line for line in source.splitlines() if line.startswith('readonly SCRIPT_DIR='))
            source = source.replace(line, 'readonly SCRIPT_DIR=' + shlex.quote(str(work)))
            mock = r'''
ansible-inventory() { printf '{"nvme_serial":"fixture"}\n'; }
ansible-playbook() {
    python3 - "$@" <<'JSON'
import json, sys
argument = next(a for a in sys.argv if a.startswith('--extra-vars=@'))
with open(argument.split('@', 1)[1]) as handle:
    print('VARS:' + json.dumps(json.load(handle)))
print('PLAY:' + ' '.join(sys.argv[1:]))
JSON
}
run_boot_installer "$@"
'''
            def invoke(*args):
                return subprocess.run(['bash', '-c', source + mock, 'fixture', *args],
                                      text=True, capture_output=True)
            for option in ('--connect', '--conenct'):
                result = invoke('kube1', option, 'kube1.example', '--live-connect', 'live.example')
                self.assertEqual(result.returncode, 0, result.stderr)
                values = json.loads(next(line[5:] for line in result.stdout.splitlines() if line.startswith('VARS:')))
                self.assertEqual(values['target_node'], 'kube1')
                self.assertEqual(values['boot_installer_connect'], 'kube1.example')
                self.assertEqual(values['boot_installer_live_connect'], 'live.example')
                self.assertNotIn('ansible_host', values)
                self.assertIn('ControlPath=none', values['ansible_ssh_args'])
                self.assertIn('25-boot-installer.yml', result.stdout)
                self.assertNotIn('30-install-live-iso.yml', result.stdout)
            result = invoke('kube1')
            self.assertEqual(result.returncode, 0, result.stderr)
            values = json.loads(next(line[5:] for line in result.stdout.splitlines() if line.startswith('VARS:')))
            self.assertEqual(values['boot_installer_connect'], '')
            self.assertEqual(values['boot_installer_live_connect'], 'kube1-installer.local')
            for arguments in [(), ('all:*',), ('kube1', '--connect'), ('kube1', '--connect', 'root@node'),
                              ('kube1', '--connect', 'node x=y'), ('kube1', '--bogus', 'x')]:
                result = invoke(*arguments)
                self.assertNotEqual(result.returncode, 0, arguments)
                self.assertNotIn('PLAY:', result.stdout)
            iso.write_bytes(b'corrupt')
            result = invoke('kube1')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('PLAY:', result.stdout)
            iso.unlink()
            result = invoke('kube1')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('archiso.sh create', result.stderr)

    def test_per_node_kernel_hostname(self):
        tasks = yaml.safe_load((ROOT / 'roles/boot_installer/tasks/main.yml').read_text())
        facts = {key: value for task in tasks for key, value in
                 task.get('ansible.builtin.set_fact', {}).items()}
        for host in ('kube1', 'kube2'):
            hostname = Template(facts['boot_live_hostname'], undefined=StrictUndefined).render(
                inventory_hostname=host)
            command = Template(facts['boot_command_line'], undefined=StrictUndefined).render(
                boot_live_hostname=hostname, boot_before={'uuid': 'fixture'}, boot_stage='/root/stage')
            self.assertEqual(hostname, host + '-installer')
            self.assertIn('systemd.hostname=' + hostname, shlex.split(command))
            self.assertIn('copytoram=y', shlex.split(command))

    def test_confirmation_precedes_loading_and_no_installation(self):
        tasks = yaml.safe_load((ROOT / 'roles/boot_installer/tasks/main.yml').read_text())
        names = [task['name'] for task in tasks]
        self.assertLess(names.index('Verify handoff confirmation before loading a kernel'),
                        names.index('Load and schedule the orderly handoff'))
        text = (ROOT / 'playbooks/25-boot-installer.yml').read_text()
        self.assertNotIn('role: arch_install', text)
        self.assertNotIn('30-install-live-iso', text)


if __name__ == '__main__':
    unittest.main()
