// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <functional>
#include <optional>
#include <string>

namespace InputCommon {
class VirtualGamepad;
}

namespace IosUI {

/// True when a debugger (StikDebug) is attached, which is what lets iOS run JIT code.
bool IsJitEnabled();

/// Shows the game list in its own window, above SDL's.
void ShowLauncher();

/// Hides the game list once the game's window is up.
void HideLauncher();

/// The game the user picked since the last call, if any.
std::optional<std::string> TakeSelectedGame();

/// Shows an alert on the game list.
void ShowMessage(const std::string& title, const std::string& message);

/// Adds the on-screen controls on top of the game's UIWindow (an SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER).
void AttachOverlay(void* uikit_window, InputCommon::VirtualGamepad* gamepad,
                   std::function<void()> on_quit);

/// Shows or hides the on-screen buttons; the menu button always stays.
void SetOverlayVisible(bool visible);

} // namespace IosUI
