# Wi-Fi settings

From Home, open Settings and select **Wi-Fi** (or press `w`). The screen
shows connection progress and the IPv4 address when a lease is available.
Select **Connect** (`c`), enter an ASCII SSID, press Enter, enter the password,
and press Enter again. An empty password is accepted for an open network.
The password is masked; Escape cancels and clears the input. Select
**Disconnect** (`d`) to stop using the current configuration.

This first version uses the normal CPU0 network owner and retains credentials
only in its volatile configuration for reconnects. They are not saved across
reboot. Nearby AP scanning, saved networks, and persistent auto-connect are
not implemented. Do not place credentials in the editor, logs, or source tree.

The form uses the private input path rather than the document or command
history. The transient form is erased on cancellation, on workspace failure,
and after a connection request succeeds or fails. The owner validates and
copies the new configuration before restarting the C6 connection. Host tests
and image audits do not establish physical SD/Wi-Fi coexistence, wireless
authentication, power-loss behavior, or hardware security properties.
