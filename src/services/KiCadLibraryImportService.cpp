#include "KiCadLibraryImportService.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QStandardPaths>
#include <QTemporaryDir>

namespace EasyKiConverter {

KiCadLibraryImportService::KiCadLibraryImportService(QObject* parent) : QObject(parent), m_process(new QProcess(this)) {
    connect(m_process,
            qOverload<int, QProcess::ExitStatus>(&QProcess::finished),
            this,
            [this](int exitCode, QProcess::ExitStatus exitStatus) {
                handleProcessFinished(exitCode, static_cast<int>(exitStatus));
            });
    connect(m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            finish(false, QStringLiteral("Could not start PowerShell: %1").arg(m_process->errorString()));
        }
    });
}

KiCadLibraryImportService::~KiCadLibraryImportService() {
    if (m_process && m_process->state() != QProcess::NotRunning) {
        m_process->terminate();
        if (!m_process->waitForFinished(3000)) {
            m_process->kill();
            m_process->waitForFinished();
        }
    }
}

bool KiCadLibraryImportService::isRunning() const {
    return m_process && m_process->state() != QProcess::NotRunning;
}

void KiCadLibraryImportService::startImport(const QString& sourceRoot,
                                            const QString& projectRoot,
                                            const QString& libraryName,
                                            bool reuseExistingFootprints,
                                            const QString& kiCadCliPath) {
    if (isRunning() || libraryName.isEmpty()) {
        emit completed(false, QStringLiteral("The import service is busy or the library name is empty."), QString());
        return;
    }

    m_sourceRoot = QDir::cleanPath(sourceRoot);
    m_projectRoot = QDir::cleanPath(projectRoot);
    m_libraryName = libraryName;
    m_reuseExistingFootprints = reuseExistingFootprints;
    m_kiCadCliPath = kiCadCliPath;
    m_fingerprint.clear();
    m_backupDirectory.clear();
    m_finishing = false;

    m_resultDirectory = std::make_unique<QTemporaryDir>(QDir::tempPath() + QStringLiteral("/easykiconverterplus-import-XXXXXX"));
    if (!m_resultDirectory->isValid()) {
        finish(false, QStringLiteral("Could not create a temporary import result directory."));
        return;
    }
    if (!QFileInfo(scriptPath()).isFile()) {
        finish(false, QStringLiteral("The bundled KiCad library importer script is missing."));
        return;
    }

    startOperation(QStringLiteral("DryRun"));
}

QString KiCadLibraryImportService::scriptPath() const {
    const QString relativePath = QStringLiteral("tools/kicad-library-importer/Invoke-KiCadLibraryImport.ps1");
    const QString installedPath = QDir(QCoreApplication::applicationDirPath()).filePath(relativePath);
    if (QFileInfo(installedPath).isFile())
        return installedPath;

    const QString buildTreePath = QDir(QCoreApplication::applicationDirPath()).filePath(
        QStringLiteral("../") + relativePath);
    if (QFileInfo(buildTreePath).isFile())
        return QDir::cleanPath(buildTreePath);

#ifdef EASYKICONVERTER_IMPORTER_SOURCE_DIR
    const QString sourcePath = QDir(QStringLiteral(EASYKICONVERTER_IMPORTER_SOURCE_DIR))
                                   .filePath(QStringLiteral("Invoke-KiCadLibraryImport.ps1"));
    if (QFileInfo(sourcePath).isFile())
        return sourcePath;
#endif
    return installedPath;
}

void KiCadLibraryImportService::startOperation(const QString& operation, const QString& fingerprint) {
    m_currentOperation = operation;
    m_resultPath = QDir(m_resultDirectory->path()).filePath(operation.toLower() + QStringLiteral(".json"));

    QString program = QStandardPaths::findExecutable(QStringLiteral("powershell.exe"));
    if (program.isEmpty())
        program = QStringLiteral("powershell.exe");

    QStringList arguments = {QStringLiteral("-NoLogo"),
                             QStringLiteral("-NoProfile"),
                             QStringLiteral("-NonInteractive"),
                             QStringLiteral("-ExecutionPolicy"),
                             QStringLiteral("Bypass"),
                             QStringLiteral("-File"),
                             scriptPath(),
                             QStringLiteral("-Operation"),
                             operation,
                             QStringLiteral("-SourceRoot"),
                             m_sourceRoot,
                             QStringLiteral("-ProjectRoot"),
                             m_projectRoot,
                             QStringLiteral("-LibraryName"),
                             m_libraryName,
                             QStringLiteral("-ResultPath"),
                             m_resultPath};
    if (m_reuseExistingFootprints)
        arguments.append(QStringLiteral("-ReuseExistingFootprints"));
    if (!m_kiCadCliPath.isEmpty()) {
        arguments.append(QStringLiteral("-KiCadCliPath"));
        arguments.append(m_kiCadCliPath);
    }
    if (!fingerprint.isEmpty()) {
        arguments.append(QStringLiteral("-ExpectedFingerprint"));
        arguments.append(fingerprint);
    }

    m_process->setProgram(program);
    m_process->setArguments(arguments);
    m_process->start();
}

void KiCadLibraryImportService::handleProcessFinished(int exitCode, int exitStatus) {
    if (m_finishing)
        return;

    const QByteArray standardError = m_process->readAllStandardError();
    QJsonObject result;
    QFile resultFile(m_resultPath);
    if (resultFile.open(QIODevice::ReadOnly)) {
        const QJsonDocument document = QJsonDocument::fromJson(resultFile.readAll());
        if (document.isObject())
            result = document.object();
    }

    const QString error = result.value(QStringLiteral("errorMessage")).toString(
        QString::fromUtf8(standardError).trimmed());
    const bool succeeded = exitStatus == static_cast<int>(QProcess::NormalExit) && exitCode == 0 &&
                           result.value(QStringLiteral("success")).toBool();
    if (!succeeded) {
        finish(false,
               error.isEmpty() ? QStringLiteral("KiCad library import failed during %1.").arg(m_currentOperation)
                               : error,
               result.value(QStringLiteral("backupDirectory")).toString());
        return;
    }

    if (m_currentOperation == QStringLiteral("DryRun")) {
        m_fingerprint = result.value(QStringLiteral("fingerprint")).toString();
        if (m_fingerprint.isEmpty()) {
            finish(false, QStringLiteral("The import preview did not return a fingerprint."));
            return;
        }
        startOperation(QStringLiteral("Apply"), m_fingerprint);
        return;
    }

    if (!result.value(QStringLiteral("finalValidation")).toBool()) {
        finish(false,
               QStringLiteral("The import finished without KiCad's final library validation."),
               result.value(QStringLiteral("backupDirectory")).toString());
        return;
    }

    m_backupDirectory = result.value(QStringLiteral("backupDirectory")).toString();
    const int symbolCount = result.value(QStringLiteral("symbols")).toArray().size();
    const int footprintCount = result.value(QStringLiteral("footprints")).toArray().size();
    const QString message = QStringLiteral("Imported %1 symbols and %2 footprints into %3.")
                                .arg(symbolCount)
                                .arg(footprintCount)
                                .arg(m_libraryName);
    finish(true, message, m_backupDirectory);
}

void KiCadLibraryImportService::finish(bool success, const QString& message, const QString& backupDirectory) {
    if (m_finishing)
        return;
    m_finishing = true;
    m_resultDirectory.reset();
    emit completed(success, message, backupDirectory);
}

}  // namespace EasyKiConverter
