pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import qs.config
import qs.services
import qs.widgets

// «Камера.exe»: предпросмотр, фото, видео, переключение камер и микрофонов.
// Одна разметка в обеих темах: в пиксельной хост — PxWindow (обличье 98-х), в macOS —
// стеклянная карточка Liquid Glass; оформление берётся из Skin и GoldenGate, свои цвета
// не рисуем. Окно закрывается только крестиком окна (крестик сначала даёт рекордеру
// дописать файл) либо системной комбинацией закрытия (Win+Q в пиксельной теме, Mod+W
// в macOS): Esc и щелчки в сторону ничего не закрывают.
Item {
    id: app

    property var plugin
    signal closeRequested()
    signal flashFramed()                      // кадр сделан — тело вспыхнет (id из компонента наружу не виден)

    // Контролы qs.widgets рисуют себя в облике macOS, когда она включена: они узнают
    // об этом по settingsSkin выше по родительской цепочке (Theme.settingsSkinFor).
    readonly property bool macLook: Skin.mac
    readonly property string settingsSkin: macLook ? "goldengate" : ""
    readonly property int spacing: Skin.spacing

    // ---- настройки плагина (Настройки → Плагины → Камера) ----
    readonly property bool mirror: plugin ? !!plugin.get("mirror", true) : true
    readonly property string container: plugin ? String(plugin.get("container", "mp4") || "mp4") : "mp4"
    readonly property string photoFormat: plugin ? String(plugin.get("photoFormat", "jpg") || "jpg") : "jpg"
    readonly property string quality: plugin ? String(plugin.get("quality", "high") || "high") : "high"
    readonly property int fps: plugin ? Math.max(0, Number(plugin.get("fps", 0)) || 0) : 0
    readonly property bool micOn: plugin ? !!plugin.get("micOn", true) : true
    readonly property string mode: plugin ? (String(plugin.get("mode", "photo") || "photo") === "video" ? "video" : "photo") : "photo"

    // папки: «~» раскрывается в дом, относительные — тоже от дома; пустая — путь по умолчанию
    function userPath(key, def) {
        const raw = plugin ? String(plugin.get(key, "") || "").trim() : "";
        let p = raw === "" ? def : raw.replace(/^~(?=\/|$)/, Config.home);
        if (!p.startsWith("/"))
            p = Config.home + "/" + p;
        return p.replace(/\/+$/, "") || def;
    }
    readonly property string photoDir: userPath("photoDir", Config.home + "/Pictures/Photos")
    readonly property string videoDir: userPath("videoDir", Config.home + "/Videos/Camera")

    // sh-кавычки: папки с пробелами и апострофами не ломают команду
    function shq(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }
    function ensureDirs() {
        Shell.sh("mkdir -p -- " + shq(photoDir) + " " + shq(videoDir));
    }
    function openFolder() {                 // папка того, чем занят: съёмка — фото, запись — видео
        ensureDirs();
        Shell.exec(["xdg-open", mode === "video" ? videoDir : photoDir]);
    }

    // ---- короткое сообщение внизу экрана («Сохранил: …») ----
    property string note: ""
    Timer {
        id: noteFade
        interval: 5000
        onTriggered: app.note = ""
    }
    onNoteChanged: {
        if (note !== "")
            noteFade.restart();
    }
    function say(s) {
        note = s;
    }

    // ---- устройства ----
    MediaDevices {
        id: devices
    }

    readonly property var cams: devices.videoInputs || []      // QCameraDevice: description, isDefault…
    readonly property var mics: devices.audioInputs || []      // QAudioDevice: description…

    // имя без повторов вида «HD Camera: HD Camera» и без хвостов вида «(USB: 1234)»
    function camName(d) {
        if (!d)
            return "";
        const s = String(d.description || d.id || "").replace(/\s*\([^)]*\)/g, "").replace(/\s+/g, " ").trim();
        const p = s.split(/:\s+/);
        return (p.length > 1 && p[0] === p[1] ? p[0] : s) || "Камера";
    }
    function micName(d) {
        if (!d)
            return "";
        const s = String(d.description || d.id || "").replace(/\s*\([^)]*\)/g, "").replace(/\s+/g, " ").trim();
        return s || "Микрофон";
    }

    readonly property string camKey: plugin ? String(plugin.get("camId", "") || "") : ""
    readonly property string micKey: plugin ? String(plugin.get("micId", "") || "") : ""
    // выбор из настроек (пусто — умолчание, какие даёт система)
    readonly property var chosenCam: cams.find(d => camName(d) === camKey) || devices.defaultVideoInput || cams[0] || null
    readonly property var chosenMic: (micKey ? mics.find(d => String(d.description || "") === micKey) : null) || devices.defaultAudioInput || mics[0] || null

    property var pendingCam: null          // сменить камеру посреди записи нельзя — ждём её конца
    property var currentCam: null          // камера, которая работает сейчас
    property string pendingMic: ""         // то же с микрофоном — иная связка во время записи хрупка
    function refreshCam() {
        // своё устройство, но исчезнувшее из системы — вернёмся к выбранному/умолчанию
        if (!currentCam || !cams.find(d => camName(d) === camName(currentCam)))
            currentCam = chosenCam;
    }
    onCamsChanged: Qt.callLater(refreshCam)
    onChosenCamChanged: if (!currentCam)
        Qt.callLater(refreshCam)
    onCurrentCamChanged: warmingTimer.restart()

    // ---- захват ----
    // кадр живёт внутри AppBody той темы, что в ходу; ссылку на VideoOutput тело само
    // приносит сюда (id из inline-компонента снаружи не виден)
    property var viewSurface: null
    CaptureSession {
        id: session
        camera: Camera {
            id: cam
            cameraDevice: app.currentCam                // null — умолчание системы
            active: app.currentCam !== null
        }
        audioInput: AudioInput {
            id: mic
            device: app.chosenMic                  // элементы null → система умолчания берёт
            muted: !app.micOn
        }
        videoOutput: app.viewSurface
        imageCapture: ImageCapture {
            id: still
            quality: ImageCapture.VeryHighQuality
            fileFormat: app.photoFormat === "png" ? ImageCapture.PNG : app.photoFormat === "webp" ? ImageCapture.WebP : ImageCapture.JPEG
            onImageCaptured: app.flashFramed()
            onImageSaved: (id, fileName) => {
                app.say(I18n.t("Сохранил: ", "Saved: ") + String(fileName).replace(Config.home, "~"));
                if (app.plugin)
                    app.plugin.achieve("first-shot");
            }
            onErrorOccurred: (id, error, errorString) => {
                app.say(I18n.t("Снимок не вышел: ", "The shot failed: ") + String(errorString || error));
            }
        }
        recorder: MediaRecorder {
            id: rec
            quality: app.quality === "max" ? MediaRecorder.VeryHighQuality : app.quality === "low" ? MediaRecorder.LowQuality : app.quality === "normal" ? MediaRecorder.NormalQuality : MediaRecorder.HighQuality
            videoFrameRate: app.fps > 0 ? app.fps : 0              // 0 — сама решит
            // MediaFormat объектом создать нельзя (isCreatable:false) — только групповым свойством рекордера
            mediaFormat {
                fileFormat: app.container === "mkv" ? MediaFormat.Matroska : MediaFormat.MPEG4
                videoCodec: MediaFormat.VideoCodec.H264
                audioCodec: app.container === "mkv" ? MediaFormat.AudioCodec.Opus : MediaFormat.AudioCodec.AAC
            }
            onErrorOccurred: (error, errorString) => {
                app.say(I18n.t("Запись споткнулась: ", "The recording failed: ") + String(errorString || error));
            }
        }
    }
    // у Camera в Qt 6 нет свойства «статус»: кадр смотрим через ошибки и разогрев
    readonly property bool camBroken: !!currentCam && cam.error !== Camera.NoError && String(cam.errorString || "") !== ""
    readonly property bool warming: !!currentCam && warmingTimer.running
    Timer {
        id: warmingTimer
        interval: 2500
        running: true
    }

    // ---- фото и видео ----
    property string lastStamp: ""
    property int lastN: 0                     // два файла за одну секунду — второй с номером
    function stampName(dir, ext) {
        const s = Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss");
        let dup = 0;
        if (s === lastStamp) {
            dup = lastN + 1;                      // второй файл за секунду — с номером
            lastN = dup;
        } else {
            lastStamp = s;
            lastN = 0;
        }
        return dir + "/angelos-" + s + (dup ? "-" + dup : "") + "." + ext;
    }

    function shoot() {
        if (!currentCam) {
            say(I18n.t("Камер система не видит", "The system sees no camera"));
            return;
        }
        if (!still.readyForCapture) {
            say(I18n.t("Камера ещё просыпается…", "The camera is still waking up…"));
            return;
        }
        ensureDirs();
        note = "";
        still.captureToFile(stampName(photoDir, photoFormat === "png" ? "png" : photoFormat === "webp" ? "webp" : "jpg"));
    }

    readonly property bool recording: rec.recorderState !== MediaRecorder.StoppedState
    property bool wasRecording: false         // она кончилась сама или её остановили
    property bool closingSoon: false          // крестик ждёт, пока доехал файл

    function stopRecording() {
        if (rec.recorderState !== MediaRecorder.StoppedState)
            rec.stop();
    }

    function playVideo() {
        if (recording) {                      // та же кнопка пишет и останавливает
            closingSoon = false;
            stopRecording();
            return;
        }
        if (!currentCam) {
            say(I18n.t("Камер система не видит", "The system sees no camera"));
            return;
        }
        ensureDirs();
        if (pendingMic !== "")                // микрофон успел смениться, пока писали — к новой записи уже
            applyMic(pendingMic);
        rec.outputLocation = stampName(videoDir, container === "mkv" ? "mkv" : "mp4");
        wasRecording = true;
        note = "";
        rec.record();
    }

    // крестик окна: сначала файл доехать, потом закрыться
    function requestClose() {
        if (recording) {
            closingSoon = true;
            say(I18n.t("Дозаписываю файл…", "Finishing the video…"));
            stopRecording();
            return;
        }
        closeRequested();
    }

    // закончилась запись (по своей воле): пришёл файл — либо закрываемся, либо смена камеры
    Connections {
        target: rec
        function onRecorderStateChanged(state) {
            if (state !== MediaRecorder.StoppedState || !app.wasRecording)
                return;
            app.wasRecording = false;
            if (app.closingSoon) {
                app.closingSoon = false;
                app.closeRequested();
                return;
            }
            if (app.pendingMic !== "")        // смену микрофона, набежавшую во время записи, — в настройки
                app.applyMic(app.pendingMic);
            if (app.pendingCam) {
                const next = app.pendingCam;
                app.pendingCam = null;
                app.currentCam = next;
                if (app.plugin)
                    app.plugin.progress("many-cams");
                app.note = "";
                return;
            }
            app.say(I18n.t("Видео: ", "Video: ") + String(app.rec.actualLocation).replace(/^file:\/\//, "").replace(Config.home, "~"));
            if (app.plugin)
                app.plugin.achieve("first-video");
        }
    }

    // ---- выбор устройств в самом окне ----
    function pickCamera(name) {
        const d = cams.find(x => camName(x) === String(name || ""));
        if (!d)
            return;
        if (plugin)
            plugin.set("camId", String(name));    // запомнить и на следующий раз
        if (recording) {                          // не рвать файл: доехать и переключить
            pendingCam = d;
            say(I18n.t("Жду, пока допишется видео…", "Waiting for the video to finish…"));
            stopRecording();
            return;
        }
        if (currentCam && camName(currentCam) === String(name))
            return;
        currentCam = d;
        if (plugin)
            plugin.progress("many-cams");
        note = "";
    }
    function cycleCamera() {                      // кнопка-стрелка: следующая камера
        if (cams.length < 2) {
            say(I18n.t("Другой камеры система не видит", "The system sees no other camera"));
            return;
        }
        const i = cams.findIndex(d => currentCam && camName(d) === camName(currentCam));
        pickCamera(camName(cams[(i + 1) % cams.length]));
    }
    function pickMic(name) {
        name = String(name || "");
        if (recording) {                      // не дёргать звук под файлом: заведём после
            pendingMic = name;
            say(I18n.t("Поменяю микрофон, когда допишется видео…", "I'll switch the mic when the video is done…"));
            return;
        }
        applyMic(name);
        note = "";
    }
    function applyMic(name) {
        pendingMic = "";
        if (plugin)
            plugin.set("micId", name);
    }
    // микрофон пишется только в видео; фотография звук не берёт
    function toggleMic() {
        if (!plugin)
            return;
        plugin.set("micOn", !micOn);
        note = "";
    }
    function setMode(m) {
        if (recording) {
            say(I18n.t("Сначала останови запись", "Stop the recording first"));
            return;
        }
        if (plugin)
            plugin.set("mode", m === "video" ? "video" : "photo");
    }

    function fmtMs(ms) {
        const s = Math.floor((ms || 0) / 1000);
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60);
        return (h ? h + ":" + ("0" + m).slice(-2) : String(m)) + ":" + ("0" + s % 60).slice(-2);
    }

    // ==== тело: экран с кадром + приборная панель (одно на обе темы) ====
    component AppBody: Item {
        id: body

        readonly property bool mac: app.macLook

        // ---- экран ----
        Item {
            id: viewport
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: deck.top
            anchors.bottomMargin: app.spacing

            PxBox {
                anchors.fill: parent
                visible: !body.mac
                sunken: true
                color: Theme.desk
            }
            Rectangle {
                anchors.fill: parent
                visible: body.mac
                radius: GoldenGate.px(10)
                color: GoldenGate.contentBg
                border.width: 1
                border.color: GoldenGate.separator
            }

            VideoOutput {
                id: view
                anchors.fill: parent
                anchors.margins: body.mac ? GoldenGate.px(6) : Theme.u
                fillMode: VideoOutput.PreserveAspectFit
                // кадр отдаём этой CaptureSession у корня (id наружу не виден)
                Component.onCompleted: app.viewSurface = view
                Component.onDestruction: app.viewSurface = null
                // Qt сам камеру не зеркалит («видеть себя» ожидают все); зрачку показываем
                // перевёрнуто, а плашки — REC, «Сохранил: …» — держим снаружи, не зеркалим их
                transform: Scale {
                    xScale: app.mirror ? -1 : 1
                    origin.x: view.width / 2
                    origin.y: view.height / 2
                }
            }

            // вспышка кадра
            Rectangle {
                id: flashFx
                anchors.fill: parent
                color: "#ffffff"
                opacity: 0
                SequentialAnimation {
                    id: flash
                    NumberAnimation {
                        target: flashFx
                        property: "opacity"
                        to: 0.9
                        duration: 60
                    }
                    NumberAnimation {
                        target: flashFx
                        property: "opacity"
                        to: 0
                        duration: 320
                    }
                }
            }
            Connections {
                target: app
                function onFlashFramed() {
                    flash.restart();
                }
            }

            // ● REC и длительность — у верхнего края (виден только в видео)
            Row {
                visible: app.mode === "video"
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.margins: body.mac ? GoldenGate.px(10) : Theme.u * 2
                spacing: body.mac ? GoldenGate.px(8) : Theme.u * 2

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: body.mac ? GoldenGate.px(10) : Theme.u * 2
                    height: width
                    radius: body.mac ? width / 2 : 0
                    color: app.recording ? Theme.danger : body.mac ? GoldenGate.tertiaryLabel : Theme.mix(Theme.textDim, Theme.desk, 0.4)
                    opacity: app.recording ? 1 : 0.6
                    SequentialAnimation on opacity {
                        running: app.recording && app.visible
                        loops: Animation.Infinite
                        NumberAnimation {
                            to: 0.25
                            duration: Skin.ms(900)
                        }
                        NumberAnimation {
                            to: 1
                            duration: Skin.ms(900)
                        }
                    }
                }
                PxText {
                    text: app.recording ? I18n.t("ЗАПИСЬ ", "REC ") + app.fmtMs(app.rec.duration) : I18n.t("видео не пишется", "idle")
                    kind: "tiny"
                    color: body.mac ? GoldenGate.label : Theme.text
                }
            }

            // нет кадра — камера ещё поднимается, сломалась или её нет вовсе
            Column {
                anchors.centerIn: parent
                visible: app.camBroken || !app.currentCam || app.warming
                spacing: app.spacing

                PxText {
                    text: app.camBroken ? String(cam.errorString) : app.currentCam ? I18n.t("Открываю камеру…", "Opening the camera…") : I18n.t("Камер система не видит", "The system sees no camera")
                    kind: "body"
                    color: app.camBroken ? Theme.danger : body.mac ? GoldenGate.secondaryLabel : Theme.textDim
                    horizontalAlignment: Text.AlignHCenter
                }
                PxButton {
                    text: I18n.t("Обновить", "Refresh")
                    icon: "refresh"
                    compact: true
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: {
                        app.refreshCam();
                        app.ensureDirs();
                        app.note = "";
                    }
                }
            }

            // сообщение («Сохранил: …», «Дозаписываю файл…»)
            PxText {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: body.mac ? GoldenGate.px(10) : Theme.u * 2
                visible: app.note !== ""
                text: app.note
                kind: "body"
                color: body.mac ? GoldenGate.label : Theme.text
                elide: Text.ElideMiddle
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // ---- приборная панель ----
        Column {
            id: deck
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: app.spacing

            Rectangle {
                width: parent.width
                height: 1
                color: Skin.separator
            }

            // камеры и микрофоны — списком, с кнопками рядом
            Flow {
                spacing: app.spacing
                anchors.horizontalCenter: parent.horizontalCenter

                PxCombo {
                    width: Skin.px(290)
                    model: app.cams.map(d => ({
                                "label": app.camName(d),
                                "value": app.camName(d)
                            }))
                    // в поле — то, что снимает на самом деле: пусто в настройках — умолчание
                    currentValue: app.camName(app.pendingCam || app.currentCam)
                    placeholder: I18n.t("нет камер", "no cameras")
                    enabled: app.cams.length > 0
                    onActivated: name => app.pickCamera(String(name))
                }
                PxButton {
                    icon: "rotate"
                    compact: true
                    enabled: app.cams.length > 1       // стрелка имеет смысл от двух камер
                    onClicked: app.cycleCamera()
                }
                PxCombo {
                    width: Skin.px(260)
                    model: app.mics.map(d => ({
                                "label": app.micName(d),
                                "value": String(d.description || "")
                            }))
                    // то же правило, что у камер: покажем выбранное, даже если заведём после записи
                    currentValue: app.pendingMic || (app.chosenMic ? String(app.chosenMic.description || "") : "")
                    placeholder: I18n.t("нет микрофонов", "no microphones")
                    enabled: app.mics.length > 0
                    onActivated: name => app.pickMic(String(name))
                }
                PxButton {
                    icon: app.micOn ? "mic" : "micMute"
                    compact: true
                    enabled: app.mics.length > 0
                    onClicked: app.toggleMic()
                }
            }

            Row {
                spacing: app.spacing
                anchors.horizontalCenter: parent.horizontalCenter

                PxSegmented {
                    model: [
                        {
                            "label": I18n.t("Фото", "Photo"),
                            "value": "photo",
                            "icon": "camera"
                        },
                        {
                            "label": I18n.t("Видео", "Video"),
                            "value": "video",
                            "icon": "play"
                        }
                    ]
                    currentValue: app.mode
                    onActivated: v => app.setMode(String(v))
                }

                PxButton {
                    accent: true
                    danger: app.mode === "video" && app.recording
                    height: Skin.px(34)
                    text: app.mode === "photo" ? I18n.t("Снять фото", "Take a photo") : app.recording ? I18n.t("Остановить запись", "Stop") : I18n.t("Начать видео", "Record")
                    icon: app.mode !== "photo" && !app.recording ? "play" : ""
                    onClicked: app.mode === "photo" ? app.shoot() : app.playVideo()
                }

                PxButton {
                    icon: "folder"
                    compact: true
                    onClicked: app.openFolder()
                }
            }
        }
    }

    // ==== хосты: рамка окна той или иной темы ====
    Loader {
        active: !app.macLook
        anchors.fill: parent
        sourceComponent: pxHost
    }
    Loader {
        active: app.macLook
        anchors.fill: parent
        sourceComponent: macHost
    }

    Component {
        id: pxHost
        PxWindow {
            anchors.fill: parent
            title: Skin.title(I18n.t("Камера", "Camera"))
            icon: "camera"

            onCloseClicked: app.requestClose()

            // всё что внутри — тело; рамку, фаску и «Камера.exe» рисует PxWindow
            AppBody {
                anchors.fill: parent
            }
        }
    }

    Component {
        id: macHost
        MacGlass {
            anchors.fill: parent
            anchors.margins: GoldenGate.px(12)
            radius: GoldenGate.panelRadius
            fill: GoldenGate.glass(0.4)
            shadow: false                 // тень на окне уже ставит niri (правило Golden Gate)

            Column {
                anchors.fill: parent

                // заголовок: красный «светофор» слева (он и есть крестик), имя по центру —
                // светофор как в modules/settings/views/MacView.qml: токены, глянец, крест по наведению
                Item {
                    width: parent.width
                    height: GoldenGate.px(38)
                    Rectangle {
                        id: light
                        width: GoldenGate.px(12)
                        height: width
                        x: GoldenGate.px(20)
                        anchors.verticalCenter: parent.verticalCenter
                        radius: width / 2
                        color: GoldenGate.lights[0]
                        border.width: 1
                        border.color: Qt.rgba(0, 0, 0, 0.14)
                        HoverHandler {
                            id: closeHover
                        }
                        Rectangle {
                            x: parent.width * 0.2
                            y: parent.height * 0.08
                            width: parent.width * 0.6
                            height: parent.height * 0.42
                            radius: height / 2
                            color: Qt.rgba(1, 1, 1, 0.35)
                        }
                        MacIcon {
                            visible: closeHover.hovered
                            anchors.centerIn: parent
                            name: "x"
                            size: parent.width * 0.7
                            stroke: 3
                            color: Qt.rgba(0, 0, 0, 0.55)
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: app.requestClose()
                        }
                        Accessible.role: Accessible.Button
                        Accessible.name: I18n.t("Закрыть камеру", "Close the camera")
                        Accessible.onPressAction: app.requestClose()
                    }

                    PxText {
                        anchors.centerIn: parent
                        text: I18n.t("Камера", "Camera")
                        kind: "title"
                        color: GoldenGate.label
                    }
                }
                Rectangle {
                    width: parent.width
                    height: 1
                    color: GoldenGate.separator
                }
                Item {
                    width: parent.width
                    height: parent.height - GoldenGate.px(38) - 1

                    AppBody {
                        anchors.fill: parent
                    }
                }
            }
        }
    }
}
