# E2B build pipeline

Docker-based build that produces `e2b/build/dist/e2b-<pin7>.tar.gz` from the pinned upstream commit plus `e2b/patches/`.

**Task 2** adds `Dockerfile.build`, `build.sh`, and dist layout (`bin/`, migrations, `BUILD_INFO`, `SHA256SUMS`).
