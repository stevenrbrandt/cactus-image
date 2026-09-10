/*
 * pmi-test.c -- minimal 2-rank MPI ping-pong.
 *
 * Purpose: a small, standalone way to check -- on a *specific* HPC site --
 * whether this image's bundled MPI (OpenMPI or MPICH; see cactus-openmpi.cfg
 * / cactus-mpich.cfg) can actually be bootstrapped by that site's process
 * manager (Slurm's PMI2 or PMIx) and successfully pass a message between
 * two ranks, *before* sinking time into a full Cactus build/run on that
 * machine. It deliberately does nothing else -- no Cactus, no CarpetX, no
 * ExternalLibraries -- so a failure here isolates the problem to the
 * MPI/PMI/launcher layer.
 *
 * Typical use, once this container is available via Singularity/Apptainer
 * on the target machine:
 *
 *   srun --mpi=pmi2  -N2 -n2 singularity exec image.sif /opt/cactus-deps/bin/pmi-test-mpich
 *   srun --mpi=pmix  -N2 -n2 singularity exec image.sif /opt/cactus-deps/bin/pmi-test-openmpi
 *
 * Do NOT add `singularity exec --cleanenv` here. srun hands the PMI
 * handshake to each task purely through environment variables (the PMI_,
 * PMIX_ and SLURM_ families), and --cleanenv drops them before the
 * container sees them -- so every task initializes as its own singleton
 * MPI_COMM_WORLD of size 1, and this test fails with "got 1" on each rank.
 * Same symptom for both MPI flavors, which is the giveaway that it's the
 * launch line rather than the MPI itself. (--nv and --bind are fine; it is
 * specifically --cleanenv.)
 *
 * (or plain `mpirun -np 2 ...` / `mpiexec -np 2 ...` inside the container,
 * for a purely internal sanity check that doesn't exercise the site's PMI
 * bridge at all). Try both --mpi= values and both binaries if you don't
 * know which PMI variant the site's Slurm exposes -- see `srun --mpi=list`.
 *
 * Requires exactly 2 ranks by design (see cactus-build-ref.md's own
 * emphasis on multi-node launch as the thing that actually needs PMI to
 * work, as opposed to a single-rank smoke test that would pass even with
 * PMI completely broken).
 */
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Environment variables that carry the PMI handshake from the launcher into
 * each task. If MPI came up as a singleton but the launcher clearly started
 * more than one task, what is (and isn't) set here is the whole diagnosis. */
static const char *const pmi_vars[] = {
    /* Slurm's view of the step -- set even when PMI itself isn't working */
    "SLURM_JOB_ID", "SLURM_NTASKS", "SLURM_STEP_NUM_TASKS", "SLURM_PROCID",
    /* PMI-1/PMI-2 (what `srun --mpi=pmi2` provides; MPICH speaks this) */
    "PMI_RANK", "PMI_SIZE", "PMI_FD", "PMI_JOBID",
    /* PMIx (what `srun --mpi=pmix` provides; OpenMPI speaks this) */
    "PMIX_RANK", "PMIX_NAMESPACE", "PMIX_SERVER_URI", "PMIX_SECURITY_MODE",
    /* OpenMPI's own, set once its bootstrap succeeded */
    "OMPI_COMM_WORLD_RANK", "OMPI_COMM_WORLD_SIZE",
    NULL};

static void report_bootstrap_env(void) {
  fprintf(stderr, "pmi-test: PMI-related environment as seen inside the container:\n");
  int any = 0;
  for (const char *const *v = pmi_vars; *v; ++v) {
    const char *val = getenv(*v);
    if (val) {
      fprintf(stderr, "    %-22s = %s\n", *v, val);
      any = 1;
    }
  }
  if (!any) {
    fprintf(stderr, "    (none set -- nothing from the launcher reached this process)\n");
  }
}

int main(int argc, char **argv) {
  /* Unbuffered, and printed BEFORE MPI_Init, so that a hang is immediately
   * localized: if you see this line but never "MPI_Init returned", the
   * process is stuck inside MPI_Init -- i.e. it is failing to complete the
   * PMI/PMIx handshake with the launcher (wrong or mismatched --mpi=
   * plugin, or a PMIx client/server version mismatch), rather than failing
   * later in the actual message exchange. A hang with no output at all
   * means the process never got as far as running this binary. */
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);

  char prehost[256] = "unknown";
  gethostname(prehost, sizeof(prehost) - 1);
  const char *procid = getenv("SLURM_PROCID");
  fprintf(stderr, "pmi-test: starting on %s (SLURM_PROCID=%s), calling MPI_Init...\n",
          prehost, procid ? procid : "unset");

  MPI_Init(&argc, &argv);

  int rank, size;
  MPI_Comm_rank(MPI_COMM_WORLD, &rank);
  MPI_Comm_size(MPI_COMM_WORLD, &size);

  fprintf(stderr, "pmi-test: MPI_Init returned on %s -- rank %d of %d\n",
          prehost, rank, size);

  char host[MPI_MAX_PROCESSOR_NAME];
  int host_len;
  MPI_Get_processor_name(host, &host_len);

  if (size != 2) {
    /* Deliberately printed by EVERY rank, not just rank 0: when PMI
     * bootstrap fails, each task becomes rank 0 of its own size-1 world, so
     * seeing this message N times is itself the symptom. */
    fprintf(stderr,
            "pmi-test: FAIL -- this test requires exactly 2 MPI ranks, got %d "
            "(I am rank %d on %s).\n",
            size, rank, host);

    const char *ntasks = getenv("SLURM_NTASKS");
    if (ntasks == NULL) {
      ntasks = getenv("SLURM_STEP_NUM_TASKS");
    }
    if (size == 1 && ntasks != NULL && atoi(ntasks) > 1) {
      fprintf(stderr,
              "\n"
              "pmi-test: the launcher started %s tasks, but MPI came up as a\n"
              "singleton (size 1). That means the PMI bootstrap did not happen:\n"
              "the tasks ran as separate 1-rank jobs instead of joining one\n"
              "MPI_COMM_WORLD. Usual causes, in order:\n"
              "  1. `singularity exec --cleanenv` -- srun passes the PMI\n"
              "     handshake purely through environment variables, and\n"
              "     --cleanenv drops them before the container sees them.\n"
              "     Drop --cleanenv (or re-export the vars listed below).\n"
              "  2. No `--mpi=` selector, or the wrong one. MPICH needs\n"
              "     `srun --mpi=pmi2`; OpenMPI needs `srun --mpi=pmix`.\n"
              "     `srun --mpi=list` shows what this site actually offers.\n"
              "  3. The site's PMI/PMIx server version can't talk to this\n"
              "     container's client (mostly a PMIx-vs-PMIx concern).\n"
              "\n",
              ntasks);
    }
    report_bootstrap_env();
    MPI_Abort(MPI_COMM_WORLD, 1);
    return 1;
  }

  const int tag = 42;
  if (rank == 0) {
    const char ping[] = "ping from rank 0";
    char pong[64] = {0};

    MPI_Send(ping, (int)sizeof(ping), MPI_CHAR, 1, tag, MPI_COMM_WORLD);
    MPI_Recv(pong, (int)sizeof(pong), MPI_CHAR, 1, tag, MPI_COMM_WORLD,
             MPI_STATUS_IGNORE);

    printf("rank 0 (%s): sent \"%s\", received \"%s\"\n", host, ping, pong);
    if (strcmp(pong, "pong from rank 1") == 0) {
      printf("PMI-TEST: PASS -- 2-rank message exchange succeeded\n");
    } else {
      printf("PMI-TEST: FAIL -- unexpected reply content\n");
      MPI_Abort(MPI_COMM_WORLD, 2);
    }
  } else {
    char ping[64] = {0};
    const char pong[] = "pong from rank 1";

    MPI_Recv(ping, (int)sizeof(ping), MPI_CHAR, 0, tag, MPI_COMM_WORLD,
             MPI_STATUS_IGNORE);
    MPI_Send(pong, (int)sizeof(pong), MPI_CHAR, 0, tag, MPI_COMM_WORLD);

    printf("rank 1 (%s): received \"%s\", sent \"%s\"\n", host, ping, pong);
  }

  MPI_Finalize();
  return 0;
}
