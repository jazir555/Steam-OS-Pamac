#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

# Install build deps if needed
echo "=== Installing build dependencies ==="
echo a | sudo -S pacman -S --needed --noconfirm extra-cmake-modules qt6-base-dev kf6-service-dev 2>&1 | tail -5

echo ""
echo "=== Compiling test program ==="
cd /tmp/test-trader

cat > CMakeLists.txt << 'CMEOF'
cmake_minimum_required(VERSION 3.16)
project(test-trader)
find_package(Qt6 REQUIRED Core)
find_package(KF6 REQUIRED Service)
add_executable(test-trader test-trader.cpp)
target_link_libraries(test-trader Qt6::Core KF6::Service)
CMEOF

mkdir -p build && cd build
cmake .. 2>&1 | tail -10
make 2>&1 | tail -10

echo ""
echo "=== Running test ==="
./test-trader 2>&1
