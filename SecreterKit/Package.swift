// swift-tools-version: 6.2
import PackageDescription

let modules: [(name: String, deps: [String])] = [
    ("AzureCLI", []),
    ("AzureCore", []),
    ("AzureAuth", ["AzureCLI", "AzureCore"]),
    ("AzureARM", ["AzureCore", "AzureAuth"]),
    ("KeyVaultSecrets", ["AzureCore", "AzureAuth"]),
    ("Search", ["AzureCore", "AzureAuth", "AzureARM", "KeyVaultSecrets"]),
    ("Persistence", []),
]

let package = Package(
    name: "SecreterKit",
    platforms: [.macOS(.v26)],
    products: modules.map { .library(name: $0.name, targets: [$0.name]) },
    targets: modules.flatMap { module -> [Target] in
        [
            .target(name: module.name, dependencies: module.deps.map { .target(name: $0) }),
            .testTarget(name: "\(module.name)Tests", dependencies: [.target(name: module.name)]),
        ]
    }
)
