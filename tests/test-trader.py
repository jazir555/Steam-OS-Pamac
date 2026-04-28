#!/usr/bin/env python3
"""Test KApplicationTrader::preferredService for x-scheme-handler/appstream"""
import subprocess
import sys
import os

os.environ.setdefault('DISPLAY', ':0')
os.environ.setdefault('XDG_RUNTIME_DIR', '/run/user/1000')
os.environ.setdefault('DBUS_SESSION_BUS_ADDRESS', 'unix:path=/run/user/1000/bus')

# Use qdbus to test indirectly - check if plasmashell's kicker sees appstream actions
# We can't call KApplicationTrader directly from Python, but we can check sycoca

# Check sycoca database for the service
result = subprocess.run(
    ['kbuildsycoca6', '--noincremental'],
    capture_output=True, text=True, timeout=10
)
print(f"kbuildsycoca6: {result.stderr}")

# Try using qdbus to check kicker's behavior
result = subprocess.run(
    ['qdbus', 'org.kde.plasmashell'],
    capture_output=True, text=True, timeout=5
)
if result.returncode != 0:
    print("plasmashell not on dbus")
else:
    print(f"plasmashell services: {result.stdout[:200]}")

# The definitive test: use KDE's own tools
# kservice-cli6 can query the trader
for tool in ['kservice-cli6', 'kservice-cli', 'ktraderclient6']:
    result = subprocess.run(['which', tool], capture_output=True, text=True)
    if result.returncode == 0:
        print(f"Found: {tool}")
        result = subprocess.run(
            [tool, '--mimeType', 'x-scheme-handler/appstream'],
            capture_output=True, text=True, timeout=5
        )
        print(f"{tool} output: {result.stdout[:500]}")
        print(f"{tool} errors: {result.stderr[:500]}")
        break
else:
    print("No kservice-cli/ktraderclient found")

# Alternative: compile a small test program
print("\n=== Compiling test program ===")
test_code = '''
#include <QCoreApplication>
#include <KApplicationTrader>
#include <KService>
#include <iostream>

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    
    auto service = KApplicationTrader::preferredService(QStringLiteral("x-scheme-handler/appstream"));
    if (service) {
        std::cout << "preferredService returned: " << service->storageId().toStdString() 
                  << " NoDisplay=" << (service->noDisplay() ? "true" : "false")
                  << " Hidden=" << (service->isDeleted() ? "true" : "false")
                  << " Valid=" << (service->isValid() ? "true" : "false") << std::endl;
    } else {
        std::cout << "preferredService returned NULL - no appstream handler!" << std::endl;
    }
    
    auto list = KApplicationTrader::queryByMimeType(QStringLiteral("x-scheme-handler/appstream"));
    std::cout << "queryByMimeType returned " << list.size() << " services:" << std::endl;
    for (const auto& s : list) {
        std::cout << "  - " << s->storageId().toStdString() 
                  << " NoDisplay=" << (s->noDisplay() ? "true" : "false")
                  << " Hidden=" << (s->isDeleted() ? "true" : "false") << std::endl;
    }
    
    return 0;
}
'''

pro_code = '''
QT += core
LIBS += -lKService
TARGET = test-trader
SOURCES += test-trader.cpp
'''

print("Writing test program...")
os.makedirs('/tmp/test-trader', exist_ok=True)
with open('/tmp/test-trader/test-trader.cpp', 'w') as f:
    f.write(test_code)
with open('/tmp/test-trader/test-trader.pro', 'w') as f:
    f.write(pro_code)

print("Files written to /tmp/test-trader/")
print("Compile with: cd /tmp/test-trader && qmake6 && make && ./test-trader")
