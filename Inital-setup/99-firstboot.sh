#!/bin/bash

if [ -n "$BASH_VERSION" ] && [ -z "$SSH_TTY" ] && [ "$(id -u)" -eq 0 ]; then
    if [ ! -f "/etc/firstboot_completed" ]; then
        /usr/local/bin/initial-setup.sh
    fi
fi
