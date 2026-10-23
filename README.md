# Grenzpunkt-Foto – QField-Plugin

Foto aufnehmen → Grenzpunkt aus dem ALKIS-Layer wählen → das Foto bekommt **genau die Koordinaten dieses Punktes** als EXIF-Geotag.

## Ablauf im Feld
1. Kamera-Knopf in der Plugin-Leiste antippen, Foto machen, bestätigen.
2. Liste der nächsten Grenzpunkte (bis 60 m um die aktuelle RTK-Position, ohne Position um die Kartenmitte) – der nächste ist grün hervorgehoben. Antippen.
3. Fertig: Das Foto liegt als `DCIM/Grenzpunkte/<Punktkennung>_<Datum_Zeit>.jpg` im Projektordner,
   mit den Punktkoordinaten im EXIF und – wenn eingeschaltet – mit Stempel „Grenzpunkt …, E/N, KBS, Datum“ im Bild.

## Einstellungen
- **Grenzpunkte-Layer:** wird beim ersten Mal erraten (Feld `pkn` bzw. Layername „Grenzpunkt…“) und pro Projekt gemerkt. Ändern: Kamera-Knopf **lange drücken**.
- **Punktkennung:** Feld `pkn`, sonst `punktkennung`, `punkt`, `name`, `nr`, `id`, sonst Feature-ID.
- **Stempel** ein/aus: Schalter im Auswahl-Dialog (wird gemerkt).

## Zusammenspiel mit dem QGIS-Plugin „Absteckprotokoll“
Fotos aus `DCIM/Grenzpunkte` einfach als Foto-Ordner hinzufügen – die Zuordnung klappt über die Punktkennung im Dateinamen
und über die exakte EXIF-Position.

Hinweis: In QField unter Einstellungen „Native Kamera verwenden“ ausschalten (sonst gehen EXIF-Daten verloren).
Benötigt QField 4.x.
