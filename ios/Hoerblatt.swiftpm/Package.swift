// swift-tools-version: 5.9
// Hörblatt as a native iPad app for Swift Playgrounds: Vision reads the worksheet on the device, AVSpeechSynthesizer speaks.
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Hoerblatt",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "Hörblatt",
            targets: ["AppModule"],
            bundleIdentifier: "de.hoerblatt.app",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .openBook),
            accentColor: .presetColor(.teal),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [.portrait, .landscapeRight, .landscapeLeft],
            capabilities: [
                .camera(purposeString: "Das Hörblatt fotografiert das Arbeitsblatt, um es vorzulesen."),
                .photoLibrary(purposeString: "Zum Testen kann ein vorhandenes Foto eines Arbeitsblatts gewählt werden."),
                .microphone(purposeString: "Antworten werden gesprochen statt geschrieben."),
                .speechRecognition(purposeString: "Gesprochene Antworten werden in Text umgewandelt.")
            ]
        )
    ],
    targets: [
        .executableTarget(name: "AppModule", path: ".")
    ]
)
