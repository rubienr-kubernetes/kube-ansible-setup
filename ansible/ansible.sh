#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM=${0##*/}
readonly SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

die() {
    printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  $PROGRAM doctor
  $PROGRAM validate
  $PROGRAM inventory [HOST]
  $PROGRAM install-iso [HOST] [--connect ADDRESS]
  $PROGRAM boot-installer HOST [--connect ADDRESS] [--iso IMAGE.iso] [--live-connect ADDRESS]
  $PROGRAM bootstrap-host [HOST] [--connect ADDRESS]
  $PROGRAM configure-host [HOST] [--connect ADDRESS]
  $PROGRAM prepare-kubernetes [HOST] [--connect ADDRESS]
  $PROGRAM {-h|--help}

Commands:
  doctor          Check required tools, collections, inventory, key, and space.
  validate        Parse every active helper/playbook, then run all local
                  regression suites. This is the normal validation command.
  inventory       Show the inventory graph, or resolved variables for HOST.
  install-iso     With no HOST, list installable inventory targets. With HOST,
                  require inspection, then run the exactly gated installation.
                  --connect selects the live installer (default kube-installer).
                  The supplied address is used verbatim; reboot returns to inventory FQDN.
  boot-installer  Stage a verified built ISO on an installed node, confirm,
                  kexec into RAM, and verify identity and disk release.
                  Never formats or invokes installation. --conenct is accepted
                  as an alias for --connect. --live-connect selects the live
                  discovery name (default HOST-installer.local), not the initial host.
  bootstrap-host  With no HOST, list host targets. With HOST, create the
                  permanent administrator, install the host package baseline,
                  and retain manually gated root key SSH. Never runs kubeadm.
  configure-host  With no HOST, list host targets. With HOST, apply general
                  system and user configuration. Never configures Kubernetes.
  prepare-kubernetes
                  With no HOST, list host targets. With HOST, perform a full
                  Arch upgrade, configure and validate CRI-O, reboot, and
                  leave kubelet stopped. Never runs kubeadm init or join.

  --connect ADDRESS selects the initial connection endpoint. For install-iso
  this is the live installer; other lifecycle commands target the installed OS.
EOF
}

