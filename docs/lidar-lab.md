# Experiment 1: iPhone LiDAR perception

Open **Lab** on the **On the can** phone. This screen is perception only: it does not plan a route, identify a person, or generate navigation commands. Camera frames, depth and corridor geometry stay on the iPhone. The Pi only supplies a motor inspection hold; no depth processing is sent to Python.

## Install and bench test

1. Update the Pi checkout and restart `python3 pi/server.py` so `/inspection` is available. Rebuild the Xcode app and install it on both phones. Existing Play/Locate/Connect behavior remains available outside Lab.
2. Choose On the can in Connect. Enter the Pi URL. Pair phones if you also want UWB; pairing is not required for the camera-only experiment.
3. Open Lab. It sends authenticated inspection-hold requests to the Pi using the existing token. Wait for **Pi confirmed · motors held stopped**. The Pi stops existing movement and rejects subsequent manual/Summon commands while held. Paired player UI also disables movement.
4. If the Pi hold cannot be confirmed, physically disconnect motor power before enabling the matching toggle. This permits standalone camera testing without a server; the app does not claim a remote stop it cannot confirm.
5. Mount the phone rigidly with rear cameras facing forward and slightly down, with the bucket/rim outside the forward view; self-occlusion masking is not implemented yet. Tap **Start LiDAR**, grant Camera access, and wait for **Normal** tracking. LiDAR depth is unavailable in Simulator or on devices without scene-depth support; that case shows an unavailable state.
6. Use the assumed orange-bucket dimensions: **30 cm width, 44 cm height**, with camera height provisionally **44 cm above the floor**. The floor reference initializes automatically on the first Normal-tracking frame and reinitializes after resets/interruptions; no calibration tap is required. If the camera is mounted higher, or wheels protrude beyond 30 cm, these assumptions must be updated before relying on the distances for navigation.
7. Place a box straight ahead at a tape-measured distance. Check **Nearest forward obstacle**. Move the box outside the yellow corridor, then remove it. The floor should not remain an obstacle. Check that poor depth or missing floor coverage reports **Unknown**.

Closing Lab stops its preview and requests hold release. Release never resumes a prior movement command: issue a new command explicitly. If the network drops before release, the Pi hold remains latched; restore the connection and open/close Lab, or restart the Pi server, to release it. Stop camera only stops the preview; the hold remains while Lab is open. Leaving/backgrounding the screen requests release and automatically initializes a new floor reference after a restarted AR session.

## What the screen means

- Camera preview at up to 30 fps; sampled depth analysis/overlay up to 5 Hz on a serial background queue.
- Red/orange/cyan dots show near/middle/far depth, not object identities. Green dots are close to the assumed floor. Low-confidence/missing depth is omitted, not treated as free.
- Yellow outline is a camera-forward, ground-plane corridor. Width = assumed 30 cm can width + 8 cm clearance per side = 46 cm. It begins 15 cm ahead of the camera's ground projection and looks ahead 3 m. This is an experimental footprint, not yet a calibrated vehicle model.
- Floor tolerance is ±6 cm. Candidate obstacles are 8 cm to 1.5 m above the assumed floor. Three medium/high-confidence samples in a grid cell are required to reject isolated noise. Low obstacles below 8 cm, overhead limits and unobserved geometry are not covered by this experiment.
- Grid cells are 25 cm long and five across the corridor. Observed floor distance extends through consecutive rows with floor samples in at least three of five columns and no supported obstacle cell. It is a diagnostic coverage heuristic, **not** proof that the full can can pass. Sparse/missing coverage remains unknown.
- AR heading is yaw relative to the session origin, not geographic compass heading. Obstacle distances are horizontal forward distances from the camera's ground projection, not distances from the bucket's front bumper.
- Readouts become unknown after 750 ms without a processed frame. Tracking limited/unavailable or an uninitialized floor reference cannot produce a valid obstacle estimate.

## Shared camera session

The mounted phone owns one `ARSession` configured for gravity-aligned world tracking and scene depth when supported. The same session is supplied to Nearby Interaction via `setARSession` before running camera-assisted ranging. The preview attaches to that session rather than starting another camera capture. UWB may keep the AR session running after preview closes; depth processing only occurs while preview is requested. Starting the first session resets tracking and invalidates the previous floor reference, which initializes again once tracking is Normal.

