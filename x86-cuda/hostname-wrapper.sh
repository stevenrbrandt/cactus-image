#!/bin/sh
#
# hostname(1) shim -- makes the *command* report
# "<image-name>-<real hostname>" so a shell, a Makefile, or a SimFactory
# machine-detection rule can tell it is running inside this image.
#
# Installed as /usr/local/bin/hostname, which precedes /usr/bin on PATH.
#
# SCOPE, and it is deliberately narrow: this changes only what the
# `hostname` command prints. It does NOT change gethostname(2), so
# socket.gethostname(), os.uname(), MPI's own node names, and Slurm all
# still see the real host. That is on purpose -- rewriting the real UTS
# name would need a private namespace Singularity does not give an
# unprivileged job, and would misdirect MPI rank placement if it did.
# For programmatic detection prefer $CACTUS_IMAGE_NAME, or the existence
# of this file.
#
# The prefix comes from $CACTUS_IMAGE_NAME, with the same default baked in
# literally, so that a job launched with `singularity --cleanenv` -- which
# strips the image's environment -- still gets the prefixed name.
#
# Only the plain display forms are prefixed. Anything that sets the
# hostname, or that prints something which is not a hostname (-i/-I give
# addresses, -d a domain), is passed through to the real binary untouched:
# prefixing those would produce a string that is simply wrong.
set -u

prefix="${CACTUS_IMAGE_NAME:-cactus-cuda}"

real_hostname() {
    if [ -x /usr/bin/hostname ]; then
        /usr/bin/hostname "$@"
    else
        # Busybox-less fallback; /proc is always present under Singularity.
        cat /proc/sys/kernel/hostname
    fi
}

case "${1:-}" in
    "")                     printf '%s-%s\n' "$prefix" "$(real_hostname)" ;;
    -s|--short)             printf '%s-%s\n' "$prefix" "$(real_hostname -s)" ;;
    -f|--fqdn|--long)       printf '%s-%s\n' "$prefix" "$(real_hostname -f)" ;;
    *)                      exec /usr/bin/hostname "$@" ;;
esac
