#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly ANSIBLE_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)

# shellcheck source=../boot-next-installer.sh
source "$ANSIBLE_DIR/boot-next-installer.sh"

fail() {
    printf 'test_boot_installer_next.sh: FAIL: %s\n' "$*" >&2
    exit 1
}

[[ $(normalize_entry 000a) == 000A ]] || fail 'plain entry normalization failed'
[[ $(normalize_entry Boot00fF) == 00FF ]] || fail 'Boot-prefixed entry normalization failed'
[[ $(normalize_entry bOoT000e) == 000E ]] || fail 'mixed-case Boot prefix was rejected'
if (normalize_entry 7 >/dev/null 2>&1); then
    fail 'short entry number was accepted'
fi

sample_output=$'BootCurrent: 0001\nBootOrder: 0001,0007\nBoot0001* Arch Linux HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0x200000)/\\File(\\EFI\\GRUB\\grubx64.efi)\nBoot0007* USB installer HD(2,GPT,11111111-2222-3333-4444-555555555555,0x1000,0x20000)/\\File(\\EFI\\BOOT\\BOOTX64.EFI)'
line=$(selected_boot_line "$sample_output" 0007) || fail 'selected entry was not found'
[[ $line == Boot0007\** ]] || fail 'wrong entry line was selected'
[[ $(extract_gpt_uuid "$line") == 11111111-2222-3333-4444-555555555555 ]] || \
    fail 'GPT UUID extraction failed'

mbr_line=$'Boot000D* UEFI OS\tHD(2,MBR,0x86f2a821,0x28ae00,0x84000)/\\EFI\\BOOT\\BOOTX64.EFI'
[[ $(extract_mbr_fields "$mbr_line") == '2 0x86f2a821 0x28ae00 0x84000' ]] || \
    fail 'hybrid-MBR identity extraction failed'

owned_line=$'Boot000E* Kube ArchISO USB\tHD(2,MBR,0x6a464a6e,0x28ae00,0x84000)/\\EFI\\BOOT\\BOOTX64.EFI'
[[ $(entry_label "$owned_line" 000e) == 'Kube ArchISO USB' ]] || \
    fail 'helper-owned label was not parsed exactly'
[[ $(selected_boot_line "${owned_line/Boot/boot}" 000e) == boot000E\** ]] || \
    fail 'case-insensitive entry matching failed'
pair_fixture='PATH="/dev/sda2" TYPE="part" LABEL="ARCHISO_EFI" FSTYPE="vfat"'
[[ $(pair_value "$pair_fixture" TYPE) == part ]] || fail 'lsblk TYPE pair parsing collided with FSTYPE'
[[ $(pair_value "$pair_fixture" FSTYPE) == vfat ]] || fail 'lsblk FSTYPE pair parsing failed'
[[ $(pair_value "$pair_fixture" LABEL) == ARCHISO_EFI ]] || fail 'lsblk LABEL pair parsing failed'

before_entries=$'BootCurrent: 000B\nBootOrder: 000B,000D\nBoot000B* Arch Linux\tHD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0x200000)'
after_entries="$before_entries"$'\nBoot000E* Kube ArchISO USB\tHD(2,MBR,0x6a464a6e,0x28ae00,0x84000)'
[[ $(new_entry_number "$before_entries" "$after_entries") == 000E ]] || \
    fail 'newly allocated entry was not detected'
if new_entry_number "$before_entries" "${after_entries/Boot000B/Boot000C}" >/dev/null; then
    fail 'creation accepted an unrelated entry replacement'
fi
only_entry_removed "$after_entries" "$before_entries" 000e || \
    fail 'single selected entry removal was not recognized'
if only_entry_removed "$after_entries" 'BootCurrent: 000B' 000E; then
    fail 'removing additional entries was accepted as a single-entry deletion'
fi
[[ $(boot_field "$after_entries" BootOrder) == 000B,000D ]] || fail 'BootOrder parsing failed'
boot_order_contains 000B,000D 000d || fail 'case-insensitive BootOrder membership failed'
boot_order_contains '000B, 000D' 000d || fail 'BootOrder whitespace bypassed membership'
if boot_order_contains 000B,000D 000E; then
    fail 'non-member was reported in BootOrder'
fi

(
    resolve_create_device() {
        SELECTED_DEVICE=/dev/disk/by-id/usb-fixture
        MATCHED_DISK=/dev/sda
        SELECTED_EFI_PARTITION=/dev/sda2
        SELECTED_EFI_PART_NUMBER=2
    }
    create_plan=$(create_entry plan /dev/disk/by-id/usb-fixture)
    [[ $create_plan == *'efibootmgr --create-only'* ]] || fail 'create plan omits --create-only'
    [[ $create_plan == *'BootNext will not be set'* ]] || fail 'create plan does not preserve BootNext separation'
)

