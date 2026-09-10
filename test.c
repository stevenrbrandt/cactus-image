#include <mpi.h>
#include <stdio.h>

int main(int argc, char **argv) {
    MPI_Init(&argc, &argv);

    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (size != 2) {
        if (rank == 0)
            fprintf(stderr, "Need exactly 2 ranks\n");
        MPI_Finalize();
        return 1;
    }

    int msg = 42;
    MPI_Status status;

    if (rank == 0) {
        MPI_Send(&msg, 1, MPI_INT, 1, 0, MPI_COMM_WORLD);
        MPI_Recv(&msg, 1, MPI_INT, 1, 1, MPI_COMM_WORLD, &status);
        printf("success\n");
    } else {
        MPI_Recv(&msg, 1, MPI_INT, 0, 0, MPI_COMM_WORLD, &status);
        MPI_Send(&msg, 1, MPI_INT, 0, 1, MPI_COMM_WORLD);
    }

    MPI_Finalize();
    return 0;
}
