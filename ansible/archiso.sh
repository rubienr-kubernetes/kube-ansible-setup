#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly PROGRAM=${0##*/}
readonly SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
VERIFIED_ISO=

die() {
    printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  $PROGRAM create
  $PROGRAM verify --iso IMAGE.iso
  $PROGRAM --verify --iso IMAGE.iso
  $PROGRAM write --iso IMAGE.iso --device /dev/disk/by-id/usb-DEVICE \\
    [--allow-fixed-usb] [--no-read-back]
  $PROGRAM {-h|--help}

Commands:
  create  Build the generic kube-installer ISO through Ansible.
  verify  Verify an ISO against its adjacent .sha256 sidecar.
  write   Validate and destructively write an explicit ISO to an explicit USB.

The write command requires a stable whole-device /dev/disk/by-id/usb-* path,
verifies the build checksum sidecar, and delegates all target validation,
confirmation, dd/fsync, sync, and read-back verification to Ansible.
EOF
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

require_unprivileged() {
    (( EUID != 0 )) || die "run this wrapper as your normal user, without sudo"
}

verify_iso_checksum() {
    local requested=$1 resolved expected listed extra actual
    local -a checksum_lines=()

    need_command realpath
    need_command sha256sum
    resolved=$(realpath -e -- "$requested") || die "ISO does not exist: $requested"
    [[ -f $resolved ]] || die "ISO is not a regular file: $resolved"
    [[ -f $resolved.sha256 ]] || die "checksum sidecar is missing: $resolved.sha256"
    mapfile -t checksum_lines <"$resolved.sha256"
    ((${#checksum_lines[@]} == 1)) || \
        die "checksum sidecar must contain exactly one record"
    read -r expected listed extra <<<"${checksum_lines[0]}"
    [[ $expected =~ ^[[:xdigit:]]{64}$ && -n $listed && -z ${extra:-} ]] || \
        die "checksum sidecar has an invalid record"
    listed=${listed#\*}
    [[ $listed == "$(basename -- "$resolved")" ]] || \
        die "checksum sidecar does not name the requested ISO"
    actual=$(sha256sum -- "$resolved")
    actual=${actual%% *}
    [[ ${actual,,} == ${expected,,} ]] || \
        die "ISO does not match its checksum sidecar"
    printf '%s: OK\n' "$listed"
    VERIFIED_ISO=$resolved
}

verify_iso() {
    local iso=

    while (($#)); do
        case $1 in
            --iso)
                (($# >= 2)) || die "--iso requires a value"
                [[ -z $iso ]] || die "--iso may be specified only once"
                iso=$2
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *) die "unknown verify argument: $1" ;;
        esac
    done
    [[ -n $iso ]] || die "verify requires --iso IMAGE.iso"
    verify_iso_checksum "$iso"
    printf 'Verified ISO: %s\n' "$VERIFIED_ISO"
}

create_iso() {
    (($# == 0)) || die "create takes no arguments"
    require_unprivileged
    need_command ansible-playbook
    cd -- "$SCRIPT_DIR"
    printf 'ArchISO artifacts will be published under: %s/iso\n' "$SCRIPT_DIR"
    exec ansible-playbook playbooks/00-build-archiso.yml
}

write_iso() {
    local iso= device= allow_fixed_usb=false read_back=true ansible_status

    while (($#)); do
        case $1 in
            --iso)
                (($# >= 2)) || die "--iso requires a value"
                iso=$2
                shift 2
                ;;
            --device)
                (($# >= 2)) || die "--device requires a value"
                device=$2
                shift 2
                ;;
            --allow-fixed-usb)
                allow_fixed_usb=true
                shift
                ;;
            --no-read-back)
                read_back=false
                shift
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *) die "unknown write argument: $1" ;;
        esac
    done

    [[ -n $iso ]] || die "write requires --iso IMAGE.iso"
    [[ -n $device ]] || die "write requires --device /dev/disk/by-id/usb-DEVICE"
    [[ $device == /dev/disk/by-id/usb-* ]] || \
        die "device must use /dev/disk/by-id/usb-*"
    [[ $device != *-part[0-9]* ]] || \
        die "device must be a whole disk, not a partition: $device"

    require_unprivileged
    need_command ansible-playbook
    verify_iso_checksum "$iso"
    iso=$VERIFIED_ISO

    local iso_hash
    iso_hash=$(sha256sum -- "$iso")
    iso_hash=${iso_hash%% *}

    cd -- "$SCRIPT_DIR"
    set +e
    ansible-playbook playbooks/10-write-archiso-usb.yml \
        --ask-become-pass \
        -e "iso_path=$iso" \
        -e "iso_sha256=$iso_hash" \
        -e "usb_device=$device" \
        -e "allow_fixed_usb=$allow_fixed_usb" \
        -e "usb_full_readback=$read_back"
    ansible_status=$?
    set -e
    return "$ansible_status"
}

main() {
    (($#)) || {
        usage >&2
        return 2
    }

    source "$SCRIPT_DIR/export.sh"

    case $1 in
        create)
            shift
            create_iso "$@"
            ;;
        verify|--verify)
            shift
            verify_iso "$@"
            ;;
        write)
            shift
            write_iso "$@"
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage >&2
            die "unknown command: $1"
            ;;
    esac
}

main "$@"
