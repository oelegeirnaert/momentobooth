# MQTT integration settings
This settings panel allows setting up the MQTT integration feature.

If the integration is enabled, the application will publish MQTT messages to the specified broker and will subscribe for commands.

## Connection
This section contains all settings related to the connection with and authentication for your MQTT broker. Set these up according to your broker settings.

## Client
These settings specify the publication topic and client ID.

## Immich integration
The MQTT settings screen also includes a section for Immich publishing. When enabled, each captured photo can be uploaded to a configured Immich server and placed into the configured album automatically.

To use it:

1. Enable `Immich Publishing`.
2. Enter the Immich server URL, for example `https://immich.example.com`.
3. Set the album name you want photos to be added to.
4. Add the API key for the Immich instance.
5. Optionally use `Test Immich connection` to confirm the server and key work before a capture session.

If the album does not exist yet, MomentoBooth will create it automatically. If the configured album name is blank, the photo is uploaded without adding it to an album.

## Home Assitant integration
Integration with Home Assistant is available, so automations can be created that respond to the state of the app in real time. Settings are available for the discovery topic (usually `homeassistant`), and the device ID.
