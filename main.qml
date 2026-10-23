import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import org.qfield
import org.qgis
import Theme

/**
 * Grenzpunkt-Foto – QField-Plugin
 *
 * 1. Foto aufnehmen
 * 2. Grenzpunkt aus dem ALKIS-Layer wählen (nächste Punkte zur aktuellen Position)
 * 3. Das Foto bekommt die Koordinaten GENAU DIESES Punktes als EXIF-Geotag,
 *    optional einen Info-Stempel ins Bild und wird als
 *    DCIM/Grenzpunkte/<Punktkennung>_<Zeit>.jpg im Projektordner abgelegt.
 *
 * Das QGIS-Plugin „Absteckprotokoll“ ordnet diese Fotos dann automatisch zu
 * (Punktkennung im Dateinamen bzw. exakte GPS-Position im Foto).
 */
Item {
  id: plugin

  property var mainWindow: iface.mainWindow()
  property var positionSource: iface.findItemByObjectName('positionSource')

  readonly property string settingsPrefix: "grenzpunktFoto/"
  readonly property real searchRadius: 60          // Meter um die aktuelle Position
  readonly property int maxCandidates: 8

  property var pointLayer: null
  property string idField: ""
  property string pendingPhoto: ""
  property string referenceText: ""

  Component.onCompleted: {
    iface.addItemToPluginsToolbar(photoButton)
    restoreLayer()
  }

  Connections {
    target: iface
    function onLoadProjectEnded(path, name) {
      plugin.restoreLayer()
    }
  }

  // ------------------------------------------------------------------ Hilfen

  function toast(msg, type) {
    mainWindow.displayToast(msg, type === undefined ? 'info' : type)
  }

  function projectKey() {
    return qgisProject.fileName ? settingsPrefix + qgisProject.fileName : ""
  }

  function pointLayers() {
    const result = []
    const layers = ProjectUtils.mapLayers(qgisProject)
    for (const id in layers) {
      const l = layers[id]
      try {
        if (l && l.geometryType && l.geometryType() === Qgis.GeometryType.Point)
          result.push(l)
      } catch (e) {}
    }
    result.sort((a, b) => a.name.localeCompare(b.name))
    return result
  }

  function guessIdField(layer) {
    if (!layer)
      return ""
    const names = layer.fields.names
    const wanted = ["pkn", "punktkennung", "punktnummer", "punkt", "pid", "name", "nr", "id"]
    for (const w of wanted) {
      for (const n of names) {
        if (n.toLowerCase() === w)
          return n
      }
    }
    return ""
  }

  function guessLayer() {
    const ls = pointLayers()
    for (const l of ls) {
      if (l.fields.names.indexOf("pkn") >= 0)
        return l
    }
    for (const l of ls) {
      if (l.name.toLowerCase().indexOf("grenzpunkt") >= 0)
        return l
    }
    return ls.length > 0 ? ls[0] : null
  }

  function setLayer(layer) {
    pointLayer = layer
    idField = guessIdField(layer)
    const key = projectKey()
    if (key !== "" && layer)
      settings.setValue(key, layer.id)
  }

  function restoreLayer() {
    pointLayer = null
    idField = ""
    if (!qgisProject.fileName)
      return
    const savedId = settings.value(projectKey(), "")
    const layers = ProjectUtils.mapLayers(qgisProject)
    if (savedId !== "" && layers[savedId]) {
      setLayer(layers[savedId])
      return
    }
    const g = guessLayer()
    if (g)
      setLayer(g)
  }

  function sanitize(s) {
    return String(s).replace(/[^0-9A-Za-zÄÖÜäöüß_\-]+/g, "_")
  }

  function pad(n) {
    return (n < 10 ? "0" : "") + n
  }

  function timestamp() {
    const d = new Date()
    return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) + "_" + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds())
  }

  function fmt(v, dec) {
    return Number(v).toFixed(dec).replace(".", ",")
  }

  // Bezugsposition im KBS des Punkte-Layers: GNSS, sonst Kartenmitte
  function referencePoint() {
    const crs = pointLayer.crs
    if (positionSource && positionSource.active) {
      const pi = positionSource.positionInformation
      if (pi && pi.latitudeValid && pi.longitudeValid) {
        referenceText = qsTr("zur aktuellen Position")
        return GeometryUtils.reprojectPoint(GeometryUtils.point(pi.longitude, pi.latitude), CoordinateReferenceSystemUtils.wgs84Crs(), crs)
      }
    }
    const ms = iface.mapCanvas().mapSettings
    referenceText = qsTr("zur Kartenmitte (keine Position)")
    return GeometryUtils.reprojectPoint(ms.center, ms.destinationCrs, crs)
  }

  function findCandidates() {
    const ref = referencePoint()
    const r = searchRadius
    const rect = GeometryUtils.createRectangleFromPoints(GeometryUtils.point(ref.x - r, ref.y - r), GeometryUtils.point(ref.x + r, ref.y + r))
    const it = LayerUtils.createFeatureIteratorFromRectangle(pointLayer, rect)
    const list = []
    while (it.hasNext()) {
      const f = it.next()
      const p = GeometryUtils.centroid(f.geometry)
      const d = GeometryUtils.distanceBetweenPoints(ref, p)
      let label = idField !== "" ? f.attribute(idField) : ""
      if (label === undefined || label === null || String(label) === "" || String(label) === "NULL")
        label = "FID " + f.id
      list.push({ label: String(label), x: p.x, y: p.y, distance: d })
    }
    it.close()
    list.sort((a, b) => a.distance - b.distance)
    return list.slice(0, maxCandidates)
  }

  function assignPhoto(cand) {
    const path = pendingPhoto
    if (path === "" || !FileUtils.fileExists(path)) {
      toast(qsTr("Foto nicht gefunden"), 'error')
      return
    }
    const crs = pointLayer.crs

    // 1) EXIF-Geotag = Koordinate des gewählten Grenzpunkts
    const wgs = GeometryUtils.reprojectPointToWgs84(GeometryUtils.point(cand.x, cand.y), crs)
    const info = PositioningUtils.createGnssPositionInformation(wgs.y, wgs.x, NaN, NaN, NaN, NaN, NaN, NaN, NaN, new Date(), "Grenzpunkt " + cand.label)
    FileUtils.addImageMetadata(path, info)

    // 2) optional Info-Stempel ins Bild
    if (stampSwitch.checked) {
      const geo = crs.isGeographic
      const dec = geo ? 8 : 2
      const d = new Date()
      const text = qsTr("Grenzpunkt %1").arg(cand.label) + "\n"
        + (geo ? "Lon " : "E ") + fmt(cand.x, dec) + "   " + (geo ? "Lat " : "N ") + fmt(cand.y, dec) + "   " + crs.authid + "\n"
        + pad(d.getDate()) + "." + pad(d.getMonth() + 1) + "." + d.getFullYear() + " " + pad(d.getHours()) + ":" + pad(d.getMinutes())
      FileUtils.addImageStamp(path, text)
    }

    // 3) in DCIM/Grenzpunkte/<Kennung>_<Zeit>.jpg ablegen
    const home = qgisProject.homePath
    platformUtilities.createDir(home, "DCIM")
    platformUtilities.createDir(home + "/DCIM", "Grenzpunkte")
    const suffix = FileUtils.fileSuffix(path) || "jpg"
    const target = home + "/DCIM/Grenzpunkte/" + sanitize(cand.label) + "_" + timestamp() + "." + suffix
    const ok = platformUtilities.renameFile(path, target)
    pendingPhoto = ""
    toast(ok ? qsTr("Foto Grenzpunkt %1 zugeordnet").arg(cand.label) : qsTr("Foto zugeordnet, Umbenennen fehlgeschlagen"), ok ? 'info' : 'warning')
  }

  function startCapture() {
    if (!qgisProject.fileName) {
      toast(qsTr("Bitte zuerst ein Projekt öffnen"), 'warning')
      return
    }
    if (!pointLayer) {
      openLayerChooser()
      return
    }
    cameraLoader.active = true
  }

  function openLayerChooser() {
    layerModel.clear()
    const ls = pointLayers()
    let current = 0
    for (let i = 0; i < ls.length; i++) {
      layerModel.append({ name: ls[i].name, layerId: ls[i].id })
      if (pointLayer && ls[i].id === pointLayer.id)
        current = i
    }
    if (ls.length === 0) {
      toast(qsTr("Kein Punkte-Layer im Projekt"), 'warning')
      return
    }
    layerCombo.currentIndex = current
    layerPopup.open()
  }

  // ------------------------------------------------------------------ Button

  QfToolButton {
    id: photoButton
    bgcolor: Theme.darkGray
    iconSource: Theme.getThemeVectorIcon('ic_camera_photo_black_24dp')
    iconColor: Theme.mainColor
    round: true

    onClicked: plugin.startCapture()
    onPressAndHold: plugin.openLayerChooser()
  }

  // ------------------------------------------------------------------ Kamera

  Loader {
    id: cameraLoader
    active: false
    sourceComponent: Component {
      QfCamera {
        id: camera
        visible: false

        Component.onCompleted: {
          camera.state = 'PhotoCapture'
          open()
        }

        onFinished: path => {
          close()
          plugin.pendingPhoto = path
          candidateModel.clear()
          const cands = plugin.findCandidates()
          for (const c of cands)
            candidateModel.append(c)
          if (cands.length === 0) {
            plugin.toast(qsTr("Kein Grenzpunkt im Umkreis von %1 m – Foto liegt unzugeordnet in DCIM").arg(plugin.searchRadius), 'warning')
            plugin.pendingPhoto = ""
            return
          }
          pickPopup.open()
        }

        onCanceled: close()
        onClosed: cameraLoader.active = false
      }
    }
  }

  // ------------------------------------------------------------------ Punktauswahl

  ListModel {
    id: candidateModel
  }

  QfPopup {
    id: pickPopup
    parent: plugin.mainWindow.contentItem
    width: Math.min(420, plugin.mainWindow.width - 24)
    height: Math.min(pickColumn.implicitHeight + 32, plugin.mainWindow.height - 48)
    x: (plugin.mainWindow.width - width) / 2
    y: Math.max(24, (plugin.mainWindow.height - height) / 2)
    padding: 16
    modal: true
    closePolicy: Popup.CloseOnEscape

    onClosed: {
      if (plugin.pendingPhoto !== "") {
        plugin.toast(qsTr("Keine Zuordnung – Foto liegt unzugeordnet in DCIM"), 'warning')
        plugin.pendingPhoto = ""
      }
    }

    ColumnLayout {
      id: pickColumn
      anchors.fill: parent
      spacing: 8

      Label {
        Layout.fillWidth: true
        text: qsTr("Grenzpunkt zuordnen")
        font: Theme.strongFont
        color: Theme.mainTextColor
      }
      Label {
        Layout.fillWidth: true
        text: qsTr("Nächste Punkte %1 · %2").arg(plugin.referenceText).arg(plugin.pointLayer ? plugin.pointLayer.name : "")
        font: Theme.tipFont
        color: Theme.secondaryTextColor
        wrapMode: Text.WordWrap
      }

      ListView {
        id: candidateList
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(contentHeight, 360)
        clip: true
        model: candidateModel
        spacing: 6
        delegate: QfButton {
          required property int index
          required property string label
          required property real distance
          width: candidateList.width
          text: label + "   ·   " + (distance < 10 ? plugin.fmt(distance, 2) : plugin.fmt(distance, 0)) + " m"
          bgcolor: index === 0 ? Theme.mainColor : "transparent"
          color: index === 0 ? "white" : Theme.mainTextColor
          borderColor: Theme.mainColor
          onClicked: {
            plugin.assignPhoto(candidateModel.get(index))
            pickPopup.close()
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        Label {
          Layout.fillWidth: true
          text: qsTr("Punkt und Koordinaten ins Foto stempeln")
          font: Theme.defaultFont
          color: Theme.mainTextColor
          wrapMode: Text.WordWrap
        }
        QfSwitch {
          id: stampSwitch
          checked: settings.valueBool(plugin.settingsPrefix + "stamp", true)
          onToggled: settings.setValue(plugin.settingsPrefix + "stamp", checked)
        }
      }

      QfButton {
        Layout.fillWidth: true
        text: qsTr("Abbrechen")
        bgcolor: "transparent"
        color: Theme.secondaryTextColor
        onClicked: pickPopup.close()
      }
    }
  }

  // ------------------------------------------------------------------ Layerwahl

  ListModel {
    id: layerModel
  }

  QfPopup {
    id: layerPopup
    parent: plugin.mainWindow.contentItem
    width: Math.min(380, plugin.mainWindow.width - 24)
    height: layerColumn.implicitHeight + 32
    x: (plugin.mainWindow.width - width) / 2
    y: Math.max(24, (plugin.mainWindow.height - height) / 2)
    padding: 16
    modal: true

    ColumnLayout {
      id: layerColumn
      anchors.fill: parent
      spacing: 10

      Label {
        Layout.fillWidth: true
        text: qsTr("Grenzpunkte-Layer (ALKIS) wählen")
        font: Theme.strongFont
        color: Theme.mainTextColor
        wrapMode: Text.WordWrap
      }
      ComboBox {
        id: layerCombo
        Layout.fillWidth: true
        model: layerModel
        textRole: "name"
        font: Theme.defaultFont
      }
      Label {
        Layout.fillWidth: true
        text: qsTr("Wird pro Projekt gemerkt. Ändern: Kamera-Knopf lange drücken.")
        font: Theme.tipFont
        color: Theme.secondaryTextColor
        wrapMode: Text.WordWrap
      }
      QfButton {
        Layout.fillWidth: true
        text: qsTr("Übernehmen")
        onClicked: {
          const id = layerModel.get(layerCombo.currentIndex).layerId
          const layers = ProjectUtils.mapLayers(qgisProject)
          plugin.setLayer(layers[id])
          layerPopup.close()
          plugin.toast(qsTr("Grenzpunkte: %1 · Kennung: %2").arg(plugin.pointLayer.name).arg(plugin.idField !== "" ? plugin.idField : "FID"))
        }
      }
    }
  }
}
