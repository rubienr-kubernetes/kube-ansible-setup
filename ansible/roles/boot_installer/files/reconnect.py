"""Poll fresh live SSH sessions; perform read-only identity and RAM-state checks."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-script', required=True)
    parser.add_argument('--candidates', required=True)
    parser.add_argument('--disk', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--mac', required=True)
    parser.add_argument('--hostname', required=True)
    parser.add_argument('--old-boot', required=True)
    parser.add_argument('--sha512', required=True)
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    candidates = list(dict.fromkeys(json.loads(args.candidates)))
    command = shlex.join(['python3', '-c', Path(args.state_script).read_text(), 'live',
                          args.disk, args.serial, args.mac, args.old_boot, args.sha512, args.hostname])
    deadline = time.monotonic() + args.timeout
    errors = {}
    while time.monotonic() < deadline:
        for address in candidates:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            # Live images generate a new SSH identity. A failed probe must not pin
            # the old installed key and prevent the next probe after the reboot.
            with tempfile.TemporaryDirectory(prefix='kube-live-probe-') as directory:
                ssh = ['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                       '-o', 'ConnectionAttempts=1', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                       '-o', 'StrictHostKeyChecking=accept-new', '-o',
                       f'UserKnownHostsFile={directory}/known_hosts', f'root@{address}', command]
                try:
                    result = subprocess.run(ssh, text=True, capture_output=True, timeout=min(30, remaining))
                    if result.returncode == 0:
                        report = json.loads(result.stdout)
                        report['verified_endpoint'] = address
                        print(json.dumps(report))
                        return 0
                    errors[address] = result.stderr.strip()[-800:]
                except (subprocess.TimeoutExpired, ValueError) as error:
                    errors[address] = str(error)
        time.sleep(max(0, min(5, deadline - time.monotonic())))
    print(json.dumps({'error': 'No verified live installer returned. Do not run installation.',
                      'probes': errors}))
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
