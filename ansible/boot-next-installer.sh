#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM=${0##*/}
readonly SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly OWNED_LABEL='Kube ArchISO USB'
readonly EFI_LOADER='\EFI\BOOT\BOOTX64.EFI'
MATCHED_PARTITION=
MATCHED_DISK=
SELECTED_ENTRY_ACTIVE=false
SELECTED_DEVICE=
SELECTED_EFI_PARTITION=
SELECTED_EFI_PART_NUMBER=

die() {
    printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  $PROGRAM --list
  $PROGRAM --bootnext-entry BOOT_NUMBER {--plan|--apply}
  $PROGRAM --create-entry --device /dev/disk/by-id/usb-DEVICE {--plan|--apply}
  $PROGRAM --create-and-set-bootnext --device /dev/disk/by-id/usb-DEVICE {--plan|--apply}
  $PROGRAM --delete-entry --bootnext-entry BOOT_NUMBER {--plan|--apply}
  $PROGRAM --delete-all-entries {--plan|--apply}
  $PROGRAM {-h|--help}

With only --bootnext-entry, validate a helper-owned entry and plan or set one-shot
BootNext. --create-entry plans or creates a helper-owned entry with
efibootmgr --create-only; it never adds the entry to BootOrder and never sets
BootNext. --create-and-set-bootnext creates and verifies the helper-owned entry,
then sets that newly allocated entry as BootNext without adding it to BootOrder.
--delete-entry removes only an entry whose exact label is '$OWNED_LABEL'; it
refuses BootCurrent and BootOrder members. BOOT_NUMBER may be written as 000E
or Boot000E, in any letter case. --delete-all-entries selects every exact-label
helper-owned entry as one operation and fails before deletion if any selected
entry is BootCurrent or a BootOrder member.

Every --plan path is read-only. Every --apply path requires root and exact
confirmation. The script never changes BootOrder and never reboots.
EOF
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

normalize_entry() {
    local entry=${1^^}
    entry=${entry#BOOT}
    [[ $entry =~ ^[[:xdigit:]]{4}$ ]] || \
        die "boot entry must be exactly four hexadecimal digits, optionally prefixed by Boot"
    printf '%s\n' "$entry"
}

selected_boot_line() {
    local output=$1 entry=$2 line upper found= count=0
    entry=${entry^^}
    while IFS= read -r line; do
        upper=${line^^}
        if [[ $upper =~ ^BOOT${entry}([*[:space:]]) ]]; then
            found=$line
            ((count += 1))
        fi
    done <<<"$output"
    ((count == 1)) || return 1
    printf '%s\n' "$found"
}

entry_label() {
    local line=$1 entry=$2 prefix rest
    entry=${entry^^}
    prefix=${line:0:8}
    [[ ${prefix^^} == "BOOT$entry" ]] || return 1
    rest=${line:8}
    rest=${rest#\*}
    while [[ $rest == [[:space:]]* ]]; do
        rest=${rest:1}
    done
    [[ $rest == *$'\t'* ]] || return 1
    printf '%s\n' "${rest%%$'\t'*}"
}

entry_numbers() {
    local output=$1 line upper
    while IFS= read -r line; do
        upper=${line^^}
        if [[ $upper =~ ^BOOT([[:xdigit:]]{4})([*[:space:]]) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done <<<"$output"
}

new_entry_number() {
    local before=$1 after=$2 entry
    local -A existed=() remains=()
    local -a added=()
    while IFS= read -r entry; do
        [[ -n $entry ]] && existed[${entry^^}]=1
    done < <(entry_numbers "$before")
    while IFS= read -r entry; do
        [[ -n $entry ]] || continue
        remains[${entry^^}]=1
        [[ -v existed[${entry^^}] ]] || added+=("${entry^^}")
    done < <(entry_numbers "$after")
    for entry in "${!existed[@]}"; do
        [[ -v remains[$entry] ]] || return 1
    done
    ((${#added[@]} == 1)) || return 1
    printf '%s\n' "${added[0]}"
}

only_entry_removed() {
    local before=$1 after=$2 removed=${3^^} entry
    local -A before_set=() after_set=()
    while IFS= read -r entry; do
        [[ -n $entry ]] && before_set[${entry^^}]=1
    done < <(entry_numbers "$before")
    while IFS= read -r entry; do
        [[ -n $entry ]] && after_set[${entry^^}]=1
    done < <(entry_numbers "$after")
    [[ -v before_set[$removed] && ! -v after_set[$removed] ]] || return 1
    unset "before_set[$removed]"
    ((${#before_set[@]} == ${#after_set[@]})) || return 1
    for entry in "${!before_set[@]}"; do
        [[ -v after_set[$entry] ]] || return 1
    done
}

only_entries_removed() {
    local before=$1 after=$2 entry
    shift 2
    local -A before_set=() after_set=() removed_set=()
    while IFS= read -r entry; do
        [[ -n $entry ]] && before_set[${entry^^}]=1
    done < <(entry_numbers "$before")
    while IFS= read -r entry; do
        [[ -n $entry ]] && after_set[${entry^^}]=1
    done < <(entry_numbers "$after")
    for entry in "$@"; do
        entry=${entry^^}
        [[ -v before_set[$entry] && ! -v after_set[$entry] ]] || return 1
        removed_set[$entry]=1
        unset "before_set[$entry]"
    done
    ((${#removed_set[@]} == $#)) || return 1
    ((${#before_set[@]} == ${#after_set[@]})) || return 1
    for entry in "${!before_set[@]}"; do
        [[ -v after_set[$entry] ]] || return 1
    done
}

owned_entry_numbers() {
    local output=$1 line upper entry label
    while IFS= read -r line; do
        upper=${line^^}
        [[ $upper =~ ^BOOT([[:xdigit:]]{4})([*[:space:]]) ]] || continue
        entry=${BASH_REMATCH[1]}
        label=$(entry_label "$line" "$entry") || \
            die "Boot$entry label could not be parsed safely"
        [[ $label == "$OWNED_LABEL" ]] && printf '%s\n' "$entry"
    done <<<"$output"
}

boot_field() {
    local output=$1 wanted=${2^^} line key value found= count=0
    while IFS= read -r line; do
        key=${line%%:*}
        [[ ${key^^} == "$wanted" ]] || continue
        value=${line#*:}
        value=${value#${value%%[![:space:]]*}}
        found=$value
        ((count += 1))
    done <<<"$output"
    ((count == 1)) || return 1
    printf '%s\n' "$found"
}

boot_order_contains() {
    local order=${1^^} entry=${2^^} item
    local -a items=()
    IFS=, read -r -a items <<<"$order"
    for item in "${items[@]}"; do
        item=${item//[[:space:]]/}
        [[ $item == "$entry" ]] && return 0
    done
    return 1
}

extract_gpt_uuid() {
    local line=$1
    sed -nE 's/.*HD\([^,]+,[Gg][Pp][Tt],([^,]+),.*/\1/p' <<<"$line"
}

extract_mbr_fields() {
    local line=$1
    sed -nE \
        's/.*HD\(([^,]+),[Mm][Bb][Rr],([^,]+),([^,]+),([^\)]+)\).*/\1 \2 \3 \4/p' \
        <<<"$line"
}

pair_value() {
    local line=$1 key=$2
    sed -nE \
        "s/(^|.*[[:space:]])${key}=\"([^\"]*)\"([[:space:]].*|$)/\\2/p" \
        <<<"$line"
}

print_inventory() {
    printf '%s\n' 'Block-device inventory:'
    lsblk -e 7 -o \
        NAME,PATH,TYPE,SIZE,TRAN,MODEL,SERIAL,PARTN,START,LOG-SEC,FSTYPE,LABEL,PARTLABEL,PARTTYPE,PARTUUID,MOUNTPOINTS
    printf '\n%s\n' 'UEFI boot entries:'
    efibootmgr
}

resolve_entry() {
    local entry=$1 boot_output=$2 plain_output=$3 required_label=${4:-}
    local line plain_line label guid mbr_fields path type partn partuuid start
    local size_bytes logical_sector disk transport identity
    local mbr_part mbr_signature mbr_start mbr_size expected_partuuid
    local mbr_part_decimal mbr_start_decimal mbr_size_decimal expected_start expected_size
    local -a matching_partitions=() parent_disks=()

    line=$(selected_boot_line "$boot_output" "$entry") || \
        die "Boot$entry does not identify exactly one firmware entry"
    plain_line=$(selected_boot_line "$plain_output" "$entry") || \
        die "Boot$entry is missing from the ordinary firmware listing"
    label=$(entry_label "$line" "$entry") || \
        die "Boot$entry label could not be parsed safely"
    if [[ -n $required_label && $label != "$required_label" ]]; then
        die "Boot$entry label is '$label', expected exact helper-owned label '$required_label'"
    fi
    [[ ${line^^} == "BOOT${entry^^}*"* ]] && SELECTED_ENTRY_ACTIVE=true || \
        SELECTED_ENTRY_ACTIVE=false

    guid=$(extract_gpt_uuid "$line")
    if [[ -n $guid ]]; then
        identity="GPT PARTUUID $guid"
        while read -r path type partn partuuid start size_bytes logical_sector; do
            [[ $type == part && -n ${partuuid:-} ]] || continue
            [[ ${partuuid,,} == "${guid,,}" ]] && matching_partitions+=("$path")
        done < <(lsblk -bnrpo PATH,TYPE,PARTN,PARTUUID,START,SIZE,LOG-SEC -e 7)
    else
        mbr_fields=$(extract_mbr_fields "$line")
        [[ -n $mbr_fields ]] || \
            die "Boot$entry has no supported GPT or MBR hard-drive identity"
        read -r mbr_part mbr_signature mbr_start mbr_size <<<"$mbr_fields"
        [[ $mbr_part =~ ^[0-9]+$ ]] || die "Boot$entry has an invalid MBR partition number"
        [[ $mbr_signature =~ ^0[xX][[:xdigit:]]{8}$ ]] || \
            die "Boot$entry has an invalid MBR disk signature"
        [[ $mbr_start =~ ^(0[xX][[:xdigit:]]+|[0-9]+)$ ]] || \
            die "Boot$entry has an invalid MBR start sector"
        [[ $mbr_size =~ ^(0[xX][[:xdigit:]]+|[0-9]+)$ ]] || \
            die "Boot$entry has an invalid MBR partition size"
        mbr_part_decimal=$((10#$mbr_part))
        mbr_start_decimal=$((mbr_start))
        mbr_size_decimal=$((mbr_size))
        mbr_signature=${mbr_signature#0x}
        mbr_signature=${mbr_signature#0X}
        printf -v expected_partuuid '%s-%02x' "${mbr_signature,,}" "$mbr_part_decimal"
        identity="MBR PARTUUID $expected_partuuid, start $mbr_start_decimal, size $mbr_size_decimal sectors"

        while read -r path type partn partuuid start size_bytes logical_sector; do
            [[ $type == part && -n ${partuuid:-} ]] || continue
            [[ ${partuuid,,} == "$expected_partuuid" ]] || continue
            [[ $partn == "$mbr_part_decimal" ]] || continue
            [[ $logical_sector =~ ^[0-9]+$ && $logical_sector -gt 0 ]] || continue
            expected_start=$((mbr_start_decimal * logical_sector / 512))
            expected_size=$((mbr_size_decimal * logical_sector))
            [[ $start == "$expected_start" && $size_bytes == "$expected_size" ]] || continue
            matching_partitions+=("$path")
        done < <(lsblk -bnrpo PATH,TYPE,PARTN,PARTUUID,START,SIZE,LOG-SEC -e 7)
    fi
    ((${#matching_partitions[@]} == 1)) || \
        die "Boot$entry identity '$identity' matched ${#matching_partitions[@]} visible partitions"
    path=${matching_partitions[0]}

    while read -r disk type; do
        [[ $type == disk ]] && parent_disks+=("$disk")
    done < <(lsblk -snrpo PATH,TYPE -- "$path")
    ((${#parent_disks[@]} == 1)) || die "cannot resolve one parent disk for $path"
    disk=${parent_disks[0]}
    transport=$(lsblk -dnro TRAN -- "$disk")
    transport=${transport//[[:space:]]/}

    MATCHED_PARTITION=$path
    MATCHED_DISK=$disk
    printf '\nSelected entry: %s\n' "$plain_line"
    printf 'Validated label: %s\n' "$label"
    printf 'Partition match: %s -> %s\n' "$identity" "$path"
    printf 'Parent disk: %s (transport: %s)\n' "$disk" "${transport:-unknown}"
    [[ $SELECTED_ENTRY_ACTIVE == true ]] || die "Boot$entry is inactive"
    [[ $transport == usb ]] || \
        die "refusing Boot$entry because its parent disk is not reported as USB"
}

resolve_create_device() {
    local requested=$1 disk type transport line path label fstype partn
    local -a candidates=()
    [[ $requested == /dev/disk/by-id/usb-* ]] || \
        die "--device must be a stable /dev/disk/by-id/usb-* path"
    [[ $requested != *-part[0-9]* ]] || die "--device must identify a whole disk, not a partition"
    [[ -e $requested ]] || die "USB device path does not exist: $requested"
    disk=$(readlink -e -- "$requested") || die "cannot resolve USB device: $requested"
    [[ -b $disk ]] || die "resolved USB device is not a block device: $disk"
    type=$(lsblk -dnro TYPE -- "$disk")
    [[ $type == disk ]] || die "resolved USB device is not a whole disk: $disk"
    transport=$(lsblk -dnro TRAN -- "$disk")
    transport=${transport//[[:space:]]/}
    [[ $transport == usb ]] || die "resolved device is not reported as USB: $disk"

    while IFS= read -r line; do
        [[ $(pair_value "$line" TYPE) == part ]] || continue
        label=$(pair_value "$line" LABEL)
        fstype=$(pair_value "$line" FSTYPE)
        [[ $label == ARCHISO_EFI && $fstype == vfat ]] || continue
        path=$(pair_value "$line" PATH)
        [[ -n $path ]] && candidates+=("$path")
    done < <(lsblk -P -p -o PATH,TYPE,LABEL,FSTYPE -- "$disk")
    ((${#candidates[@]} == 1)) || \
        die "expected exactly one vfat ARCHISO_EFI partition on $requested; found ${#candidates[@]}"
    path=${candidates[0]}
    partn=$(lsblk -dnro PARTN -- "$path")
    partn=${partn//[[:space:]]/}
    [[ $partn =~ ^[0-9]+$ ]] || die "cannot determine partition number for $path"

    SELECTED_DEVICE=$requested
    MATCHED_DISK=$disk
    SELECTED_EFI_PARTITION=$path
    SELECTED_EFI_PART_NUMBER=$partn
    printf '\nSelected USB disk: %s -> %s\n' "$requested" "$disk"
    printf 'ArchISO EFI partition: %s (partition %s, label ARCHISO_EFI)\n' "$path" "$partn"
}

show_boot_state() {
    local output=$1
    printf '\n%s\n' 'Current firmware boot state:'
    while IFS= read -r line; do
        case ${line%%:*} in
            BootCurrent|BootNext|BootOrder) printf '%s\n' "$line" ;;
        esac
    done <<<"$output"
}

plan_create_command() {
    printf "efibootmgr --create-only --disk %q --part %q --label %q --loader %q\n" \
        "$MATCHED_DISK" "$SELECTED_EFI_PART_NUMBER" "$OWNED_LABEL" "$EFI_LOADER"
}

create_entry() {
    local action=$1 device=$2 set_bootnext=${3:-false}
    local before after verbose_after new_entry final verified_next order_final
    local order_before order_after next_before next_after confirmation expected
    resolve_create_device "$device"
    printf '\nPlanned helper-owned entry creation:\n  '
    plan_create_command
    if [[ $set_bootnext == true ]]; then
        printf 'Then set BootNext to the newly allocated and verified Boot#### entry.\n'
    else
        printf 'The entry will not be added to BootOrder and BootNext will not be set.\n'
    fi
    printf 'BootOrder will not be changed and the machine will not be rebooted.\n'
    [[ $action == plan ]] && {
        printf 'Plan only: UEFI variables were not changed.\n'
        return 0
    }

    ((EUID == 0)) || die "--apply must be run as root"
    before=$(efibootmgr)
    order_before=$(boot_field "$before" BootOrder) || die "cannot determine BootOrder before creation"
    next_before=$(boot_field "$before" BootNext || true)
    if [[ $set_bootnext == true ]]; then
        expected="CREATE KUBE ARCHISO ENTRY AND SET BOOTNEXT FOR $SELECTED_EFI_PARTITION ON $SELECTED_DEVICE"
    else
        expected="CREATE KUBE ARCHISO ENTRY FOR $SELECTED_EFI_PARTITION ON $SELECTED_DEVICE"
    fi
    read -r -p "Type \"$expected\" to continue: " confirmation </dev/tty || \
        die "confirmation could not be read"
    [[ $confirmation == "$expected" ]] || die "confirmation did not match; no entry was created"

    efibootmgr --create-only --disk "$MATCHED_DISK" --part "$SELECTED_EFI_PART_NUMBER" \
        --label "$OWNED_LABEL" --loader "$EFI_LOADER"
    after=$(efibootmgr)
    verbose_after=$(efibootmgr -v)
    new_entry=$(new_entry_number "$before" "$after") || \
        die "creation did not produce exactly one new Boot#### entry"
    order_after=$(boot_field "$after" BootOrder) || die "cannot determine BootOrder after creation"
    next_after=$(boot_field "$after" BootNext || true)
    [[ $order_after == "$order_before" ]] || die "BootOrder changed unexpectedly during create-only"
    [[ $next_after == "$next_before" ]] || die "BootNext changed unexpectedly during entry creation"
    resolve_entry "$new_entry" "$verbose_after" "$after" "$OWNED_LABEL"
    [[ $MATCHED_PARTITION == "$SELECTED_EFI_PARTITION" && $MATCHED_DISK == "$(readlink -e -- "$SELECTED_DEVICE")" ]] || \
        die "new Boot$new_entry does not resolve to the selected ArchISO EFI partition"
    if [[ $set_bootnext == true ]]; then
        efibootmgr --bootnext "$new_entry"
        final=$(efibootmgr)
        verified_next=$(boot_field "$final" BootNext || true)
        verified_next=${verified_next//[[:space:]]/}
        [[ ${verified_next^^} == "$new_entry" ]] || \
            die "efibootmgr returned successfully but BootNext did not verify as $new_entry"
        order_final=$(boot_field "$final" BootOrder) || \
            die "cannot determine BootOrder after setting BootNext"
        [[ $order_final == "$order_before" ]] || \
            die "BootOrder changed unexpectedly while creating the entry and setting BootNext"
        printf 'Created and verified helper-owned entry Boot%s and set it as BootNext. Reboot remains a separate manual action.\n' "$new_entry"
    else
        printf 'Created and verified helper-owned entry Boot%s. BootNext remains unchanged.\n' "$new_entry"
    fi
}

delete_entry() {
    local action=$1 entry=$2 before line label current order order_after next
    local confirmation expected after cleared_next
    before=$(efibootmgr)
    line=$(selected_boot_line "$before" "$entry") || die "Boot$entry does not exist exactly once"
    label=$(entry_label "$line" "$entry") || die "Boot$entry label could not be parsed safely"
    [[ $label == "$OWNED_LABEL" ]] || \
        die "refusing to delete Boot$entry with label '$label'; expected '$OWNED_LABEL'"
    current=$(boot_field "$before" BootCurrent) || die "cannot determine BootCurrent"
    order=$(boot_field "$before" BootOrder) || die "cannot determine BootOrder"
    next=$(boot_field "$before" BootNext || true)
    current=${current//[[:space:]]/}
    next=${next//[[:space:]]/}
    [[ ${current^^} != "$entry" ]] || die "refusing to delete current boot entry Boot$entry"
    ! boot_order_contains "$order" "$entry" || \
        die "refusing to delete Boot$entry because it is present in BootOrder"

    printf '\nSelected helper-owned entry: %s\n' "$line"
    if [[ ${next^^} == "$entry" ]]; then
        printf 'Planned prerequisite: efibootmgr --delete-bootnext\n'
    fi
    printf 'Planned deletion: efibootmgr --bootnum %s --delete-bootnum\n' "$entry"
    [[ $action == plan ]] && {
        printf 'Plan only: UEFI variables were not changed.\n'
        return 0
    }

    ((EUID == 0)) || die "--apply must be run as root"
    expected="DELETE KUBE ARCHISO ENTRY Boot$entry"
    read -r -p "Type \"$expected\" to continue: " confirmation </dev/tty || \
        die "confirmation could not be read"
    [[ $confirmation == "$expected" ]] || die "confirmation did not match; nothing was deleted"
    if [[ ${next^^} == "$entry" ]]; then
        efibootmgr --delete-bootnext
        after=$(efibootmgr)
        cleared_next=$(boot_field "$after" BootNext || true)
        [[ ${cleared_next^^} != "$entry" ]] || \
            die "BootNext still references Boot$entry after clearing"
    fi
    efibootmgr --bootnum "$entry" --delete-bootnum
    after=$(efibootmgr)
    only_entry_removed "$before" "$after" "$entry" || \
        die "firmware entry set did not change by only the removal of Boot$entry"
    order_after=$(boot_field "$after" BootOrder) || die "cannot determine BootOrder after deletion"
    [[ $order_after == "$order" ]] || \
        die "BootOrder changed unexpectedly during deletion"
    printf 'Deleted helper-owned entry Boot%s. BootOrder remains unchanged.\n' "$entry"
}

delete_all_entries() {
    local action=$1 before current order next entry after order_after cleared_next
    local confirmation expected entry_words owned_output clear_next=false
    local -a entries=()
    before=$(efibootmgr)
    owned_output=$(owned_entry_numbers "$before") || \
        die "could not safely enumerate helper-owned entries"
    [[ -n $owned_output ]] || die "no entries have the exact helper-owned label '$OWNED_LABEL'"
    mapfile -t entries <<<"$owned_output"
    current=$(boot_field "$before" BootCurrent) || die "cannot determine BootCurrent"
    order=$(boot_field "$before" BootOrder) || die "cannot determine BootOrder"
    next=$(boot_field "$before" BootNext || true)
    current=${current//[[:space:]]/}
    next=${next//[[:space:]]/}

    for entry in "${entries[@]}"; do
        [[ ${current^^} != "$entry" ]] || \
            die "refusing bulk deletion because Boot$entry is BootCurrent"
        ! boot_order_contains "$order" "$entry" || \
            die "refusing bulk deletion because Boot$entry is present in BootOrder"
        [[ ${next^^} != "$entry" ]] || clear_next=true
    done

    printf '\nSelected helper-owned entries for deletion:\n'
    printf '  Boot%s\n' "${entries[@]}"
    if [[ $clear_next == true ]]; then
        printf 'Planned prerequisite: efibootmgr --delete-bootnext\n'
    fi
    for entry in "${entries[@]}"; do
        printf 'Planned deletion: efibootmgr --bootnum %s --delete-bootnum\n' "$entry"
    done
    [[ $action == plan ]] && {
        printf 'Plan only: UEFI variables were not changed.\n'
        return 0
    }

    ((EUID == 0)) || die "--apply must be run as root"
    printf -v entry_words 'Boot%s ' "${entries[@]}"
    entry_words=${entry_words% }
    expected="DELETE ALL KUBE ARCHISO ENTRIES $entry_words"
    read -r -p "Type \"$expected\" to continue: " confirmation </dev/tty || \
        die "confirmation could not be read"
    [[ $confirmation == "$expected" ]] || die "confirmation did not match; nothing was deleted"

    if [[ $clear_next == true ]]; then
        efibootmgr --delete-bootnext
        after=$(efibootmgr)
        cleared_next=$(boot_field "$after" BootNext || true)
        [[ ${cleared_next^^} != "${next^^}" ]] || \
            die "BootNext still references Boot$next after clearing"
    fi
    for entry in "${entries[@]}"; do
        efibootmgr --bootnum "$entry" --delete-bootnum
    done
    after=$(efibootmgr)
    only_entries_removed "$before" "$after" "${entries[@]}" || \
        die "firmware entry set did not change by exactly the selected removals"
    order_after=$(boot_field "$after" BootOrder) || die "cannot determine BootOrder after deletion"
    [[ $order_after == "$order" ]] || \
        die "BootOrder changed unexpectedly during bulk deletion"
    printf 'Deleted %d helper-owned entries. BootOrder remains unchanged.\n' "${#entries[@]}"
}

set_bootnext() {
    local action=$1 entry=$2 plain verbose confirmation expected verified verified_next
    local order_before order_after
    plain=$(efibootmgr)
    verbose=$(efibootmgr -v)
    resolve_entry "$entry" "$verbose" "$plain" "$OWNED_LABEL"
    show_boot_state "$plain"
    printf '\nPlanned one-shot change: efibootmgr --bootnext %s\n' "$entry"
    printf 'The machine will not be rebooted by this script.\n'
    [[ $action == plan ]] && {
        printf 'Plan only: UEFI variables were not changed.\n'
        return 0
    }

    ((EUID == 0)) || die "--apply must be run as root"
    order_before=$(boot_field "$plain" BootOrder) || die "cannot determine BootOrder"
    expected="SET BOOTNEXT Boot$entry $MATCHED_PARTITION ON $MATCHED_DISK"
    read -r -p "Type \"$expected\" to continue: " confirmation </dev/tty || \
        die "confirmation could not be read"
    [[ $confirmation == "$expected" ]] || die "confirmation did not match; BootNext was not changed"
    efibootmgr --bootnext "$entry"
    verified=$(efibootmgr)
    verified_next=$(boot_field "$verified" BootNext || true)
    verified_next=${verified_next//[[:space:]]/}
    [[ ${verified_next^^} == "$entry" ]] || \
        die "efibootmgr returned successfully but BootNext did not verify as $entry"
    order_after=$(boot_field "$verified" BootOrder) || die "cannot determine BootOrder after setting BootNext"
    [[ $order_after == "$order_before" ]] || die "BootOrder changed unexpectedly while setting BootNext"
    printf 'Verified BootNext: %s. Reboot remains a separate manual action.\n' "$entry"
}

main() {
    local action= operation=bootnext entry= device=
    if (($# == 0)); then
        usage >&2
        printf '\n%s: error: choose --list, --plan, or --apply\n' "$PROGRAM" >&2
        return 2
    fi
    while (($#)); do
        case $1 in
            --list)
                [[ -z $action ]] || die "choose exactly one of --list, --plan, or --apply"
                action=list
                shift
                ;;
            --plan|--apply)
                [[ -z $action ]] || die "choose exactly one of --list, --plan, or --apply"
                action=${1#--}
                shift
                ;;
            --create-entry|--create-and-set-bootnext|--delete-entry|--delete-all-entries)
                [[ $operation == bootnext ]] || die "choose only one entry operation"
                operation=${1#--}
                shift
                ;;
            --bootnext-entry)
                (($# >= 2)) || die "--bootnext-entry requires a Boot#### number"
                [[ -z $entry ]] || die "--bootnext-entry may be specified only once"
                entry=$(normalize_entry "$2")
                shift 2
                ;;
            --device)
                (($# >= 2)) || die "--device requires a stable USB whole-disk path"
                [[ -z $device ]] || die "--device may be specified only once"
                device=$2
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    [[ -n $action ]] || die "choose --list, --plan, or --apply"
    if [[ $action == list ]]; then
        [[ $operation == bootnext && -z $entry && -z $device ]] || \
            die "--list does not accept an entry operation, --bootnext-entry, or --device"
    elif [[ $operation == create-entry || $operation == create-and-set-bootnext ]]; then
        [[ -n $device && -z $entry ]] || \
            die "the create operation requires --device and forbids --bootnext-entry"
    elif [[ $operation == delete-all-entries ]]; then
        [[ -z $entry && -z $device ]] || \
            die "--delete-all-entries forbids --bootnext-entry and --device"
    else
        [[ -n $entry && -z $device ]] || \
            die "this operation requires --bootnext-entry and forbids --device"
    fi

    need_command efibootmgr
    need_command lsblk
    need_command sed
    [[ -d /sys/firmware/efi ]] || die "the running system was not booted in UEFI mode"
    print_inventory
    [[ $action == list ]] && return 0

    case $operation in
        bootnext) set_bootnext "$action" "$entry" ;;
        create-entry)
            need_command readlink
            create_entry "$action" "$device" false
            ;;
        create-and-set-bootnext)
            need_command readlink
            create_entry "$action" "$device" true
            ;;
        delete-entry) delete_entry "$action" "$entry" ;;
        delete-all-entries) delete_all_entries "$action" ;;
        *) die "internal error: unsupported operation $operation" ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
