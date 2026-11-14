#include "services/ConfigService.h"

#include <QDir>
#include <QTemporaryDir>
#include <QtTest>

using namespace EasyKiConverter;

class TestConfigService : public QObject {
    Q_OBJECT

private slots:
    void testCacheSettingsPersistAcrossLoad();
    void testDiskCacheLimitClamped();
    void testExportModePersistAcrossLoad();
    void testDirectImportSettingsPersistAcrossLoad();
};

/**
 * @brief 验证 testCacheSettingsPersistAcrossLoad 测试场景。
 */
void TestConfigService::testCacheSettingsPersistAcrossLoad() {
    // tempDir：测试使用的文件系统路径。
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());

    // configPath：测试使用的文件系统路径。
    const QString configPath = QDir(tempDir.path()).filePath(QStringLiteral("config.json"));
    // cacheDir：测试使用的文件系统路径。
    const QString cacheDir = QDir(tempDir.path()).filePath(QStringLiteral("custom-cache"));

    // config：测试用配置对象。
    ConfigService* config = ConfigService::instance();
    config->resetToDefaults();
    config->setCacheDir(cacheDir);
    config->setDiskCacheLimitMB(2048);
    QVERIFY(config->saveConfig(configPath));

    config->resetToDefaults();
    QVERIFY(config->loadConfig(configPath));

    QCOMPARE(config->getCacheDir(), QDir::cleanPath(cacheDir));
    QCOMPARE(config->getDiskCacheLimitMB(), 2048);
}

/**
 * @brief 验证 testDiskCacheLimitClamped 测试场景。
 */
void TestConfigService::testDiskCacheLimitClamped() {
    // config：测试用配置对象。
    ConfigService* config = ConfigService::instance();

    config->setDiskCacheLimitMB(0);
    QCOMPARE(config->getDiskCacheLimitMB(), 1);

    config->setDiskCacheLimitMB(1048577);
    QCOMPARE(config->getDiskCacheLimitMB(), 1048576);
}

/**
 * @brief 验证 testExportModePersistAcrossLoad 测试场景。
 */
void TestConfigService::testExportModePersistAcrossLoad() {
    // tempDir：测试使用的文件系统路径。
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());

    // configPath：测试使用的文件系统路径。
    const QString configPath = QDir(tempDir.path()).filePath(QStringLiteral("config.json"));

    // config：测试用配置对象。
    ConfigService* config = ConfigService::instance();
    config->resetToDefaults();
    QCOMPARE(config->getExportMode(), 0);

    config->setExportMode(1);
    QCOMPARE(config->getExportMode(), 1);
    QVERIFY(config->saveConfig(configPath));

    config->resetToDefaults();
    QCOMPARE(config->getExportMode(), 0);

    QVERIFY(config->loadConfig(configPath));
    QCOMPARE(config->getExportMode(), 1);
}

void TestConfigService::testDirectImportSettingsPersistAcrossLoad() {
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString configPath = QDir(tempDir.path()).filePath(QStringLiteral("config.json"));
    const QString targetPath = QDir(tempDir.path()).filePath(QStringLiteral("TestLibrary.pretty"));

    ConfigService* config = ConfigService::instance();
    config->resetToDefaults();
    config->setDirectImportEnabled(true);
    config->setDirectImportTargetPath(targetPath);
    config->setReuseExistingFootprints(true);
    config->setKiCadCliPath(QStringLiteral("D:/KiCad/bin/kicad-cli.exe"));
    QVERIFY(config->saveConfig(configPath));

    config->resetToDefaults();
    QVERIFY(config->loadConfig(configPath));
    QVERIFY(config->getDirectImportEnabled());
    QCOMPARE(config->getDirectImportTargetPath(), targetPath);
    QVERIFY(config->getReuseExistingFootprints());
    QCOMPARE(config->getKiCadCliPath(), QStringLiteral("D:/KiCad/bin/kicad-cli.exe"));
}

QTEST_GUILESS_MAIN(TestConfigService)
#include "test_config_service.moc"
