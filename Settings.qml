pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.config
import qs.services
import qs.widgets

// Страница Настройки → Плагины → Камера.
// Здесь записываются клавиши открытия: каждое сочетание уходит в plugin.set("openKeys", …),
// а фоновый сервис плагина (Main.qml) приводит к ним бинды niri тем же путём, каким
// это делает Настройки → Горячие клавиши (services/Keybinds). Остальное окно берёт
// сразу из настроек (App.qml читает их на ходу).

Column {
    id: page

    property var plugin
    width: parent ? parent.width : 400
    spacing: Skin.px(10)

    function keys() {
        const list = plugin ? plugin.get("openKeys", []) : [];
        return (Array.isArray(list) ? list : []).map(String).filter(k => k && k.trim() !== "");
    }
    function setKeys(list) {
        if (!plugin)
            return;
        const out = [], seen = {};
        for (const k of list.map(String)) {
            const n = Keybinds.normKey(k);
            if (!k.trim() || seen[n])
                continue;
            seen[n] = true;
            out.push(k.trim());
        }
        plugin.set("openKeys", out);
    }
    function addKey(combo) {
        setKeys(keys().concat([combo]));
    }
    function dropKey(norm) {
        setKeys(keys().filter(k => Keybinds.normKey(k) !== norm));
    }

    // запись сочетания: кнопки модификаторов + «нажми клавишу» — как в Настройках → Горячие клавиши
    component Recorder: Row {
        id: rec

        property var mods: ({
                "mod": true,
                "ctrl": false,
                "alt": false,
                "shift": false
            })
        property string key: ""
        readonly property string combo: Keybinds.compose(mods, key)
        readonly property var clash: combo ? Keybinds.bindFor(combo, -1) : null

        spacing: Theme.u * 2
        Repeater {
            model: [["mod", "Win"], ["ctrl", "Ctrl"], ["alt", "Alt"], ["shift", "Shift"]]
            PxButton {
                required property var modelData
                compact: true
                checked: !!rec.mods[modelData[0]]
                text: modelData[1]
                onClicked: {
                    const m = Object.assign({}, rec.mods);
                    m[modelData[0]] = !m[modelData[0]];
                    rec.mods = m;
                }
            }
        }
        PxText {
            text: "+"
            anchors.verticalCenter: parent.verticalCenter
        }
        // сфокусировать и нажать клавишу; модификаторы, зажатые вместе с ней, берутся тоже
        Item {
            id: catcher
            width: Theme.u * 52
            height: Theme.u * 13
            activeFocusOnTab: true

            PxBox {
                anchors.fill: parent
                sunken: true
                color: Theme.sunken
                edgeColor: catcher.activeFocus ? Theme.accent : Theme.edge
            }
            PxText {
                anchors.centerIn: parent
                width: parent.width - Theme.u * 4
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: catcher.activeFocus ? I18n.t("нажми клавишу…", "press a key…") : rec.key ? Keybinds.pretty(rec.key) : I18n.t("клавиша", "key")
                dim: !rec.key || catcher.activeFocus
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: catcher.forceActiveFocus()
            }
            Keys.onPressed: e => {
                e.accepted = true;
                if (e.key === Qt.Key_Escape && !(e.modifiers & ~Qt.KeypadModifier)) {
                    catcher.focus = false;
                    return;
                }
                if (Keybinds.isModifier(e))
                    return;
                const name = Keybinds.keyName(e);
                if (!name)
                    return;
                const m = Keybinds.mods(e);
                if (m.mod || m.ctrl || m.alt || m.shift)
                    rec.mods = m;
                rec.key = name;
                catcher.focus = false;
            }
        }
        PxField {
            width: Theme.u * 44
            placeholder: I18n.t("или имя", "or a name")
            onEdited: rec.key = text.trim()
        }
    }

    PxGroup {
        title: I18n.t("Клавиши открытия", "Opening keys")
        icon: "keyboard"
        width: parent.width

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Theme.u * 2

            Repeater {
                model: page.keys()
                delegate: SettingRow {
                    id: row
                    required property string modelData
                    // «свой» бинд — тот же признак, что и в Main.qml: полный вызов камеры или наш заголовок
                    readonly property bool hasIt: !!Keybinds.binds.find(b => b.editable && Keybinds.normKey(b.key) === Keybinds.normKey(row.modelData) && (b.action.indexOf("ipc call camera") >= 0 || b.title === "angelOS: " + I18n.t("Камера", "Camera")))

                    label: Keybinds.pretty(row.modelData)
                    hint: row.hasIt ? I18n.t("бинд в файле клавиш", "bound in the keys file") : I18n.t("бинда пока нет — приложение создаст при включении", "no bind yet — the app makes one when enabled")
                    PxButton {
                        text: I18n.t("Убрать", "Remove")
                        icon: "close"
                        compact: true
                        onClicked: page.dropKey(Keybinds.normKey(row.modelData))
                    }
                }
            }
        }

        PxText {
            visible: !page.keys().length
            text: I18n.t("Пока пусто — камера открывается из меню рабочего стола.", "Nothing yet — the camera opens from the desktop menu.")
            width: parent.width
            wrapMode: Text.Wrap
            kind: "tiny"
            color: Theme.textDim
        }

        SettingRow {
            label: I18n.t("Новое сочетание", "New combination")
            hint: addRec.clash ? I18n.t("⚠ занято: ", "⚠ in use: ") + Keybinds.describe(addRec.clash).label : I18n.t("кнопками выбери модификаторы, потом нажми клавишу в поле", "pick modifiers with the buttons, then press the key in the box")

            Recorder {
                id: addRec
            }
        }

        Row {
            spacing: Theme.u * 3
            PxButton {
                text: I18n.t("Добавить", "Add")
                icon: "plus"
                accent: true
                enabled: !Keybinds.busy && addRec.combo !== "" && !addRec.clash
                onClicked: {
                    page.addKey(addRec.combo);
                    addRec.key = "";
                }
            }
            PxText {
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.u * 220
                wrapMode: Text.Wrap
                text: Keybinds.log
                kind: "tiny"
                color: Keybinds.failed ? Theme.danger : Theme.textDim
            }
        }

        PxText {
            text: I18n.t("Бинды живут в профиле клавиш текущей темы (Настройки → Горячие клавиши); смена темы завезёт их и в другой профиль. Окно закрывается только крестиком или клавишей закрытия окна — Win+Q (в macOS Mod+W).", "Bindings live in the current theme's key profile (Settings → Shortcuts); when the theme changes, the app adds them to the other profile too. The window closes by the × or the system key (Win+Q; Mod+W on macOS).")
            width: parent.width
            wrapMode: Text.Wrap
            kind: "tiny"
            color: Theme.textDim
        }
    }

    PxGroup {
        title: I18n.t("Куда сохранять", "Folders")
        icon: "folder"
        width: parent.width

        SettingRow {
            label: I18n.t("Фото", "Photos")
            PxField {
                width: parent.width
                text: page.plugin ? String(page.plugin.get("photoDir", "") || "") : ""
                placeholder: I18n.t("~/Pictures/Photos", "~/Pictures/Photos")
                onEdited: if (page.plugin)
                    page.plugin.set("photoDir", text.trim())
            }
        }
        SettingRow {
            label: I18n.t("Видео", "Videos")
            PxField {
                width: parent.width
                text: page.plugin ? String(page.plugin.get("videoDir", "") || "") : ""
                placeholder: I18n.t("~/Videos/Camera", "~/Videos/Camera")
                onEdited: if (page.plugin)
                    page.plugin.set("videoDir", text.trim())
            }
        }
        PxText {
            text: I18n.t("Пусто — папка по умолчанию; папки появятся при первом снимке, «~» — дом.", "Empty — the default folder; folders appear with the first shot. “~” is the home.")
            width: parent.width
            wrapMode: Text.Wrap
            kind: "tiny"
            color: Theme.textDim
        }
    }

    PxGroup {
        title: I18n.t("Снимки и запись", "Shots and recording")
        icon: "camera"
        width: parent.width

        SettingRow {
            label: I18n.t("Формат снимков", "Shot format")
            PxSegmented {
                model: [
                    {
                        "label": "JPG",
                        "value": "jpg"
                    },
                    {
                        "label": "PNG",
                        "value": "png"
                    },
                    {
                        "label": "WebP",
                        "value": "webp"
                    }
                ]
                currentValue: page.plugin ? page.plugin.get("photoFormat", "jpg") : "jpg"
                onActivated: v => {
                    if (page.plugin)
                        page.plugin.set("photoFormat", v)
                }
            }
        }
        SettingRow {
            label: I18n.t("Качество записи", "Recording quality")
            PxSegmented {
                model: [
                    {
                        "label": I18n.t("Низкое", "Low"),
                        "value": "low"
                    },
                    {
                        "label": I18n.t("Обычное", "Normal"),
                        "value": "normal"
                    },
                    {
                        "label": I18n.t("Высокое", "High"),
                        "value": "high"
                    },
                    {
                        "label": I18n.t("Матёрое", "Max"),
                        "value": "max"
                    }
                ]
                currentValue: page.plugin ? page.plugin.get("quality", "high") : "high"
                onActivated: v => {
                    if (page.plugin)
                        page.plugin.set("quality", v)
                }
            }
        }
        SettingRow {
            label: I18n.t("Кадров в секунду", "Frames per second")
            hint: "0 — " + I18n.t("камера решит сама", "the camera's own choice")
            PxField {
                width: parent.width
                text: page.plugin ? String(Math.max(0, Number(page.plugin.get("fps", 0)) || 0)) : "0"
                onEdited: if (page.plugin)
                    page.plugin.set("fps", Math.max(0, Math.round(Number(text) || 0)))
            }
        }
        SettingRow {
            label: I18n.t("Контейнер видео", "Video container")
            hint: I18n.t("mkv переживает оборванную запись", "mkv survives a cut recording")
            PxSegmented {
                model: [
                    {
                        "label": "MP4",
                        "value": "mp4"
                    },
                    {
                        "label": "MKV",
                        "value": "mkv"
                    }
                ]
                currentValue: page.plugin ? page.plugin.get("container", "mp4") : "mp4"
                onActivated: v => {
                    if (page.plugin)
                        page.plugin.set("container", v)
                }
            }
        }
        SettingRow {
            label: I18n.t("Звук микрофона в видео", "Microphone sound in video")
            hint: I18n.t("и в окне его кнопка такая же", "the same switch lives in the window")
            PxCheck {
                checked: page.plugin ? !!page.plugin.get("micOn", true) : true
                onToggled: c => {
                    if (page.plugin)
                        page.plugin.set("micOn", c)
                }
            }
        }
        SettingRow {
            label: I18n.t("Кадр как в зеркале", "Preview as in a mirror")
            hint: I18n.t("только в окне: запись остаётся, как камера смотрит", "only the preview: the recording keeps the camera's own view")
            PxCheck {
                checked: page.plugin ? !!page.plugin.get("mirror", true) : true
                onToggled: c => {
                    if (page.plugin)
                        page.plugin.set("mirror", c)
                }
            }
        }
    }
}
