# 🎮 UntoldArcade

**UntoldArcade** is a collection of demo games built with the [Untold Engine](https://github.com/untoldengine/UntoldEngine).  
These demos give game developers a **quick look** at what the engine can do.

The first demo included is:

- ⚽ **SoccerArcade** – a small arcade-style soccer prototype showcasing the engine’s ECS, rendering, and input systems.

---

## 🚀 Getting Started

### 1. Clone the repo
```bash
git clone https://github.com/untoldengine/UntoldArcade.git
cd UntoldArcade
```

### 2. Open the workspace
Open the workspace in Xcode:

```bash
xed UntoldArcade.xcworkspace
```

(or double-click UntoldArcade.xcworkspace in Finder).

### 3. Select and run the game

- In the Xcode toolbar, select the SoccerArcade scheme.
- Choose your platform/device (macOS, iOS, or visionOS if supported).
- Press Run ▶️ to build and launch the demo.

## 🔗 Engine Dependency

Each demo project depends on the Untold Engine via Swift Package Manager (SPM).

Game developers: The workspace is already configured to fetch the engine from its develop branch on GitHub.

## 📂 Project Structure

```bash
UntoldArcade/
├── UntoldArcade.xcworkspace   # Workspace with all demos
├── SoccerArcade/              # First demo project
│   ├── Sources/               # Game source code
│   └── Resources/             # Game assets
└── Shared/                    # (optional) shared assets across demos
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
