pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config
import qs.services
import qs.widgets

// Фоновый сервис «Камеры» — живёт, пока плагин включён.
//
// · IPC `qs -c angelos ipc call camera open|close|toggle`: сюда приходит и хоткей,
//   выбранный в настройках плагина, и пункт меню рабочего стола;
// · синхронизация niri-биндов: на странице настроек плагина записывают сочетания в
//   plugin.set("openKeys", [...]), здесь из них делается то же, что и из
//   Настройки → Горячие клавиши (services/Keybinds → scripts/keybinds.py);
// · окно камеры: FloatingWindow с App.qml внутри. Закрыть его можно только крестиком
//   окна (крестик сначала даст рекордеру дописать файл) либо системной комбинацией
//   закрытия — Win+Q в пиксельной теме, Mod+W в macOS (окно закрывает композитор).
Item {
    id: root

    property var plugin
    property bool open: false               // окно поднимается, когда это так

    IpcHandler {
        target: "camera"

        function open(): void {
            root.open = true;
        }
        function close(): void {
            root.open = false;
        }
        function toggle(): void {
            root.open = !root.open;
        }
    }

    LazyLoader {
        active: root.open && !!root.plugin
        FloatingWindow {
            id: win
            RightClickGuard {}

            title: Shell.appTitle + " · " + I18n.t("Камера", "Camera")
            visible: true
            color: "transparent"
            implicitWidth: 980
            implicitHeight: 680
            minimumSize: Qt.size(720, 500)
            // закрыли иначе (Win+Q, Alt+F4, шторка окон): окно умолкло умытым — ресурс
            // камеры отдаётся, когда весь LazyLoader исчезает
            onClosed: root.open = false
            onVisibleChanged: if (!visible)
                root.open = false

            App {
                id: app
                anchors.fill: parent
                plugin: root.plugin
                // грузим дужку: LazyLoader рассыпается — окно и CaptureSession уходят,
                // камера освобождается (App уже дал рекордеру дописать файл до сигнала)
                onCloseRequested: root.open = false
            }
        }
    }

    // ---- хоткеи: то, что записали в настройках плагина ----

    // сочетания, как их записали; нормализуем и убираем повторы
    readonly property var wanted: {
        if (!root.plugin)
            return [];
        const list = root.plugin.get("openKeys", []);
        const raw = (Array.isArray(list) ? list : [list]).map(String).filter(k => k && k.trim() !== "");
        const seen = {}, out = [];
        for (const k of raw) {
            const n = Keybinds.normKey(k);
            if (!seen[n]) {
                seen[n] = true;
                out.push(k);
            }
        }
        return out;
    }
    readonly property string wantSig: root.wanted.map(k => Keybinds.normKey(k)).join(" ;; ")
    readonly property string action: "spawn-sh " + JSON.stringify("qs -c angelos ipc call camera open")
    readonly property string title: "angelOS: " + I18n.t("Камера", "Camera")

    // чужие бинды с «camera» в пути переписывать нельзя — это наш, только если вызов полный
    function isMine(b) {
        return !!b.editable && (b.action.indexOf("ipc call camera") >= 0 || b.title === root.title);
    }

    property string triedFor: ""            // профиль+список, по которому уже пробовали писать

    // приводит бинды текущего профиля к списку: лишние удаляет, недостающие заводит
    function syncKeys() {
        if (!Keybinds.loaded || !root.plugin || Keybinds.busy)
            return;
        const state = Keybinds.profile + "|" + root.wantSig;
        if (root.triedFor === state)
            return;
        const mine = Keybinds.binds.filter(b => root.isMine(b));
        const held = mine.map(b => Keybinds.normKey(b.key));
        const ops = [];
        for (const b of mine)
            if (root.wantSig.split(" ;; ").indexOf(Keybinds.normKey(b.key)) < 0)
                ops.push({"op": "delete", "id": b.id});
        for (const w of root.wanted)
            if (held.indexOf(Keybinds.normKey(w)) < 0) {
                // сочетание занято чужим биндом — чужое не переписываем (в настройках про это скажут)
                if (Keybinds.bindFor(Keybinds.normKey(w), -1))
                    continue;
                ops.push({"op": "add", "key": w, "action": root.action, "title": root.title});
            }
        if (ops.length) {
            root.triedFor = state;
            Keybinds.apply(ops);
        }
    }

    onWantSigChanged: {
        root.triedFor = "";                 // новое желание — новая попытка
        root.syncKeys();
    }

    Connections {
        target: Keybinds
        function onLoadedChanged() {
            root.syncKeys();
        }
        function onBindsChanged() {
            root.syncKeys();
        }
        function onProfileChanged() {
            // смена темы — это другой файл профиля: хоткей надо завести и в нём
            Qt.callLater(root.syncKeys);
        }
    }

    Component.onCompleted: root.syncKeys()
}