No ML model is added yet: this milestone validates measured geometry first. Person association and path planning come later.

## Verification

```sh
swiftc -module-cache-path /tmp/trashketball-swift-cache ios/TrashBotUWB/DepthGeometry.swift tests/depth/main.swift -o /tmp/trashketball-depth-tests
/tmp/trashketball-depth-tests
python3 -m unittest discover -s pi -p 'test_*.py' -v
```

Synthetic geometry checks cover floor rejection, a known-distance box, footprint exclusion, low-confidence samples, isolated noise, missing floor and rotated heading. Python tests cover authenticated inspection hold, motor stop, rejected movement and no replay after release. Simulator UI tests cover the unavailable-LiDAR state and tab responsiveness. Real depth accuracy, preview registration, assumed floor accuracy, and simultaneous UWB/ARKit must be tested on the mounted physical phone.

Apple references:
- https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth
- https://developer.apple.com/documentation/nearbyinteraction/nisession/setarsession(_:)


## Top-down player + obstacle map

The Lab now includes a local map computed entirely on the can phone, with no Pi mapping work or motor commands. It pans with the phone while keeping the AR session axes fixed (not geographic north). Choose a 4/8/12 m square view. Each background grid line is 1 m apart; the underlying observation cells are 15 cm squares.

- White circle/arrow: assumed 30 cm can footprint and rear-camera heading. Yellow: the same 46 cm × 3 m forward corridor shown on the camera preview.
- Orange cells: at least three medium/high-confidence obstacle samples in a cell, 8 cm–1.5 m above the assumed floor. Green cells: observed floor within ±6 cm of it. Dark areas are unknown; green is an observation, not a passage guarantee.
- Cells stay in AR world coordinates as the phone moves. They fade and expire after 4 s, and cells beyond 6 m from the phone are discarded. Floor returns cannot immediately erase a remembered obstacle. Clear map removes observations without resetting the shared AR/UWB session; a session reset/interruption discards the floor, map and player reference.
- Cyan dot: the player phone, using this can phone's UWB measurement and an AR camera pose captured at the NI callback (pose age <250 ms). Freshness is checked independently: targets disappear after 1 s without a usable update, when the peer disconnects, or when tracking/depth is unavailable. Distance alone never invents a bearing.
- Full 3D NI direction is transformed through the AR camera rotation, so its vertical component is removed by ground projection. With only camera-assisted horizontal angle, the map uses the phone-to-phone slant distance as horizontal range and marks the target **approximate**; differing phone heights shift its position. This is a diagnostic approximation, not a verified position for navigation.
- Cyan dashed line is only the measured bearing. The 1 m dashed ring marks a proposed stopping distance for future planning. There is no route planner or obstacle inflation yet, and nothing in this map drives the motors.

### Two-phone walk test (no Pi required)

1. Build/install the updated app on both phones. Connect them with the existing can/player roles and camera assistance enabled. Use the can phone's Lab for the map.
2. Disconnect motor power for a standalone test, acknowledge this in Lab, and start LiDAR. Hold the can phone at the assumed 44 cm lens height, rear camera facing forward and slightly down. Let tracking become Normal and UWB direction converge.
3. Put a box about 1–2 m in front. Orange cells should line up with it and the yellow corridor; move the box to the side and confirm the map location changes. Old box cells may persist for up to 4 s.
4. Keep the player phone stationary, preferably at the same height as the can phone to reduce the bearing-only range approximation. Confirm cyan lies on the correct side of the box. Use a tape measure and test a player directly ahead and to either side.
5. Carry the can phone sideways and turn gently, maintaining its height. The map pans and the white arrow rotates; the box and player should keep roughly the same positions relative to each other. Check this physically before planning routes.
6. Disconnect/stop the player session: cyan should disappear within 1 s. Stop the camera or cover it until tracking is limited: the map should become unavailable, rather than continuing to show live geometry. Clear map and resume scanning to confirm fresh observations return.

Apple's [Nearby Interaction camera-assistance overview](https://developer.apple.com/videos/play/wwdc2022/10008/) describes the shared ARSession requirements and recommends stationary peer devices for this mode. Validate with a stationary player first; moving-player behavior needs a separate physical test.
