#include <QFileDevice>
#include <QDir>
#include <QGuiApplication>
#include <QInputMethod>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QSocketNotifier>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSaveFile>
#include <QTimer>
#include <QUrl>
#include <QWebEngineCookieStore>
#include <QWebEngineProfile>
#include <QWebEngineScript>
#include <QWebEngineScriptCollection>
#include <QWindow>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>

#include <QNetworkCookie>

#include <fcntl.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <unistd.h>

class HandheldController final : public QObject
{
    Q_OBJECT

public:
    explicit HandheldController(QObject *parent = nullptr) : QObject(parent)
    {
        const QStringList devices = QDir(QStringLiteral("/dev/input")).entryList(
            {QStringLiteral("event*")}, QDir::System | QDir::Files, QDir::Name);
        for (const QString &device : devices) {
            const QByteArray path = QStringLiteral("/dev/input/%1").arg(device).toLocal8Bit();
            const int candidate = open(path.constData(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
            if (candidate < 0)
                continue;
            char name[256] = {};
            if (ioctl(candidate, EVIOCGNAME(sizeof(name)), name) >= 0 &&
                QByteArray(name).contains("Anbernic RG34XX-SP Controller")) {
                fd_ = candidate;
                break;
            }
            close(candidate);
        }
        if (fd_ < 0)
            return;

        notifier_ = new QSocketNotifier(fd_, QSocketNotifier::Read, this);
        connect(notifier_, &QSocketNotifier::activated, this, &HandheldController::readEvents);
    }

    ~HandheldController() override
    {
        if (fd_ >= 0)
            close(fd_);
    }

signals:
    void keyboardNavigationKey(int key);

private:
    void sendKey(int key, Qt::KeyboardModifiers modifiers = Qt::NoModifier)
    {
        QObject *target = QGuiApplication::focusObject();
        if (!target)
            target = QGuiApplication::focusWindow();
        if (!target)
            return;
        QKeyEvent press(QEvent::KeyPress, key, modifiers);
        QCoreApplication::sendEvent(target, &press);
        QKeyEvent release(QEvent::KeyRelease, key, modifiers);
        QCoreApplication::sendEvent(target, &release);
    }

    void readEvents()
    {
        input_event event{};
        while (read(fd_, &event, sizeof(event)) == sizeof(event)) {
            if (event.type == EV_ABS && event.value != 0) {
                const bool keyboardVisible = QGuiApplication::inputMethod()->isVisible();
                if (event.code == ABS_HAT0Y) {
                    if (keyboardVisible)
                        emit keyboardNavigationKey(event.value < 0 ? Qt::Key_Up : Qt::Key_Down);
                    else
                        sendKey(event.value < 0 ? Qt::Key_Backtab : Qt::Key_Tab,
                                event.value < 0 ? Qt::ShiftModifier : Qt::NoModifier);
                } else if (event.code == ABS_HAT0X) {
                    if (keyboardVisible)
                        emit keyboardNavigationKey(event.value < 0 ? Qt::Key_Left : Qt::Key_Right);
                    else
                        sendKey(event.value < 0 ? Qt::Key_Left : Qt::Key_Right);
                }
                continue;
            }
            if (event.type != EV_KEY || event.value != 1 || event.code < BTN_GAMEPAD)
                continue;

            // Knulli exposes these as raw SDL buttons b0..b12.  The RG34XXSP
            // mapping identifies printed A as b0 and printed B as b1.
            const bool keyboardVisible = QGuiApplication::inputMethod()->isVisible();
            switch (event.code - BTN_GAMEPAD) {
            case 0:
                if (keyboardVisible)
                    emit keyboardNavigationKey(Qt::Key_Return);
                else
                    sendKey(Qt::Key_Space);
                break;                                   // printed A
            case 1:
                if (keyboardVisible)
                    QGuiApplication::inputMethod()->hide();
                else
                    sendKey(Qt::Key_Escape);
                break;                                   // printed B
            case 2: sendKey(Qt::Key_Return); break;      // printed X
            case 3: sendKey(Qt::Key_Backtab, Qt::ShiftModifier); break;
            case 6: sendKey(Qt::Key_Escape); break;      // Select
            case 7: sendKey(Qt::Key_Return); break;      // Start
            case 10: sendKey(Qt::Key_PageUp); break;
            case 11: sendKey(Qt::Key_PageDown); break;
            default: break;
            }
        }
    }

    int fd_ = -1;
    QSocketNotifier *notifier_ = nullptr;
};

class SigninBridge final : public QObject
{
    Q_OBJECT

public:
    explicit SigninBridge(QString resultPath, QObject *parent = nullptr)
        : QObject(parent), resultPath_(std::move(resultPath))
    {
    }

    Q_INVOKABLE void consoleMessage(const QString &message)
    {
        static const QString prefix = QStringLiteral("MCPE_ACCOUNT_IDENTIFIER:");
        if (!message.startsWith(prefix))
            return;
        identifier_ = QUrl::fromPercentEncoding(message.mid(prefix.size()).toUtf8());
        finishWhenReady();
    }

    void cookieAdded(const QNetworkCookie &cookie)
    {
        if (cookie.name() != QByteArrayLiteral("oauth_token"))
            return;
        token_ = QString::fromUtf8(cookie.value());
        finishWhenReady();
    }

signals:
    void captureCompleted();

private:
    void finishWhenReady()
    {
        if (finished_ || identifier_.isEmpty() || token_.isEmpty() ||
            identifier_.size() > 1024 || token_.size() > 8192)
            return;

        QSaveFile output(resultPath_);
        output.setDirectWriteFallback(false);
        if (!output.open(QIODevice::WriteOnly))
            return;
        output.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        const QJsonObject result{
            {QStringLiteral("accountIdentifier"), identifier_},
            {QStringLiteral("accountToken"), token_},
        };
        if (output.write(QJsonDocument(result).toJson(QJsonDocument::Compact)) < 0 ||
            !output.commit())
            return;

        finished_ = true;
        emit captureCompleted();
        QTimer::singleShot(900, QCoreApplication::instance(), &QCoreApplication::quit);
    }

    QString resultPath_;
    QString identifier_;
    QString token_;
    bool finished_ = false;
};

int main(int argc, char **argv)
{
    if (argc != 3)
        return 2;

    QtWebEngineQuick::initialize();
    QGuiApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("MCPE Google Sign-In"));
    QCoreApplication::setOrganizationName(QStringLiteral("PortMaster"));

    SigninBridge bridge(QString::fromLocal8Bit(argv[2]));
    HandheldController controller;
    QWebEngineProfile *profile = QWebEngineProfile::defaultProfile();
    profile->cookieStore()->deleteAllCookies();
    QWebEngineScript bridgeScript;
    bridgeScript.setName(QStringLiteral("HandheldSignInBridge"));
    bridgeScript.setInjectionPoint(QWebEngineScript::DocumentCreation);
    bridgeScript.setWorldId(QWebEngineScript::MainWorld);
    bridgeScript.setRunsOnSubFrames(false);
    bridgeScript.setSourceCode(QStringLiteral(
        "(function(){window.mm={showView:function(){},log:function(){},"
        "setAccountIdentifier:function(value){console.log('MCPE_ACCOUNT_IDENTIFIER:'"
        "+encodeURIComponent(value));}};})();"));
    profile->scripts()->insert(bridgeScript);
    QObject::connect(profile->cookieStore(), &QWebEngineCookieStore::cookieAdded,
                     &bridge, &SigninBridge::cookieAdded);

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("signinBridge"), &bridge);
    engine.rootContext()->setContextProperty(QStringLiteral("handheldController"), &controller);
    const QUrl qml = QUrl::fromLocalFile(QString::fromLocal8Bit(argv[1]));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [] { QCoreApplication::exit(3); }, Qt::QueuedConnection);
    engine.load(qml);
    if (engine.rootObjects().isEmpty())
        return 3;
    return app.exec();
}

#include "main.moc"
