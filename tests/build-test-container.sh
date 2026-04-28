#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Building test inside arch-pamac container ==="

# Install build deps in container
podman exec arch-pamac pacman -S --needed --noconfirm extra-cmake-modules qt6-base-dev kf6-service-dev cmake make gcc 2>&1 | tail -10

# Copy source to container
podman exec arch-pamac mkdir -p /tmp/test-trader 2>/dev/null

cat > /tmp/test-trader-cm.txt << 'CMEOF'
cmake_minimum_required(VERSION 3.16)
project(test-trader)
find_package(Qt6 REQUIRED Core)
find_package(KF6 REQUIRED Service)
add_executable(test-trader test-trader.cpp)
target_link_libraries(test-trader Qt6::Core KF6::Service)
CMEOF

# Write files to container via pipe
podman exec arch-pamac bash -c 'cat > /tmp/test-trader/CMakeLists.txt' < /tmp/test-trader-cm.txt 2>/dev/null
podman exec arch-pamac bash -c 'cat > /tmp/test-trader/test-trader.cpp' < /tmp/test-trader.cpp 2>/dev/null

echo ""
echo "=== Building inside container ==="
podman exec arch-pamac bash -c 'cd /tmp/test-trader && mkdir -p build && cd build && cmake .. 2>&1 && make 2>&1' | tail -20

echo ""
echo "=== Copying binary to host ==="
podman cp arch-pamac:/tmp/test-trader/build/test-trader /tmp/test-trader-bin 2>&1
chmod +x /tmp/test-trader-bin
ls -la /tmp/test-trader-bin 2>&1

echo ""
echo "=== Running on host (will use host sycoca) ==="
/tmp/test-trader-bin 2>&1
