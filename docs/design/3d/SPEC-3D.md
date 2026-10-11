# 3D 主題規格（使用者提供的原文，2026-10-11）

```text
You are a senior macOS graphics engineer, creative technologist,
and interactive 3D visual designer.

We are working on an existing macOS application called Pulsefloat.

Pulsefloat is a floating audio visualizer that reacts to system audio.

The project already includes:
- Swift
- Core Graphics rendering
- SceneKit 3D rendering
- An audio analysis pipeline
- Multiple visualization themes
- A shared timing and rendering architecture
- Eight sculpture color styles
- Persistent theme settings
- Unit tests and performance requirements

Your task is to design and implement a new generation of
premium, audio-reactive 3D visualization themes.

The goal is to make Pulsefloat feel like a high-end audiovisual
art installation rather than a conventional spectrum analyzer.

IMPORTANT:
Do not redesign the entire application.
Preserve existing functionality and architecture where possible.

Read the existing project before making changes.

Read these files if available:
- CLAUDE.md
- docs/SPEC.md
- docs/REVIEW.md

Inspect the actual implementation rather than assuming
specific classes, interfaces, or file locations.

==================================================
1. DESIGN PHILOSOPHY
==================================================

We want visually impressive 3D audio-reactive sculptures.

The visual quality should resemble:

- Apple-quality macOS visual design
- Generative digital art
- High-end motion graphics
- Scientific visualization
- Futuristic audiovisual installations

Avoid:
- Basic spectrum bars disguised as 3D objects
- Cheap particle effects
- Excessively bright glow
- Random movement unrelated to audio
- Excessive visual clutter
- Flat-looking 3D geometry
- Low-quality lighting or materials

Each visualization should have:

1. A recognizable visual identity
2. Physically coherent motion
3. Smooth audio responsiveness
4. Depth and dimensionality
5. Carefully controlled lighting
6. Attractive compositions at different window sizes
7. High-quality rendering on Retina displays

The result should feel like a living sculpture.

==================================================
2. THREE NEW 3D THEMES
==================================================

THEME A: BLACK HOLE
-------------------

Create a cinematic black-hole-inspired 3D sculpture.

Visual composition:

- A central dark spherical object
- A rotating luminous accretion disk
- Multiple orbital particle streams
- Thin glowing concentric rings
- Subtle distortion-inspired visual effects
- Depth-dependent lighting
- Carefully controlled bloom-like highlights

The design should evoke a gravitational singularity.

Audio mapping:

Bass:
- Controls accretion disk thickness
- Causes the central dark region to pulse subtly
- Modulates inward/outward energy flow

Mid frequencies:
- Control orbital stream deformation
- Modulate the shape of surrounding rings

High frequencies:
- Trigger brief energy sparks
- Control fine particle luminosity

Beat / onset:
- Sends a radial energy pulse through the disk

Stereo information:
- Introduces subtle left/right asymmetry

Animation behavior:

Do not simply rotate everything at constant speed.

The sculpture should respond meaningfully to the sound.

When audio becomes silent:
- Stop all time-dependent visual motion
- Preserve the final visual state
- Do not continue rotating particle systems
- Do not keep updating random particle positions

Technical considerations:

Use SceneKit geometry, particle systems,
custom geometry, and shaders where appropriate.

If true gravitational lensing is too expensive,
use a visually convincing approximation.

Do not claim physically accurate lensing
unless the implementation actually provides it.


THEME B: PARTICLE SPHERE
------------------------

Create a futuristic 3D particle sphere.

Visual composition:

- Thousands of luminous particles
- A spherical or slightly irregular distribution
- Fine connecting lines where visually appropriate
- Several density layers
- A bright inner core
- A faint outer shell
- Smooth gradients and controlled highlights

The sphere should resemble a living energy organism.

Audio mapping:

Bass:
- Expands the overall particle sphere

Mid:
- Generates smooth localized deformations

Treble:
- Creates fine surface vibrations

Onset:
- Generates outward-propagating pulses

Frequency distribution:
- Controls different regions of the sphere

Optional:

Use spherical harmonics or procedural noise
to create coherent spatial deformation.

Important:

Avoid independently randomizing every particle.

Particles should form a stable, recognizable structure.

Use deterministic motion driven by audio.

The sphere must remain visually interesting
without excessive movement.


THEME C: AUDIO TERRAIN
----------------------

Create a continuously evolving 3D audio landscape.

Visual composition:

- A 3D wireframe or luminous mesh terrain
- Peaks and valleys representing frequency energy
- Multiple historical spectrum slices
- Perspective depth
- Subtle surface lighting
- A clean dark background
- Optional translucent filled surfaces

Axes:

X = Frequency
Y = Time / historical frames
Z = Frequency magnitude

Audio mapping:

- FFT bins determine terrain height
- New spectrum slices appear at the front
- Older slices move into the depth
- Strong bass produces broad mountain structures
- High-frequency content creates finer terrain features

Rendering:

Support two visual variants:

1. Wireframe landscape
2. Smooth translucent surface

Use a bounded historical buffer.

Avoid rebuilding unnecessary scene objects
on every frame.

When audio becomes silent:

The terrain must freeze.

Do not advance the historical buffer
or scroll the terrain while silent.

==================================================
3. SHARED AUDIO-REACTIVE ENGINE
==================================================

All 3D visualizations should use a shared,
well-defined audio feature interface.

Inspect the existing audio analysis pipeline first.

Reuse existing features wherever possible.

Potential signals:

- RMS / loudness
- Bass energy
- Mid energy
- Treble energy
- FFT frequency bins
- Spectral centroid
- Spectral flux
- Onset / beat intensity
- Stereo balance

Do not introduce redundant FFT computations
inside individual theme renderers.

Implement smoothing when needed.

Use separate attack and release behavior
to avoid excessive jitter.

Ensure animation remains responsive.

Preserve the application's existing silence detection.

A crucial requirement:

SILENCE MUST PRODUCE A STATIC IMAGE.

No camera drifting.
No continuous rotation.
No particle movement.
No procedural time animation.
No unnecessary scene updates.

Visual parameters should change only when
the relevant audio state changes.

==================================================
4. CAMERA AND PRESENTATION
==================================================

Support two presentation modes.

MODE A: COMPACT FLOATING VISUALIZER

This is the existing compact floating window.

Requirements:

- Maintain a clean silhouette
- Preserve readability at small heights
- Avoid excessive particles
- Use simplified geometry where needed
- Ensure the theme remains recognizable

MODE B: 3D SCULPTURE VIEW

A larger floating visualization.

Requirements:

- Full 3D composition
- Cinematic camera angle
- Depth-aware lighting
- Larger particle counts where appropriate
- More detailed geometry

If the project already has an equivalent
presentation mode, integrate with it.

Do not create duplicate window systems.

Optional interaction:

- Mouse drag to rotate the sculpture
- Scroll to zoom
- Reset camera
- Automatic framing

Camera movement must not interfere with
the silence-freeze requirement.

Explicit user interaction is allowed to
change the camera while silent.

==================================================
5. LIGHTING AND MATERIALS
==================================================

Create premium-quality materials.

Support the existing eight sculpture color styles.

Do not create a conflicting color preference system.

Consider:

- Emissive materials
- Transparent surfaces
- Layered luminosity
- Fresnel-like edge highlights
- Depth-based attenuation
- Subtle gradients
- Metallic reflections where appropriate

Avoid excessive bloom.

Maintain clear contrast in both:

- Dark backgrounds
- Light backgrounds

The application should still look polished
without expensive post-processing effects.

==================================================
6. RENDERING PERFORMANCE
==================================================

Performance is critical.

The existing project targets approximately
2 ms per frame for renderer-side processing.

Preserve this budget where feasible.

Measure performance in Release builds.

Report CPU render/update cost separately
from GPU rendering cost when possible.

Do not claim that CPU timing measures GPU cost.

Target smooth animation at 60 FPS
on the supported Apple Silicon hardware.

Use appropriate optimization techniques:

- Geometry reuse
- Buffer reuse
- Batched updates
- Reduced SceneKit node count
- Efficient particle representation
- Adaptive quality levels
- Avoiding per-frame memory allocations
- Minimizing main-thread work

Consider three quality levels:

LOW:
Simplified geometry and particles.

MEDIUM:
Balanced visual quality and performance.

HIGH:
Full 3D details and effects.

If the requested quality is too expensive,
implement a reasonable fallback.

Do not sacrifice application responsiveness
for visual complexity.

==================================================
7. THEME SYSTEM INTEGRATION
==================================================

Integrate the new themes into the existing
theme selection system.

Expected themes:

- Black Hole
- Particle Sphere
- Audio Terrain

Preserve existing themes.

Support:

- Theme switching
- Theme previews / thumbnails
- Persistent selection
- Existing color styles
- Existing settings behavior

Use the existing localization conventions.

Do not create placeholder menu entries
without working renderers.

==================================================
8. VISUAL DESIGN EXPLORATION
==================================================

Before implementing all three themes,
produce a visual design exploration.

For each theme, provide:

1. A concept description
2. A proposed visual composition
3. A camera configuration
4. A material and lighting plan
5. An audio-to-visual mapping table
6. A performance-risk assessment

Create visual prototypes wherever practical.

Prefer actual renderer-generated screenshots
over unrelated reference images.

Generate screenshots for:

- Dark mode
- Light mode
- Compact mode
- Sculpture mode

The screenshots should represent what
the implemented application can actually render.

Do not substitute concept art for implementation evidence.

==================================================
9. DEVELOPMENT WORKFLOW
==================================================

First inspect the repository.

Identify:

- Existing theme architecture
- SceneKit integration
- Rendering interfaces
- Audio feature data
- Window management
- Settings persistence
- Tests
- Build commands

Then propose a minimal integration design.

If parallel development is appropriate:

Use separate Git worktrees for the three themes.

Agent A:
Black Hole

Agent B:
Particle Sphere

Agent C:
Audio Terrain

Shared architecture changes should be completed
before parallel implementations begin.

Avoid conflicting edits to shared files.

Do not overwrite uncommitted user changes.

Do not interfere with other ongoing agents
or worktrees.

Each agent must:

- Build successfully
- Pass relevant tests
- Verify silence behavior
- Inspect actual screenshots
- Report performance measurements

After the implementations are ready:

- Integrate the themes
- Run the full test suite
- Resolve integration issues
- Inspect visual quality
- Measure Release performance

Do not repeatedly launch the application
from multiple agents.

Only the coordinating agent should perform
the final interactive app launch.

==================================================
10. ACCEPTANCE CRITERIA
==================================================

The implementation is complete when:

[ ] All three themes are selectable
[ ] Each theme has genuine 3D visual structure
[ ] Themes respond to real audio features
[ ] Silence freezes visual motion
[ ] Existing themes still work
[ ] Existing settings remain compatible
[ ] Compact presentation works
[ ] Sculpture presentation works
[ ] Theme switching is stable
[ ] Dark/light backgrounds are supported
[ ] Tests pass
[ ] Performance is measured
[ ] Screenshots are available
[ ] No known crashes or major rendering defects

Do not report completion if these criteria
have not been verified.

Clearly distinguish implemented features,
visual approximations, and future improvements.

==================================================
11. FUTURE EXPANSION
==================================================

Design the architecture so that additional
3D themes can be added later.

Potential future themes:

- Liquid Glass
- Crystal Growth
- Vortex
- Neural Network
- 3D Spectrogram
- Energy Tunnel
- Ferrofluid
- Procedural Flower

Do not implement these additional themes now.

Focus on making the first three exceptional.

==================================================
12. FINAL DELIVERABLES
==================================================

Provide:

1. Architecture summary
2. Implementation summary
3. Screenshots for each theme
4. Performance measurements
5. Test results
6. Known limitations
7. Recommendations for future visual improvements

Visual quality is a primary requirement.

I would rather have three exceptional,
high-quality 3D audio visualizations
than ten mediocre ones.

Start by inspecting the repository and
explaining the proposed integration architecture.

Then proceed with the visual prototypes
and implementation.
```
