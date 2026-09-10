# Images
I'd like to expand the collection of images here from one to four, all with the same versions of packages, ideally with the same OS version.
- An image for x86 with AMReX prebuilt. We have that.
- An image for x86 + Cuda. AMReX should not be pre-built so that it can adapt to the CUDA driver version. The image should have the full NVIDIA set of tools, including nsight systems & compute.
- An image for ARM + Cuda for Grace Hopper. AMReX can be prebuilt for Grace Hopper. The image should have the full NVIDIA set of tools, including nsight systems & compute. It may make sense to build NSIMD here, too, since the vector units are known.
- An image for x86 + HiP.
- Each with a docker-compose and docker file.