owned_delete_output=$'BootCurrent: 000B\nBootNext: 000E\nBootOrder: 000B,000D\nBoot000E* Kube ArchISO USB\tHD(2,MBR,0x6a464a6e,0x28ae00,0x84000)'
(
    efibootmgr() {
        (($# == 0)) || fail 'delete plan attempted a firmware mutation'
        printf '%s\n' "$owned_delete_output"
    }
    delete_plan=$(delete_entry plan 000E)
    [[ $delete_plan == *'efibootmgr --delete-bootnext'* ]] || \
        fail 'delete plan did not plan clearing matching BootNext'
    [[ $delete_plan == *'--bootnum 000E --delete-bootnum'* ]] || \
        fail 'delete plan omitted the selected entry'
)
if (
    efibootmgr() {
        (($# == 0)) || fail 'BootCurrent refusal attempted a firmware mutation'
        printf '%s\n' "${owned_delete_output/BootCurrent: 000B/BootCurrent: 000E}"
    }
    delete_entry plan 000E >/dev/null 2>&1
); then
    fail 'delete plan accepted BootCurrent'
fi
if (
    efibootmgr() {
        (($# == 0)) || fail 'BootOrder refusal attempted a firmware mutation'
        printf '%s\n' "${owned_delete_output/BootOrder: 000B,000D/BootOrder: 000B,000D,000E}"
    }
    delete_entry plan 000E >/dev/null 2>&1
); then
    fail 'delete plan accepted a BootOrder member'
fi
if (
    efibootmgr() {
        (($# == 0)) || fail 'foreign-label refusal attempted a firmware mutation'
        printf '%s\n' "${owned_delete_output/Kube ArchISO USB/UEFI OS}"
    }
    delete_entry plan 000E >/dev/null 2>&1
); then
    fail 'delete plan accepted an entry not owned by the helper'
fi

(
    lsblk() {
        case $1 in
            -bnrpo)
                printf '%s\n' \
                    '/dev/sda disk    512110190592 512' \
                    '/dev/sda2 part 2 86f2a821-02 2665984 276824064 512'
                ;;
            -snrpo) printf '%s\n' '/dev/sda2 part' '/dev/sda disk' ;;
            -dnro) printf '%s\n' usb ;;
            *) return 1 ;;
        esac
    }
    resolve_entry 000D "$mbr_line" "$mbr_line" >/dev/null || \
        fail 'the observed ArchISO hybrid-MBR entry was rejected'
    [[ $MATCHED_PARTITION == /dev/sda2 && $MATCHED_DISK == /dev/sda ]] || \
        fail 'the ArchISO hybrid-MBR entry resolved to the wrong device'

    stale_line=${mbr_line/0x86f2a821/0x6a464a6e}
    if (resolve_entry 000D "$stale_line" "$stale_line" >/dev/null 2>&1); then
        fail 'a stale hybrid-MBR signature was accepted'
    fi
)

duplicate_output="$sample_output"$'\nBoot0007 USB duplicate'
if selected_boot_line "$duplicate_output" 0007 >/dev/null; then
    fail 'duplicate firmware entry number was accepted'
fi
if [[ -n $(extract_gpt_uuid 'Boot0007* USB device without a hard-drive path') ]]; then
    fail 'entry without GPT path produced a UUID'
fi
if [[ -n $(extract_mbr_fields 'Boot0007* USB device without a hard-drive path') ]]; then
    fail 'entry without MBR path produced an identity'
fi

if grep -qw jq "$ANSIBLE_DIR/boot-next-installer.sh"; then
    fail 'boot helper unexpectedly depends on jq'
fi

if no_arg_output=$("$ANSIBLE_DIR/boot-next-installer.sh" 2>&1); then
    fail 'no-argument invocation unexpectedly succeeded'
fi
[[ $no_arg_output == *'--create-entry'* &&
   $no_arg_output == *'--delete-entry'* &&
   $no_arg_output == *'--bootnext-entry'* ]] || \
    fail 'no-argument invocation did not print complete usage'
if grep -Eq '(^|[[:space:]])--entry([[:space:]]|$)' <<<"$no_arg_output"; then
    fail 'obsolete --entry option remains in usage'
fi

printf 'test_boot_installer_next.sh: PASS\n'
