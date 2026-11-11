"""Exercise real firmware selection expressions with USB and kexec records."""
import ast
import pathlib
import re

import jinja2
import yaml

root = pathlib.Path(__file__).resolve().parents[1]
tasks = yaml.safe_load((root / 'roles/arch_install/tasks/main.yml').read_text())

def flatten(items):
    for item in items:
        yield item
        for key in ('block', 'always', 'rescue'):
            yield from flatten(item.get(key, []))

flat = list(flatten(tasks))
by_name = {task.get('name'): task for task in flat}
env = jinja2.Environment(undefined=jinja2.StrictUndefined)
env.filters['regex_findall'] = lambda value, pattern: re.findall(pattern, value)

def evaluate(task_name, fact, **values):
    expression = by_name[task_name]['ansible.builtin.set_fact'][fact]
    return ast.literal_eval(env.from_string(expression).render(**values))

for current, expected in [('0001', ['0005', '000A']), ('0005', ['000A'])]:
    actual = evaluate('Exclude BootCurrent from stale GRUB cleanup',
                      'install_grub_cleanup_entries',
                      install_owned_grub_entries=['0005', '000A'],
                      install_boot_current=current)
    assert actual == expected, actual
    assert current not in actual

records = '''BootCurrent: 000C
Boot0005* GRUB HD(old)\\EFI\\GRUB\\grubx64.efi
Boot000A  GRUB HD(older)\\EFI\\GRUB\\grubx64.efi
Boot000C* GRUB HD(new)\\EFI\\GRUB\\grubx64.efi
Boot000D* GRUB-rescue HD(other)
Boot000E* Windows Boot Manager HD(other)
'''
actual = evaluate('Select stale GRUB entries after verified installed-system boot',
                  'install_post_boot_stale_grub_entries',
                  install_efi_post_boot={'stdout': records}, install_new_grub_entry='000C')
assert actual == ['0005', '000A'], actual
for task in flat:
    command = task.get('ansible.builtin.command', {})
    argv = command.get('argv', []) if isinstance(command, dict) else []
    if 'grub-install' in argv:
        assert '--no-nvram' in argv, task['name']
names = [task.get('name') for task in flat]
assert names.index('Require the verified installed GRUB entry as BootCurrent') < names.index(
    'Remove noncurrent exact GRUB entries after successful handoff')
print('USB/kexec firmware cleanup regression checks passed')
