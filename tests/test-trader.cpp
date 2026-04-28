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
