#!/usr/bin/env bash
# Removes the k3s install + everything deployed by install.sh.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "must run as root (try: sudo $0)" >&2
    exit 1
fi

if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    /usr/local/bin/k3s-uninstall.sh
else
    echo "k3s-uninstall.sh not found; nothing to remove"
fi

rm -f /usr/local/bin/kubectl
