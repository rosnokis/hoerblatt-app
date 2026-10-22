# Hörblatt (App)

Arbeitsblätter auf dem iPad hören statt lesen: fotografieren, Wort oder Satz antippen, Antworten sprechen,
markieren, fertiges Bild teilen. Texterkennung und alle Daten bleiben auf dem Gerät.

Dieses Repository enthält nur die laufende App (eine HTML-Seite und die Texterkennung in `tess/`).
Es wird aus dem Entwicklungs-Repository erzeugt; Änderungen bitte dort.

Nutzung: Seite in Safari öffnen → Teilen → „Zum Home-Bildschirm“.

## Native App (Swift Playgrounds)

`ios/Hoerblatt.swiftpm` ist das Hörblatt als iPad-App: Texterkennung mit Apples Vision (dieselbe wie Live Text),
Mappe mit allen Seiten, zwei Seiten nebeneinander im Querformat.

So kommt es aufs iPad:
1. In Safari diese Seite öffnen → grüner Knopf „Code“ → „Download ZIP“.
2. Dateien-App → Downloads → auf die ZIP-Datei tippen (sie wird entpackt).
3. Im entpackten Ordner nach `ios` gehen. Dort liegt `Hoerblatt` als ein einzelnes Paket-Symbol. Antippen → öffnet sich in Swift Playgrounds.
4. In Swift Playgrounds oben auf ▶︎ tippen. Beim ersten Mal fragt das iPad nach Kamera, Mikrofon und Spracherkennung.

Zeigt Swift Playgrounds rote Fehlermeldungen: Screenshot an die Entwicklung schicken (die App wurde ohne Compiler geschrieben).

Bedienung kurz: 1 Foto · 2 Wort (daneben: Satz) · 3 Sprechen · 4 Markieren · Stift · Radierer · Zurück · 5 Fertig.
Oben: Mappe (Ordner), die letzten Seiten, im Querformat „zwei Seiten“, Zahnrad (2 s drücken) für Lehrkräfte.
