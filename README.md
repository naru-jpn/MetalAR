# MetalAR

AR application sample using Metal without SceneKit.

## Features

- [x] Render only by Metal
  - [x] Filter camera frame
  - [x] Draw objects in 3D space
- [x] Take a picture on background

## Files contained project

- `ShaderTypes.h`
  - Define types used from shaders and swift.
- `ViewController.swift`
  - Main view controller.
- `Context.swift` 
  - Context to store device, library, commandQueue, textureCache. 

### UI

- `Display.swift`
  - Class to draw texture on display.
- `ShadersDisplay.metal`
  - Declears shader functions to draw texture on display.
- `Shutter.swift`
- `ShutterButton.swift`

### Renderer

- `Shaders.metal`
  - Declears shader functions for off-screen rendering. 
- `Renderer.swift`
  - Class to manage objects and process GPU commands.
  
### MatrixOperations

- `MatrixOperations.swift`
  - Support operations of transform matrix.
