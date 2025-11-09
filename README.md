# 🎮 UntoldArcade

**UntoldArcade** is a collection of demo games built with the [Untold Engine](https://github.com/untoldengine/UntoldEngine).  
These demos give game developers a **quick look** at what the engine can do.

The demos included are:

- ⚽ **SoccerArcade** – a small macOS arcade-style soccer prototype showcasing the engine's ECS, rendering, and input systems.
- 🥽 **UntoldAR** – an AR demo showcasing augmented reality capabilities on iOS devices.
- 🌐 **UntoldImmersive** – an immersive demo built for Apple Vision Pro, demonstrating spatial computing features.
- 🛠️ **SceneBuilder** – a declarative scene-building demo using SwiftUI-style syntax to construct 3D scenes programmatically.

---

## ⚙️ Requirements

- **Xcode 26.1** or later
- **macOS 26.01+** (for macOS demos)
- **iOS 26.01+** (for iOS/AR demos)
- **visionOS 26.01+** (for Vision Pro demos)
- Metal-capable GPU

---

## 🚀 Getting Started

### 1. Clone the repo
```bash
git clone https://github.com/untoldengine/UntoldArcade.git
cd UntoldArcade
```

### 2. Open a demo project
Each demo is a standalone Xcode project. Navigate to the demo folder and open the `.xcodeproj` file:

```bash
# For SoccerArcade
open SoccerArcade/SoccerArcade.xcodeproj

# For UntoldAR
open UntoldAR/UntoldAR.xcodeproj

# For UntoldImmersive (requires Vision Pro simulator or device)
open UntoldImmersive/UntoldImmersive.xcodeproj

# For SceneBuilder
open SceneBuilder/SceneBuilder.xcodeproj
```

### 3. Build and run
- Select your target device (Mac, iPhone, iPad, or Vision Pro simulator)
- Press `⌘R` to build and run
- SPM will automatically fetch the Untold Engine dependency on first build

## 🔗 Engine Dependency

Each demo project depends on the Untold Engine via Swift Package Manager (SPM).

Game developers: The workspace is already configured to fetch the engine from its develop branch on GitHub.

## 📂 Project Structure

```bash
UntoldArcade/
├── SoccerArcade/              # Arcade-style soccer game
│   ├── Sources/               # Game source code
│   └── Resources/             # Game assets
├── UntoldAR/                  # AR demo for iOS
│   ├── Sources/               # Game source code
│   └── Resources/             # Game assets
├── UntoldImmersive/           # Vision Pro immersive demo
│   ├── Sources/               # Game source code
│   └── Resources/             # Game assets
└── SceneBuilder/              # Declarative scene-building demo
    ├── Sources/               # Demo source code
    └── Resources/             # Demo assets
```

## Untold Editor

The demo game scenes in this repo were created using **[UntoldEditor](https://github.com/untoldengine/UntoldEditor)**, the official scene editor for Untold Engine.  

**UntoldEditor** gives developers a visual way to:
- Import and organize assets (models, textures, animations, sounds).
- Place entities, lights, and cameras into a scene.
- Attach components and configure properties.
- Save scenes to a JSON/scene file format that games can load at runtime.
- Preview gameplay directly in the editor before exporting.

This means the demos here (like **SoccerArcade**) aren’t just sample code — they also showcase the workflow:
1. Build and preview a scene in **UntoldEditor**.  
2. Load the scene into a demo game.  
3. Run it in Xcode to see the editor-authored content come alive with the engine.  


## 🤝 Contributing

We welcome contributions! If you’d like to:
- Add a new demo game
- Improve existing demos
- Enhance documentation

Please fork the repo, open a PR, or join discussions in the [Untold Engine repo](https://github.com/untoldengine/UntoldEngine).

📜 License

This project follows the same license as Untold Engine.

See the LICENSE file for details.
