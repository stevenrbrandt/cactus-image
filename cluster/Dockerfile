# A single node image for a two-node SLURM test cluster.
#
# Both nodes run this same image; $SLURM_ROLE decides whether slurmctld is
# started in addition to slurmd. The point of the cluster is to exercise the
# things that can only fail on a real multi-node machine -- SLURM's PMI
# bootstrap, ssh-based launchers, and a shared filesystem -- against the
# Singularity images built elsewhere in this repo, without needing an
# allocation on a real HPC system.
#
# trixie is chosen for Slurm 24.11 (bookworm is still on 22.05) and because
# Apptainer publishes a trixie-specific package.
FROM debian:trixie-slim

ARG APPTAINER_VERSION=1.5.3
# Host uid/gid, so that files on the bind-mounted shared filesystem are owned
# by the user outside the containers as well as inside.
ARG CLUSTER_USER=sbrandt
ARG CLUSTER_UID=1168
ARG CLUSTER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update -y && apt install -y --no-install-recommends \
        slurm-wlm slurmctld slurmd slurm-client munge \
        openssh-server openssh-client \
        ca-certificates curl wget \
        iproute2 iputils-ping procps psmisc \
        sudo vim less rsync file bzip2 xz-utils \
        python3 \
    && apt clean && rm -rf /var/lib/apt/lists/*

# Apptainer provides the `singularity` command. The suid package is installed
# alongside it so that both the setuid and the unprivileged (user namespace)
# execution paths are available -- which one a given kernel/container
# combination takes is exactly the sort of thing worth being able to test.
RUN set -ex; \
    cd /tmp; \
    for pkg in apptainer apptainer-suid; do \
        curl -fsSLO "https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/${pkg}_${APPTAINER_VERSION}-trixie+_amd64.deb"; \
    done; \
    apt update -y; \
    apt install -y --no-install-recommends \
        ./apptainer_${APPTAINER_VERSION}-trixie+_amd64.deb \
        ./apptainer-suid_${APPTAINER_VERSION}-trixie+_amd64.deb; \
    apt clean; rm -rf /var/lib/apt/lists/* /tmp/*.deb; \
    if [ ! -e /usr/bin/singularity ]; then ln -s apptainer /usr/bin/singularity; fi; \
    singularity --version

# The cluster user. Same uid/gid on both nodes and on the host, so the shared
# filesystem behaves like a real one rather than a permissions puzzle.
RUN set -ex; \
    groupadd -g "$CLUSTER_GID" "$CLUSTER_USER" 2>/dev/null || true; \
    useradd -m -u "$CLUSTER_UID" -g "$CLUSTER_GID" -s /bin/bash "$CLUSTER_USER"; \
    # useradd leaves the password field as '!', which marks the account
    # LOCKED. OpenSSH with UsePAM=no refuses a locked account outright --
    # even for public-key auth, and even with correct keys and permissions,
    # reporting only "Permission denied (publickey)". '*' means "no password
    # login" without locking the account, which is what is wanted here.
    usermod -p '*' "$CLUSTER_USER"; \
    echo "$CLUSTER_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cluster; \
    chmod 0440 /etc/sudoers.d/cluster

# munge.key is generated once, at image build time, so both nodes inherit an
# identical key from the same image layer. munge refuses to start if the key
# is group/world readable.
RUN set -ex; \
    install -d -o munge -g munge -m 0700 /etc/munge /var/lib/munge /var/log/munge; \
    dd if=/dev/urandom of=/etc/munge/munge.key bs=1 count=1024 status=none; \
    chown munge:munge /etc/munge/munge.key; \
    chmod 0400 /etc/munge/munge.key

# ssh: host keys and an authorized keypair are baked in, so every node trusts
# every other node without a provisioning step. This is a disposable test
# cluster on a private docker network -- do not reuse this image anywhere real.
RUN set -ex; \
    ssh-keygen -A; \
    mkdir -p /run/sshd; \
    printf '%s\n' \
        'PermitRootLogin yes' \
        'PasswordAuthentication no' \
        'UsePAM no' \
        'AcceptEnv SINGULARITY_* APPTAINER_* SLURM_* MPI_* SINGSSH_*' \
        > /etc/ssh/sshd_config.d/cluster.conf; \
    printf '%s\n' \
        'Host *' \
        '    StrictHostKeyChecking no' \
        '    UserKnownHostsFile /dev/null' \
        '    LogLevel ERROR' \
        '    SendEnv SINGULARITY_* APPTAINER_* SLURM_* MPI_* SINGSSH_*' \
        > /etc/ssh/ssh_config.d/cluster.conf; \
    for h in /root /home/${CLUSTER_USER}; do \
        install -d -m 0700 "$h/.ssh"; \
        ssh-keygen -q -t ed25519 -N '' -f "$h/.ssh/id_ed25519"; \
        cp "$h/.ssh/id_ed25519.pub" "$h/.ssh/authorized_keys"; \
        chmod 0600 "$h/.ssh/authorized_keys"; \
    done; \
    chown -R ${CLUSTER_UID}:${CLUSTER_GID} /home/${CLUSTER_USER}/.ssh

# Prove the ssh path works at build time. Node-to-node ssh is what the
# Hydra launcher (singssh) depends on, and the failure mode above is
# indistinguishable from a key problem when first seen at runtime.
RUN set -ex; \
    /usr/sbin/sshd; \
    ok=; \
    for i in $(seq 20); do \
        if su - "$CLUSTER_USER" -c 'ssh -o BatchMode=yes -o ConnectTimeout=2 localhost true' 2>/dev/null; then ok=1; break; fi; \
        sleep 0.5; \
    done; \
    test -n "$ok" || { echo "ERROR: ssh to localhost as $CLUSTER_USER failed" >&2; exit 1; }; \
    su - "$CLUSTER_USER" -c 'ssh -o BatchMode=yes localhost hostname'; \
    ssh -o BatchMode=yes localhost hostname; \
    pkill sshd || true

# /home is a volume shared by both nodes (see docker-compose.yml), which
# masks whatever the image put there. Keep a pristine copy so the entrypoint
# can seed the volume on first boot -- otherwise the ssh keys created above
# would be invisible at runtime.
RUN cp -a /home/${CLUSTER_USER} /opt/skel-home
ENV CLUSTER_USER=${CLUSTER_USER}

COPY slurm.conf /etc/slurm/slurm.conf
COPY cgroup.conf /etc/slurm/cgroup.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
