# Hörblatt (App)

Arbeitsblätter auf dem iPad hören statt lesen – für ein Kind, das noch nicht lesen und schreiben kann: Blatt
fotografieren (oder eine PDF öffnen), Wort oder Satz antippen und vorlesen lassen, Antworten in die Lücken sprechen,
markieren, mit dem Stift ankreuzen, und das fertige Blatt als PDF abgeben. Texterkennung und alle Daten bleiben auf
dem iPad.

Dieses Repository enthält nur die laufende App. Es wird aus dem (privaten) Entwicklungs-Repository erzeugt;
Änderungen bitte dort.

## iPad-App (Swift Playgrounds) – der Hauptweg

`ios/Hoerblatt.swiftpm` ist das Hörblatt als iPad-App: Texterkennung mit Apples Vision (dieselbe wie Live Text),
Vorlesen mit den Stimmen des iPads, eigene Spracherkennung, Stift (PencilKit).

### Erstes Mal aufs iPad
1. In Safari `Hoerblatt.swiftpm.zip` aus diesem Repository laden (Datei antippen → „Raw“ bzw. herunterladen) –
   oder grüner Knopf „Code“ → „Download ZIP“ für das ganze Repository.
2. In der Dateien-App die ZIP antippen (sie wird entpackt) und den Ordner an einen festen Platz legen,
   z. B. „Auf meinem iPad › Hoerblatt“.
3. `Hoerblatt.swiftpm` (beim ganzen Repository unter `ios`) antippen → öffnet sich in Swift Playgrounds → ▶︎.
   Beim ersten Mal fragt das iPad nach Kamera, Mikrofon und Spracherkennung.

### Updates
Die App sucht selbst nach einer neuen Version (liest nur `version.json` aus diesem Repository, sendet nichts;
abschaltbar). Gibt es eine, zeigt das Zahnrad einen blauen Punkt.
- Einmal: Zahnrad 1 s drücken → „Installierte Version“ → „Projektordner wählen …“ → den Ordner wählen, in dem das
  Projekt liegt (z. B. „Hoerblatt“; die App findet `Hoerblatt.swiftpm` auch in Unterordnern).
- Dann: „Jetzt aktualisieren“ → die neue Fassung wird geprüft und eingespielt, die vorige bleibt als
  „Hoerblatt Sicherung (vorige Version)“ daneben. Danach das Projekt in Swift Playgrounds schließen und neu öffnen.
- Mappe, Antworten, Schrank und Einstellungen bleiben bei jedem Update erhalten.

Zeigt Swift Playgrounds rote Fehlermeldungen: Screenshot an die Entwicklung schicken.

### Bedienung kurz
- Unten: 1 Foto · 2 Wort (daneben Satz) · 3 Sprechen · 4 Markieren · Stift · Radiergummi · Zurück · 5 Fertig
  (Nummern und Farben wie auf der Bildkarte; einzelne Werkzeuge lassen sich ausblenden).
- Oben: Mappe (Ordner), die Seiten von heute, im Querformat „zwei Seiten“, Zahnrad (1 s drücken) für Lehrkräfte.
- Mappe: zeigt nur, was heute ausgegeben ist; „Schreibblatt“ für freies Schreiben ohne Linien.
- Schrank (in der Mappe, 1 s drücken, nur Lehrkräfte): alles Übrige, Ausgeben/Weglegen, Fächer, „PDF öffnen“.
  Am Ende des Tages kommt alles von selbst in den Schrank.
- Fertig: das Kind zeigt das Blatt der Lehrkraft (Daumen) und tippt auf „Abgeben“ – die PDF wird im Abgabe-Ordner
  auf dem iPad gespeichert. AirDrop als Zusatz.
- Gesprochene Antworten lassen sich wie gedruckter Text vorlesen, markieren und Wort für Wort korrigieren.

## Web-Version (Notlösung)

`index.html` mit der Texterkennung in `tess/` ist die frühere Web-Version (wird nicht mehr weiterentwickelt).
Nutzung: Seite in Safari öffnen → Teilen → „Zum Home-Bildschirm“.

## Datenschutz
Fotos, Antworten, Markierungen und Stiftstriche bleiben auf dem iPad; die Texterkennung läuft auf dem Gerät.
Gesprochene Antworten erkennt Apple wie beim Tastatur-Diktat (ggf. auf Apples Servern). Ins Internet geht die
App nur für die Suche nach einer neuen Version.
