#!/bin/bash

# Only run if Bash is interactive, root user, standard input is a TTY, and not an SSH session
if [ -n "$BASH_VERSION" ] && [ -z "$SSH_TTY" ] && [ "$(id -u)" -eq 0 ] && [ -t 0 ]; then
    if [ ! -f "/etc/firstboot_completed" ]; then
        /usr/local/bin/initial-setup.sh
    fi
fi
