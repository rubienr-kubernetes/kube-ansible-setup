#!/usr/bin/env bash

# This file changes the caller's environment and therefore must be sourced.
if [[ -n ${ZSH_VERSION:-} ]]; then
    case ${ZSH_EVAL_CONTEXT:-} in
        *:file) ;;
        *)
            printf 'export.sh must be sourced: source ./export.sh\n' >&2
            exit 1
            ;;
    esac
elif [[ -n ${BASH_VERSION:-} && ${BASH_SOURCE[0]} == "$0" ]]; then
    printf 'export.sh must be sourced: source ./export.sh\n' >&2
    exit 1
fi

export ANSIBLE_HOME=/tmp/kube-ansible-home
export ANSIBLE_LOCAL_TEMP=/tmp/kube-ansible-local
