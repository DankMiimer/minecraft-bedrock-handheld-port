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

#include <cstdio>

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
        // Every firmware names this hardware differently: Knulli calls it
        // "Anbernic RG34XX-SP Controller", muOS calls it "muOS-Keys". Matching
        // the name alone found nothing on muOS, so the sign-in window took no
        // input at all. Prefer the name the reference device was verified with,
        // then fall back to what a device can actually do -- the buttons and
        // the hat this class drives.
        QByteArray name;
        fd_ = openController(true, &name);
        if (fd_ < 0)
            fd_ = openController(false, &name);
        if (fd_ < 0)
            return;
        map_ = mapFor(name);
        // Named in the private sign-in log, so the next firmware that arrives
        // can be told apart from one whose buttons are merely mapped wrongly.
        fprintf(stderr, "sign-in controller: %s\n", name.constData());

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
    // Button positions counted from BTN_GAMEPAD. Neither firmware numbers them
    // semantically -- on both, the button at index 6 is printed "Select" -- so
    // no order can be derived from the other and each one here was measured by
    // pressing every printed button on the hardware and reading the codes.
    struct ButtonMap {
        int a, b, x, y, select, start, pageUp, pageDown;
    };

    static ButtonMap mapFor(const QByteArray &name)
    {
        // Knulli, "Anbernic RG34XX-SP Controller".
        if (name.contains("Anbernic RG34XX-SP Controller"))
            return ButtonMap{0, 1, 2, 3, 6, 7, 10, 11};
        // muOS 2601.0, "muOS-Keys" on the same RG34XX-SP: A, B, Select and
        // Start land in the same places, X and Y are swapped, and the shoulders
        // sit at 4 and 5 rather than 10 and 11. Also the default for a firmware
        // nobody has measured yet, because it is the layout of the gpio-keys
        // node these handhelds ship rather than a vendor driver's own order.
        return ButtonMap{0, 1, 3, 2, 6, 7, 4, 5};
    }

    static bool hasBit(const unsigned char *bits, int bit)
    {
        return bits[bit / 8] & (1u << (bit % 8));
    }

    // byName: the reference device's exact name. Otherwise any node reporting
    // the gamepad buttons and the hat, which is what this class reads.
    static int openController(bool byName, QByteArray *found)
    {
        const QStringList devices = QDir(QStringLiteral("/dev/input")).entryList(
            {QStringLiteral("event*")}, QDir::System | QDir::Files, QDir::Name);
        for (const QString &device : devices) {
            const QByteArray path = QStringLiteral("/dev/input/%1").arg(device).toLocal8Bit();
            const int candidate = open(path.constData(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
            if (candidate < 0)
                continue;
            char name[256] = {};
            if (ioctl(candidate, EVIOCGNAME(sizeof(name)), name) < 0)
                name[0] = '\0';
            if (byName) {
                if (QByteArray(name).contains("Anbernic RG34XX-SP Controller")) {
                    *found = QByteArray(name);
                    return candidate;
                }
            } else {
                unsigned char keys[KEY_MAX / 8 + 1] = {};
                unsigned char axes[ABS_MAX / 8 + 1] = {};
                if (ioctl(candidate, EVIOCGBIT(EV_KEY, sizeof(keys)), keys) >= 0 &&
                    ioctl(candidate, EVIOCGBIT(EV_ABS, sizeof(axes)), axes) >= 0 &&
                    hasBit(keys, BTN_GAMEPAD) && hasBit(axes, ABS_HAT0X) &&
                    hasBit(axes, ABS_HAT0Y)) {
                    *found = QByteArray(name);
                    return candidate;
                }
            }
            close(candidate);
        }
        return -1;
    }

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

            // Both firmwares expose these as raw button positions rather than
            // named buttons, so the printed labels come from map_.
            const bool keyboardVisible = QGuiApplication::inputMethod()->isVisible();
            const int button = event.code - BTN_GAMEPAD;
            if (button == map_.a) {                      // printed A
                if (keyboardVisible)
                    emit keyboardNavigationKey(Qt::Key_Return);
                else
                    sendKey(Qt::Key_Space);
            } else if (button == map_.b) {               // printed B
                if (keyboardVisible)
                    QGuiApplication::inputMethod()->hide();
                else
                    sendKey(Qt::Key_Escape);
            } else if (button == map_.x) {
                sendKey(Qt::Key_Return);
            } else if (button == map_.y) {
                sendKey(Qt::Key_Backtab, Qt::ShiftModifier);
            } else if (button == map_.select) {
                sendKey(Qt::Key_Escape);
            } else if (button == map_.start) {
                sendKey(Qt::Key_Return);
            } else if (button == map_.pageUp) {
                sendKey(Qt::Key_PageUp);
            } else if (button == map_.pageDown) {
                sendKey(Qt::Key_PageDown);
            }
        }
    }

    int fd_ = -1;
    ButtonMap map_{0, 1, 3, 2, 6, 7, 4, 5};
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
