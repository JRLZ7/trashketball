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
