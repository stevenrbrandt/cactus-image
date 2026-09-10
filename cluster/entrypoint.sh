#!/bin/bash
# Start the per-node services. $SLURM_ROLE=controller additionally starts
# slurmctld; every node runs munged, sshd and slurmd.
set -e

log() { echo "[entrypoint $(hostname)] $*"; }

# Runtime dirs. /run is a fresh tmpfs in each container, and the spool dirs
# must not be shared between nodes, so they are created here rather than
# baked into the image.
install -d -o munge -g munge -m 0755 /run/munge
install -d -o munge -g munge -m 0700 /var/lib/munge /var/log/munge
install -d -o slurm -g slurm -m 0755 /var/spool/slurmctld /var/log/slurm
install -d -m 0755 /var/spool/slurmd
install -d -m 0755 /run/sshd

# A real cluster has a shared home directory; this one uses a docker volume
# for /home so that a build done in ~ on one node is visible from the other.
# The volume starts empty and hides the image's copy, so seed it once.
user_home="/home/${CLUSTER_USER:-sbrandt}"
if [ ! -e "$user_home/.ssh/authorized_keys" ]; then
    if [ "${SLURM_ROLE:-compute}" = controller ]; then
        log "seeding shared /home from image template"
        cp -a /opt/skel-home/. "$user_home/"
        chown -R "$(id -u "${CLUSTER_USER:-sbrandt}")":"$(id -g "${CLUSTER_USER:-sbrandt}")" "$user_home"
    else
        log "waiting for the controller to seed shared /home"
        for i in $(seq 120); do
            [ -e "$user_home/.ssh/authorized_keys" ] && break
            sleep 1
        done
    fi
fi
[ -e "$user_home/.ssh/authorized_keys" ] || {
    log "FATAL: shared /home was never seeded (no $user_home/.ssh/authorized_keys)"
    exit 1
}

log "starting munged"
gosu_munge() { setpriv --reuid=munge --regid=munge --clear-groups "$@"; }
gosu_munge /usr/sbin/munged --force
for i in $(seq 30); do munge -n >/dev/null 2>&1 && break; sleep 0.2; done
munge -n | unmunge >/dev/null || { log "FATAL: munge is not working"; exit 1; }
log "munge ok"

log "starting sshd"
/usr/sbin/sshd

# Both daemons fork and exit, so a start that "succeeded" tells us nothing.
# Confirm each is actually running and dump its log if not -- slurmd in
# particular exits immediately on a misconfiguration, and the only visible
# symptom from outside is a node stuck in NOT_RESPONDING.
start_daemon() {
    name="$1"; shift
    log "starting $name"
    "$@" || true
    for i in $(seq 40); do
        pgrep -x "$name" >/dev/null && { log "$name running"; return 0; }
        sleep 0.25
    done
    log "FATAL: $name did not stay running. Last log lines:"
    tail -20 "/var/log/slurm/$name.log" 2>&1 | sed "s/^/    /"
    exit 1
}

if [ "${SLURM_ROLE:-compute}" = controller ]; then
    start_daemon slurmctld /usr/sbin/slurmctld
fi
start_daemon slurmd /usr/sbin/slurmd

log "node ready"
exec "$@"
