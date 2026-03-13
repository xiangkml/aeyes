# Performance Improvement Analysis: AEyes (Initial -> Latest)

## 1. Streaming Audio Playback (Biggest Impact on Response Speed)

Initial used `AudioPlayer` from `audioplayers`, which required:

- Buffering PCM chunks until about 48,000 bytes accumulated, which is about 1 second of audio.
- Converting raw PCM into WAV format before playback.
- Playing each WAV chunk as a separate file-like source.

Latest switched to `FlutterSoundPlayer` from `flutter_sound`, which:

- Opens a streaming audio sink with `startPlayerFromStream`.
- Feeds raw PCM bytes directly to the player.
- Removes the WAV conversion step.
- Starts playback as soon as bytes arrive instead of waiting for a large buffer.

Impact:

The user hears the AI response almost immediately instead of waiting around 1 second or more for a playback buffer to fill. This is the biggest reason the AI now feels much faster and more human.

## 2. Continuous Camera Frame Streaming (Faster Visual Understanding)

Initial used `takePicture()` every 2 seconds, which is slow because it:

- Captures a full image snapshot.
- Uses file-style image capture flow.
- Sends visual updates infrequently.

Latest uses `startImageStream()` together with `FrameSendScheduler`:

- Receives raw camera frames continuously.
- Sends the latest useful frame roughly every 450 ms instead of every 2 seconds.
- Avoids disk or file capture overhead.
- Encodes JPEG frames in a background isolate using `compute()`.
- Downscales frames to a maximum width of 640 px with quality 72 to reduce payload size.

Impact:

The AI receives visual context much more often and with lower latency, so it reacts faster to the environment and appears more aware and intelligent.

## 3. Cloud Backend Relay (WebSocket Proxy on Cloud Run)

Initial connected directly from the mobile app to Gemini's WebSocket API.

Latest optionally routes through a Cloud Run backend that:

- Proxies WebSocket traffic between the app and Gemini.
- Keeps the API key on the server side.
- Stores session state in Firestore.
- Can improve network path stability and latency.

Impact:

This likely improves reliability and can reduce round-trip delays, especially on unstable mobile networks.

## 4. Barge-In Detection (Natural Conversational Flow)

Initial had no real interruption handling while the assistant was speaking.

Latest adds amplitude-based speech detection:

- Measures microphone amplitude in real time.
- Detects likely user speech using dB thresholds.
- Tracks assistant-speaking state.
- Clears or interrupts playback when the user starts talking.

Impact:

The conversation feels much more natural because the user can interrupt the assistant, similar to speaking with a real person.

## 5. Enhanced System Instruction (Smarter AI Behavior)

Initial used a shorter, more generic instruction.

Latest uses a much more detailed system instruction that emphasizes:

- Real-time spoken guidance.
- Hazard-first responses.
- Clear spatial directions such as left, right, ahead, near, and far.
- Safety while walking.
- Guided object search.
- Brief, action-oriented communication.

Impact:

The AI responds in a more useful, contextual, and human-like way. This is not raw runtime performance, but it strongly improves perceived intelligence and response quality.

## 6. Connection Readiness Guarantee

Initial sent setup and then proceeded without a strong readiness confirmation.

Latest adds a `Completer<void>` and waits for confirmed setup completion with timeout handling.

Impact:

This reduces startup race conditions and avoids losing early frames, audio, or initial interaction messages.

## Summary Table

| Change | Performance Effect |
| --- | --- |
| `audioplayers` -> `flutter_sound` streaming | Eliminates about 1 second of playback delay |
| `takePicture()` -> `startImageStream()` + scheduler | Much faster visual updates |
| Background JPEG encoding with `compute()` | Reduces UI jank |
| Cloud Run WebSocket relay | Better reliability and possibly lower latency |
| Barge-in detection | More natural real-time interaction |
| Stronger system instruction | Better perceived intelligence |
| Setup readiness with `Completer` | Fewer dropped early interactions |
| Frame downscaling and compression | Faster frame transfer |

## Final Conclusion

The single biggest improvement is the audio playback architecture change.

Switching from delayed, buffer-based WAV playback to direct PCM streaming removed the most obvious response lag. Combined with faster camera frame delivery, background image encoding, and better interruption handling, the latest AEyes version feels significantly faster and more human in live conversation.