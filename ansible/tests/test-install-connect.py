"""Exercise lifecycle endpoint routing with mocked commands; never contact hosts."""
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'ansible.sh').read_text().rsplit('\nmain "$@"', 1)[0]
mocks = r'''
ansible-inventory() { printf '{"nvme_serial":"fixture","ansible_host":"192.0.2.1","final_hostname":"kube1","local_domain":"example.test"}\n'; }
ansible-playbook() { printf 'PLAY'; printf ' <%s>' "$@"; printf '\n'; }
ssh() { printf 'SSH'; printf ' <%s>' "$@"; printf '\n'; }
'''
functions = {
    'install-iso': ('run_install_iso', ''),
    'bootstrap-host': ('run_bootstrap_host', 'BOOTSTRAP NODE kube1\n'),
    'configure-host': ('run_configure_host', 'CONFIGURE NODE kube1\n'),
    'prepare-kubernetes': ('run_prepare_kubernetes', 'PREPARE KUBERNETES kube1\n'),
}


def run(command, *args):
    function, confirmation = functions[command]
    script = source + mocks + f'\n{function} "$@"\n'
    return subprocess.run(['bash', '-c', script, 'fixture', *args],
                          input=confirmation, text=True, capture_output=True)


install_socket_dirs = set()
for command in functions:
    for address in (None, 'kube-installer', 'kube-installer.local', 'other-live.example', '192.0.2.123'):
        args = ['kube1'] + (['--connect', address] if address else [])
        result = run(command, *args)
        assert result.returncode == 0, result.stderr
        plays = [line for line in result.stdout.splitlines() if line.startswith('PLAY')]
        assert len(plays) == (2 if command == 'install-iso' else 1), result.stdout
        if command == 'install-iso':
            socket_dirs = [re.search(r'<ansible_control_path_dir=([^>]+)>', play).group(1)
                           for play in plays]
            assert socket_dirs[0] == socket_dirs[1], socket_dirs
            assert socket_dirs[0] not in install_socket_dirs, socket_dirs
            install_socket_dirs.add(socket_dirs[0])
            assert not pathlib.Path(socket_dirs[0]).exists(), 'private directory not cleaned'
            assert all('<ansible_control_path=%(directory)s/%%C>' in play for play in plays)
        else:
            assert all('ansible_control_path' not in play for play in plays)
        for play in plays:
            assert '<target_node=kube1>' in play
            if command == 'install-iso':
                live = 'kube-installer' if address is None else address
                assert f'<installer_connect_host={live}>' in play
                assert 'HostKeyAlias=kube1' in play
                assert '<ansible_ssh_args=-C -o ControlMaster=no -o ControlPath=none>' in play
                assert '<ansible_host=' not in play  # must remain switchable after reboot
                assert '<installer_destination_host=kube1.example.test>' in play
            else:
                assert 'installer_connect_host' not in play
                if address:
                    assert f'<ansible_host={address}>' in play
                else:
                    assert '<ansible_host=' not in play
        if command == 'bootstrap-host':
            assert f'<root@{address or "192.0.2.1"}>' in result.stdout

    for tail in (('--connect',), ('--connect', ''), ('--connect', 'root@host'),
                 ('--connect', 'host x=y'), ('--connect', '-option'),
                 ('--unknown', 'host'), ('--connect', 'host', 'extra')):
        result = run(command, 'kube1', *tail)
        assert result.returncode != 0, (command, tail)
        assert 'PLAY' not in result.stdout and 'SSH' not in result.stdout, result.stdout

result = run('install-iso', 'kube1', '--live-connect', '192.0.2.61')
assert result.returncode != 0
assert 'PLAY' not in result.stdout

# Check that destination selection stays separate from the mutable live address.
import yaml
for name in ('20-inspect-live-iso.yml', '30-install-live-iso.yml'):
    play = yaml.safe_load((root / 'playbooks' / name).read_text())[0]
    facts = [task['ansible.builtin.set_fact'] for task in play['pre_tasks']]
    assert facts[0]['installer_installed_host'] == (
        "{{ installer_destination_host | default(final_hostname ~ '.' ~ local_domain) }}")
    assert facts[1]['ansible_host'] == '{{ installer_connect_host }}'
print('Lifecycle --connect routing checks passed (no host connections)')