parse_connect() {
    connect_address=""
    if (($#)); then
        [[ $# == 2 && $1 == --connect ]] || die "expected optional --connect ADDRESS after HOST"
        [[ $2 =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || \
            die "--connect requires an IPv4 address or hostname, without user, port, or whitespace"
        connect_address=$2
    fi
}

require_unprivileged() {
    (( EUID != 0 )) || die "run this helper as your normal user, without sudo"
}

run_doctor() {
    local tool

    ansible --version
    ansible-galaxy collection list ansible.posix
    ansible-galaxy collection list community.general
    ansible-inventory --graph
    ssh-keygen -lf files/admin_authorized_keys.pub

    for tool in mkarchiso xorriso unsquashfs sha256sum; do
        printf '%-12s ' "$tool"
        command -v "$tool" || printf 'MISSING\n'
    done

    pacman -Q archiso ansible-core squashfs-tools xorriso
    unshare --map-auto --map-root-user true
    [[ -d /usr/share/archiso/configs/releng ]] || die "official releng profile is missing"
    [[ -r files/admin_authorized_keys.pub ]] || die "administrator public key is unreadable"
    df -h /tmp iso
}

run_syntax() {
    local playbook

    bash -n ansible.sh archiso.sh boot-next-installer.sh export.sh \
        roles/host_baseline/files/manage-root-ssh-access.sh \
        roles/user_environment/files/bash_profile \
        tests/test-boot-installer-next.sh || \
        die "shell-helper syntax validation failed"
    for playbook in \
        playbooks/*.yml \
        tests/test-disk-safety.yml \
        tests/test-user-environment.yml \
        tests/test-template-rendering.yml
    do
        printf '\n=== %s ===\n' "$playbook"
        ansible-playbook --syntax-check "$playbook" || \
            die "Ansible syntax validation failed: $playbook"
    done
}

run_tests() {
    local fixture

    python3 tests/test-install-connect.py || die "installer connection regression failed"
    python3 tests/test-install-firmware.py || die "installer firmware regression failed"
    python3 tests/test-boot-installer.py || die "boot-installer regression failed"

    printf '\n=== %s ===\n' tests/test-boot-installer-next.sh
    bash tests/test-boot-installer-next.sh || \
        die "shell regression failed: tests/test-boot-installer-next.sh"

    for fixture in \
        tests/test-disk-safety.yml \
        tests/test-user-environment.yml \
        tests/test-template-rendering.yml
    do
        printf '\n=== %s ===\n' "$fixture"
        ansible-playbook "$fixture" || \
            die "Ansible fixture failed: $fixture"
    done
}

show_inventory() {
    (($# <= 1)) || die "inventory accepts at most one host"
    if (($# == 1)); then
        ansible-inventory --host "$1"
    else
        ansible-inventory --graph
    fi
}

run_install_iso() (
    local target inventory_record candidate found known_hosts_file ssh_control_dir="" connect_address="" installed_address
    local -a connection_args target_args

    if (($# == 0)); then
        found=false
        printf 'Available installation targets:\n'
        while IFS= read -r candidate; do
            inventory_record=$(ansible-inventory --host "$candidate") || \
                die "could not resolve inventory host: $candidate"
            if grep -q '"install_disk"' <<<"$inventory_record" && \
               grep -q '"nvme_serial"' <<<"$inventory_record"; then
                printf '  %s\n' "$candidate"
                found=true
            fi
        done < <(
            ansible-inventory --graph kube_nodes |
                sed -n 's/^[[:space:]]*|--\([a-z0-9][a-z0-9-]*\)$/\1/p'
        )
        [[ $found == true ]] || die "inventory contains no installable kube_nodes hosts"
        printf '\nRun: %s install-iso HOST\n' "$PROGRAM"
        return 0
    fi

    target=$1
    shift
    parse_connect "$@"
    [[ $target =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || \
        die "install-iso target must be one literal lowercase hostname"

    inventory_record=$(ansible-inventory --host "$target") || \
        die "could not resolve inventory host: $target"
    grep -q '"nvme_serial"' <<<"$inventory_record" || \
        die "install-iso target is absent or lacks an installation-disk identity: $target"

    connect_address=${connect_address:-kube-installer}
    installed_address=$(python3 -c \
        'import json, sys; v=json.load(sys.stdin); print(v["final_hostname"] + "." + v["local_domain"])' \
        <<<"$inventory_record") || die "inventory requires final_hostname and local_domain"
    [[ $installed_address =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die "invalid installed hostname in inventory"

    known_hosts_file=$(mktemp /tmp/kube-live-install-known-hosts.XXXXXX) || \
        die "could not create a private installation known-hosts file"
    chmod 0600 "$known_hosts_file"
    trap 'rm -f -- "$known_hosts_file"; if [[ -n $ssh_control_dir ]]; then rm -rf -- "$ssh_control_dir"; fi' EXIT

    ssh_control_dir=$(mktemp -d /tmp/kube-install-ssh.XXXXXX) || \
        die "could not create a private installation SSH socket directory"
    chmod 0700 "$ssh_control_dir"

    connection_args=(
        "--ssh-common-args=-F /dev/null -o UserKnownHostsFile=$known_hosts_file -o HostKeyAlias=$target -o StrictHostKeyChecking=accept-new"
    )
    target_args=(
        -e "target_node=$target"
        -e ansible_user=root
        -e "installer_connect_host=$connect_address"
        -e "installer_destination_host=$installed_address"
        -e "ansible_ssh_args=-C -o ControlMaster=no -o ControlPath=none"
        -e "ansible_control_path_dir=$ssh_control_dir"
        -e 'ansible_control_path=%(directory)s/%%C'
    )
    printf 'Live connection: %s; installed connection: %s\n' "$connect_address" "$installed_address"

    printf '\n=== prerequisite: inspect live ISO target %s ===\n' "$target"
    ansible-playbook playbooks/20-inspect-live-iso.yml \
        "${connection_args[@]}" "${target_args[@]}" || \
        die "live-ISO inspection prerequisite failed; installation was not started"

    printf '\n=== destructive installation target %s ===\n' "$target"
    ansible-playbook playbooks/30-install-live-iso.yml \
        "${connection_args[@]}" "${target_args[@]}" \
        -e install_execute=true
)

run_boot_installer() (
    local target connect_address="" live_address="" iso="" run_dir inventory_record option value
    local -a images=()
    (($#)) || die "usage: boot-installer HOST [--connect ADDRESS] [--iso IMAGE.iso] [--live-connect ADDRESS]"
    target=$1
    shift
    [[ $target =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "boot-installer requires one literal inventory hostname"
    while (($#)); do
        (($# >= 2)) || die "missing value for: $1"
        option=$1
        value=$2
        case $option in
            --connect|--conenct)
                [[ -z $connect_address ]] || die "--connect may be specified only once"
                parse_connect --connect "$value"
                ;;
            --live-connect)
                [[ $value =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die "invalid live connection address"
                live_address=$value
                ;;
            --iso)
                [[ -z $iso && -n $value ]] || die "--iso requires one nonempty path"
                iso=$value
                ;;
            *) die "unknown boot-installer argument: $option" ;;
        esac
        shift 2
    done
    ((${#target} <= 53)) || die "inventory hostname is too long for the -installer suffix"
    live_address=${live_address:-${target}-installer.local}
    inventory_record=$(ansible-inventory --host "$target") || die "could not resolve inventory host: $target"
    grep -q '"nvme_serial"' <<<"$inventory_record" || die "inventory target lacks a disk identity: $target"
    if [[ -z $iso ]]; then
        shopt -s nullglob
        images=("$SCRIPT_DIR"/iso/*-kube-installer.iso)
        ((${#images[@]} == 1)) || die "expected one built installer ISO; run ./archiso.sh create if absent, or select one with --iso"
        iso=${images[0]}
    fi
    iso=$(realpath -e -- "$iso") || die "ISO not found"
    [[ -f $iso ]] || die "ISO is not a regular file"
    "$SCRIPT_DIR/archiso.sh" verify --iso "$iso" || die "ISO verification failed; no host was contacted"
    run_dir=$(mktemp -d /tmp/kube-boot-installer.XXXXXX) || die "could not create private run directory"
    chmod 0700 "$run_dir"
    trap 'rm -rf -- "$run_dir"' EXIT
    python3 - "$run_dir/vars.json" "$target" "$connect_address" "$live_address" "$iso" <<'JSON'
import json
import sys
from pathlib import Path
path, target, connect, live, iso = sys.argv[1:]
values = dict(target_node=target, ansible_user='root', boot_installer_execute=True,
              boot_installer_connect=connect, boot_installer_live_connect=live,
              boot_installer_iso=iso,
              ansible_ssh_args='-C -o ControlMaster=no -o ControlPath=none')
Path(path).write_text(json.dumps(values))
JSON
    printf 'Inventory identity: %s; initial connection: %s; live discovery: %s\n' \
        "$target" "${connect_address:-inventory address}" "$live_address"
    ansible-playbook playbooks/25-boot-installer.yml \
        "--extra-vars=@$run_dir/vars.json" \
        "--ssh-common-args=-F /dev/null -o UserKnownHostsFile=$run_dir/installed_known_hosts -o StrictHostKeyChecking=accept-new"
)

run_bootstrap_host() (
    local target target_address inventory_record candidate found known_hosts_file confirmation expected connect_address=""
    local -a connection_args target_args

    if (($# == 0)); then
        found=false
        printf 'Available node-bootstrap targets:\n'
        while IFS= read -r candidate; do
            inventory_record=$(ansible-inventory --host "$candidate") || \
                die "could not resolve inventory host: $candidate"
            if grep -q '"install_disk"' <<<"$inventory_record" && \
               grep -q '"nvme_serial"' <<<"$inventory_record"; then
                printf '  %s\n' "$candidate"
                found=true
            fi
        done < <(
            ansible-inventory --graph kube_nodes |
                sed -n 's/^[[:space:]]*|--\([a-z0-9][a-z0-9-]*\)$/\1/p'
        )
        [[ $found == true ]] || die "inventory contains no node-bootstrap targets"
        printf '\nRun: %s bootstrap-host HOST\n' "$PROGRAM"
        return 0
    fi

    target=$1
    shift
    parse_connect "$@"
    [[ $target =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || \
        die "bootstrap-host target must be one literal lowercase hostname"

    inventory_record=$(ansible-inventory --host "$target") || \
        die "could not resolve inventory host: $target"
    grep -q '"nvme_serial"' <<<"$inventory_record" || \
        die "bootstrap-host target is absent or lacks a host identity: $target"
    target_address=$(python -c \
        'import json, sys; print(json.load(sys.stdin)["ansible_host"])' \
        <<<"$inventory_record") || \
        die "could not resolve the management address for: $target"
    target_address=${connect_address:-$target_address}
    [[ -n $target_address ]] || die "empty management address for: $target"

    printf '\nThis changes packages and access policy on %s.\n' "$target"
    printf 'It verifies permanent kube SSH and installs the manual root-SSH gate.\n'
    printf 'Root public-key SSH remains enabled until you disable it manually.\n'
    printf 'It does not install or initialize Kubernetes.\n\n'
    expected="BOOTSTRAP NODE $target"
    read -r -p "Type \"$expected\" to continue: " confirmation
    [[ $confirmation == "$expected" ]] || die "confirmation did not match; nothing was changed"

    known_hosts_file=$(mktemp /tmp/kube-node-bootstrap-known-hosts.XXXXXX) || \
        die "could not create a private bootstrap known-hosts file"
    chmod 0600 "$known_hosts_file"
    trap 'rm -f -- "$known_hosts_file"' EXIT

    ssh -F /dev/null \
        -o BatchMode=yes \
        -o PasswordAuthentication=no \
        -o "UserKnownHostsFile=$known_hosts_file" \
        -o StrictHostKeyChecking=accept-new \
        "root@$target_address" /usr/bin/true || \
        die "could not authenticate root or record the host identity for: $target"

    connection_args=(
        "--ssh-common-args=-F /dev/null -o UserKnownHostsFile=$known_hosts_file -o StrictHostKeyChecking=yes"
    )
    target_args=(
        -e "target_node=$target"
        -e ansible_user=root
        -e bootstrap_node_execute=true
        -e "bootstrap_known_hosts_file=$known_hosts_file"
    )

    if [[ -n $connect_address ]]; then
        target_args+=(-e "ansible_host=$connect_address")
    fi

    ansible-playbook playbooks/40-bootstrap-host.yml \
        "${connection_args[@]}" "${target_args[@]}"
)

run_configure_host() (
    local target inventory_record candidate found known_hosts_file confirmation expected connect_address=""
    local -a connection_args target_args

    if (($# == 0)); then
        found=false
        printf 'Available node-configuration targets:\n'
        while IFS= read -r candidate; do
            inventory_record=$(ansible-inventory --host "$candidate") || \
                die "could not resolve inventory host: $candidate"
            if grep -q '"install_disk"' <<<"$inventory_record" && \
               grep -q '"nvme_serial"' <<<"$inventory_record"; then
                printf '  %s\n' "$candidate"
                found=true
            fi
        done < <(
            ansible-inventory --graph kube_nodes |
                sed -n 's/^[[:space:]]*|--\([a-z0-9][a-z0-9-]*\)$/\1/p'
        )
        [[ $found == true ]] || die "inventory contains no node-configuration targets"
        printf '\nRun: %s configure-host HOST\n' "$PROGRAM"
        return 0
    fi

    target=$1
    shift
    parse_connect "$@"
    [[ $target =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || \
        die "configure-host target must be one literal lowercase hostname"

    inventory_record=$(ansible-inventory --host "$target") || \
        die "could not resolve inventory host: $target"
    grep -q '"nvme_serial"' <<<"$inventory_record" || \
        die "configure-host target is absent or lacks a host identity: $target"

    printf '\nThis applies general system and user configuration to %s.\n' "$target"
    printf 'It does not install or configure Kubernetes.\n\n'
    expected="CONFIGURE NODE $target"
    read -r -p "Type \"$expected\" to continue: " confirmation
    [[ $confirmation == "$expected" ]] || die "confirmation did not match; nothing was changed"

    known_hosts_file=$(mktemp /tmp/kube-node-config-known-hosts.XXXXXX) || \
        die "could not create a private configuration known-hosts file"
    chmod 0600 "$known_hosts_file"
    trap 'rm -f -- "$known_hosts_file"' EXIT

    connection_args=(
        "--ssh-common-args=-F /dev/null -o UserKnownHostsFile=$known_hosts_file -o StrictHostKeyChecking=accept-new"
    )
    target_args=(
        -e "target_node=$target"
        -e ansible_user=root
        -e configure_node_execute=true
    )

    if [[ -n $connect_address ]]; then
        target_args+=(-e "ansible_host=$connect_address")
    fi

    ansible-playbook playbooks/41-configure-host.yml \
        "${connection_args[@]}" "${target_args[@]}"
)

run_prepare_kubernetes() (
    local target inventory_record candidate found known_hosts_file confirmation expected connect_address=""
    local -a connection_args target_args

    if (($# == 0)); then
        found=false
        printf 'Available Kubernetes-preparation targets:\n'
        while IFS= read -r candidate; do
            inventory_record=$(ansible-inventory --host "$candidate") || \
                die "could not resolve inventory host: $candidate"
            if grep -q '"install_disk"' <<<"$inventory_record" && \
               grep -q '"nvme_serial"' <<<"$inventory_record"; then
                printf '  %s\n' "$candidate"
                found=true
            fi
        done < <(
            ansible-inventory --graph kube_nodes |
                sed -n 's/^[[:space:]]*|--\([a-z0-9][a-z0-9-]*\)$/\1/p'
        )
        [[ $found == true ]] || die "inventory contains no Kubernetes-preparation targets"
        printf '\nRun: %s prepare-kubernetes HOST\n' "$PROGRAM"
        return 0
    fi

    target=$1
    shift
    parse_connect "$@"
    [[ $target =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || \
        die "prepare-kubernetes target must be one literal lowercase hostname"

    inventory_record=$(ansible-inventory --host "$target") || \
        die "could not resolve inventory host: $target"
    grep -q '"nvme_serial"' <<<"$inventory_record" || \
        die "prepare-kubernetes target is absent or lacks a host identity: $target"

    printf '\nThis fully upgrades Arch and prepares CRI-O on %s.\n' "$target"
    printf 'It installs current repository packages, configures the runtime, and reboots.\n'
    printf 'CRI-O will be enabled; kubelet remains stopped and disabled.\n'
    printf 'It does not run kubeadm init or join and does not configure Cilium.\n'
    printf 'Root public-key SSH must be manually enabled for this operation.\n\n'
    expected="PREPARE KUBERNETES $target"
    read -r -p "Type \"$expected\" to continue: " confirmation
    [[ $confirmation == "$expected" ]] || die "confirmation did not match; nothing was changed"

    known_hosts_file=$(mktemp /tmp/kube-kubernetes-preparation-known-hosts.XXXXXX) || \
        die "could not create a private Kubernetes-preparation known-hosts file"
    chmod 0600 "$known_hosts_file"
    trap 'rm -f -- "$known_hosts_file"' EXIT

    connection_args=(
        "--ssh-common-args=-F /dev/null -o UserKnownHostsFile=$known_hosts_file -o StrictHostKeyChecking=accept-new"
    )
    target_args=(
        -e "target_node=$target"
        -e ansible_user=root
        -e prepare_kubernetes_node_execute=true
    )

    if [[ -n $connect_address ]]; then
        target_args+=(-e "ansible_host=$connect_address")
    fi

    ansible-playbook playbooks/50-prepare-kubernetes-node.yml \
        "${connection_args[@]}" "${target_args[@]}"
)

main() {
    (($#)) || {
        usage >&2
        return 2
    }

    require_unprivileged
    source "$SCRIPT_DIR/export.sh"
    cd -- "$SCRIPT_DIR"

    case $1 in
        doctor)
            (($# == 1)) || die "doctor takes no arguments"
            run_doctor
            ;;
        validate)
            (($# == 1)) || die "validate takes no arguments"
            run_syntax
            run_tests
            printf '\nValidation succeeded: every syntax check and fixture passed.\n'
            ;;
        inventory)
            shift
            show_inventory "$@"
            ;;
        install-iso)
            shift
            run_install_iso "$@"
            ;;
        boot-installer)
            shift
            run_boot_installer "$@"
            ;;
        bootstrap-host)
            shift
            run_bootstrap_host "$@"
            ;;
        configure-host)
            shift
            run_configure_host "$@"
            ;;
        prepare-kubernetes)
            shift
            run_prepare_kubernetes "$@"
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
