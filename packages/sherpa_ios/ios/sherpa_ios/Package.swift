// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "sherpa_ios",
  platforms: [
    .iOS("15.0")
  ],
  products: [
    .library(name: "sherpa-ios", targets: ["sherpa_ios"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
    // Gemma 4 on device (Metal GPU); the same runtime the Android side uses.
    .package(url: "https://github.com/google-ai-edge/LiteRT-LM", exact: "0.18.1"),
  ],
  targets: [
    .target(
      name: "sherpa_ios",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        .product(name: "LiteRTLM", package: "LiteRT-LM"),
      ],
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    )
  ]
)
