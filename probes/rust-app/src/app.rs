use nihos_app::Services;

/// Render one frame. An input event changes state before the next frame.
pub fn draw<S: Services>(services: &mut S, selected: bool) -> Result<(), S::Error> {
    services.fill_rect(0, 0, 160, 80, if selected { 0x204060 } else { 0x101010 })?;
    services.text(8, 8, if selected { "Pressed" } else { "Ready" }, 0xffffff)
}
