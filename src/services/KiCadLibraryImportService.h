#pragma once

#include <QObject>
#include <QString>

#include <memory>

class QProcess;
class QTemporaryDir;

namespace EasyKiConverter {

class KiCadLibraryImportService : public QObject {
    Q_OBJECT

public:
    explicit KiCadLibraryImportService(QObject* parent = nullptr);
    ~KiCadLibraryImportService() override;

    bool isRunning() const;
    void startImport(const QString& sourceRoot,
                     const QString& projectRoot,
                     const QString& libraryName,
                     bool reuseExistingFootprints,
                     const QString& kiCadCliPath = QString());

signals:
    void completed(bool success, const QString& message, const QString& backupDirectory);

private:
    void startOperation(const QString& operation, const QString& fingerprint = QString());
    void handleProcessFinished(int exitCode, int exitStatus);
    void finish(bool success, const QString& message, const QString& backupDirectory = QString());
    QString scriptPath() const;

    QProcess* m_process = nullptr;
    std::unique_ptr<QTemporaryDir> m_resultDirectory;
    QString m_sourceRoot;
    QString m_projectRoot;
    QString m_libraryName;
    QString m_fingerprint;
    QString m_backupDirectory;
    QString m_currentOperation;
    QString m_resultPath;
    bool m_reuseExistingFootprints = false;
    QString m_kiCadCliPath;
    bool m_finishing = false;
};

}  // namespace EasyKiConverter
