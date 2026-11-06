// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

// iOS entry point. SDL owns the app lifecycle (SDL_MAIN_USE_CALLBACKS); the first iterations only
// show the game list, and the emulator boots the same way eden-cli does once a game is picked.

#define SDL_MAIN_USE_CALLBACKS 1
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <algorithm>
#include <cstdlib>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <sys/resource.h>

#include <fmt/format.h>

#include "common/fs/path_util.h"
#include "common/logging.h"
#include "common/scm_rev.h"
#include "common/settings.h"
#include "core/core.h"
#include "core/cpu_manager.h"
#include "core/file_sys/registered_cache.h"
#include "core/file_sys/vfs/vfs_real.h"
#include "core/hle/service/am/applet_manager.h"
#include "core/hle/service/filesystem/filesystem.h"
#include "core/loader/loader.h"
#include "input_common/drivers/virtual_gamepad.h"
#include "input_common/main.h"
#include "ios/ios_ui.h"
#include "network/network.h"
#include "video_core/gpu.h"
#include "video_core/rasterizer_interface.h"
#include "video_core/renderer_base.h"
#include "yuzu_cmd/emu_window/emu_window_sdl3_vk.h"
#include "yuzu_cmd/sdl_config.h"

namespace {

using Button = InputCommon::VirtualGamepad::VirtualButton;
using Stick = InputCommon::VirtualGamepad::VirtualStick;

struct IosState {
    Core::System system{};
    InputCommon::InputSubsystem input_subsystem{};
    std::unique_ptr<SdlConfig> config;
    std::unique_ptr<EmuWindow_SDL3> emu_window;
    std::vector<SDL_Gamepad*> gamepads;
    bool network_initialized{};
    bool booted{};
    bool paused_in_background{};
    bool quit_requested{};
};

std::string LoadError(Core::SystemResultStatus result) {
    switch (result) {
    case Core::SystemResultStatus::ErrorGetLoader:
        return "This file type is not supported, or the file is damaged.";
    case Core::SystemResultStatus::ErrorLoader:
        return "The game could not be loaded. Check that keys/prod.keys and title.keys are "
               "present and match your firmware.";
    case Core::SystemResultStatus::ErrorVideoCore:
        return "The GPU could not be started (Vulkan/MoltenVK).";
    default: {
        const u16 loader_id = u16(Core::SystemResultStatus::ErrorLoader);
        const u16 error_id = u16(result) - loader_id;
        return fmt::format("Error {:04X}-{:04X}: {}", loader_id, error_id,
                           Loader::ResultStatus(error_id));
    }
    }
}

bool Boot(IosState& state, const std::string& path) {
    LOG_INFO(Frontend, "Booting {}", path);
    if (!state.network_initialized) {
        state.network_initialized = Network::Init();
    }

    state.system.Initialize();
    // Vulkan through MoltenVK is the only renderer on iOS.
    Settings::values.renderer_backend.SetValue(Settings::RendererBackend::Vulkan);
    state.system.ApplySettings();

    state.emu_window =
        std::make_unique<EmuWindow_SDL3_VK>(&state.input_subsystem, state.system, true);

    state.system.SetContentProvider(std::make_unique<FileSys::ContentProviderUnion>());
    state.system.SetFilesystem(std::make_shared<FileSys::RealVfsFilesystem>());
    state.system.GetFileSystemController().CreateFactories(*state.system.GetFilesystem());
    state.system.GetUserChannel().clear();

    const Service::AM::FrontendAppletParameters load_parameters{
        .applet_id = Service::AM::AppletId::Application,
    };
    const auto result = state.system.Load(*state.emu_window, path, load_parameters);
    if (result != Core::SystemResultStatus::Success) {
        LOG_CRITICAL(Frontend, "Failed to load {}", path);
        state.emu_window.reset();
        IosUI::ShowMessage("Could not start the game", LoadError(result));
        return false;
    }

    state.system.GPU().Start();
    state.system.GetCpuManager().OnGpuReady();
    if (Settings::values.use_disk_shader_cache.GetValue()) {
        state.system.Renderer().ReadRasterizer()->LoadDiskResources(
            state.system.GetApplicationProcessProgramID(), std::stop_token{},
            [](VideoCore::LoadCallbackStage, size_t, size_t) {});
    }
    state.system.RegisterExitCallback([&state] { state.quit_requested = true; });
    state.system.RegisterExecuteProgramCallback([](std::size_t program_index) {
        LOG_WARNING(Frontend, "ExecuteProgram({}) is not supported on iOS", program_index);
    });

    void(state.system.Run());

    SDL_Window* window = SDL_GetKeyboardFocus();
    if (window == nullptr) {
        int count = 0;
        SDL_Window** windows = SDL_GetWindows(&count);
        window = count > 0 ? windows[0] : nullptr;
        SDL_free(windows);
    }
    void* uikit_window = window ? SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                                                         SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER,
                                                         nullptr)
                                : nullptr;
    if (uikit_window != nullptr) {
        IosUI::AttachOverlay(uikit_window, state.input_subsystem.GetVirtualGamepad(),
                             [&state] { state.quit_requested = true; });
        IosUI::SetOverlayVisible(state.gamepads.empty());
    }
    IosUI::HideLauncher();
    state.booted = true;
    return true;
}

// Physical controllers (MFi, Xbox, PlayStation, Backbone...) drive player 1 through the same
// virtual pad as the touch controls, so they work without any input configuration.
// Buttons are matched by position: the right face button is the Switch's A.
std::optional<Button> MapGamepadButton(Uint8 button) {
    switch (button) {
    case SDL_GAMEPAD_BUTTON_EAST: return Button::ButtonA;
    case SDL_GAMEPAD_BUTTON_SOUTH: return Button::ButtonB;
    case SDL_GAMEPAD_BUTTON_NORTH: return Button::ButtonX;
    case SDL_GAMEPAD_BUTTON_WEST: return Button::ButtonY;
    case SDL_GAMEPAD_BUTTON_LEFT_STICK: return Button::StickL;
    case SDL_GAMEPAD_BUTTON_RIGHT_STICK: return Button::StickR;
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return Button::TriggerL;
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return Button::TriggerR;
    case SDL_GAMEPAD_BUTTON_START: return Button::ButtonPlus;
    case SDL_GAMEPAD_BUTTON_BACK: return Button::ButtonMinus;
    case SDL_GAMEPAD_BUTTON_GUIDE: return Button::ButtonHome;
    case SDL_GAMEPAD_BUTTON_MISC1: return Button::ButtonCapture;
    case SDL_GAMEPAD_BUTTON_DPAD_UP: return Button::ButtonUp;
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return Button::ButtonDown;
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return Button::ButtonLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return Button::ButtonRight;
    default: return std::nullopt;
    }
}

void OnGamepadEvent(IosState& state, const SDL_Event& event) {
    auto* const pad = state.input_subsystem.GetVirtualGamepad();
    switch (event.type) {
    case SDL_EVENT_GAMEPAD_ADDED:
        if (SDL_Gamepad* gamepad = SDL_OpenGamepad(event.gdevice.which)) {
            state.gamepads.push_back(gamepad);
            IosUI::SetOverlayVisible(false);
        }
        return;
    case SDL_EVENT_GAMEPAD_REMOVED:
        std::erase_if(state.gamepads, [&](SDL_Gamepad* gamepad) {
            if (SDL_GetGamepadID(gamepad) != event.gdevice.which) {
                return false;
            }
            SDL_CloseGamepad(gamepad);
            return true;
        });
        if (state.gamepads.empty()) {
            IosUI::SetOverlayVisible(true);
        }
        return;
    default:
        break;
    }
    if (pad == nullptr || !state.booted) {
        return;
    }
    if (event.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN || event.type == SDL_EVENT_GAMEPAD_BUTTON_UP) {
        if (const auto button = MapGamepadButton(event.gbutton.button)) {
            pad->SetButtonState(0, *button, event.gbutton.down);
        }
        return;
    }
    if (event.type != SDL_EVENT_GAMEPAD_AXIS_MOTION) {
        return;
    }
    SDL_Gamepad* gamepad = SDL_GetGamepadFromID(event.gaxis.which);
    if (gamepad == nullptr) {
        return;
    }
    const auto axis = [&](SDL_GamepadAxis a) {
        return std::clamp(SDL_GetGamepadAxis(gamepad, a) / 32767.0f, -1.0f, 1.0f);
    };
    switch (event.gaxis.axis) {
    case SDL_GAMEPAD_AXIS_LEFTX:
    case SDL_GAMEPAD_AXIS_LEFTY:
        // SDL has y growing downwards; the core takes up as positive.
        pad->SetStickPosition(0, Stick::Left, axis(SDL_GAMEPAD_AXIS_LEFTX),
                              -axis(SDL_GAMEPAD_AXIS_LEFTY));
        break;
    case SDL_GAMEPAD_AXIS_RIGHTX:
    case SDL_GAMEPAD_AXIS_RIGHTY:
        pad->SetStickPosition(0, Stick::Right, axis(SDL_GAMEPAD_AXIS_RIGHTX),
                              -axis(SDL_GAMEPAD_AXIS_RIGHTY));
        break;
    case SDL_GAMEPAD_AXIS_LEFT_TRIGGER:
        pad->SetButtonState(0, Button::TriggerZL, axis(SDL_GAMEPAD_AXIS_LEFT_TRIGGER) > 0.5f);
        break;
    case SDL_GAMEPAD_AXIS_RIGHT_TRIGGER:
        pad->SetButtonState(0, Button::TriggerZR, axis(SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) > 0.5f);
        break;
    default:
        break;
    }
}

} // namespace

extern "C" SDL_AppResult SDL_AppInit(void** appstate, int argc, char** argv) {
    SDL_SetHint(SDL_HINT_MAIN_CALLBACK_RATE, "120");
    SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "2");
    SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");
    // Touches are routed by the overlay and SDL's finger events; no mouse emulation.
    SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");

    auto* state = new IosState();
    *appstate = state;

    if (struct rlimit rl; getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        rl.rlim_cur = std::min<rlim_t>(8192, rl.rlim_max);
        setrlimit(RLIMIT_NOFILE, &rl);
    }

    Common::Log::Initialize();
    Common::Log::Start();
    LOG_INFO(Frontend, "Lichii for iOS {} | {}-{}", Common::g_build_name, Common::g_scm_branch,
             Common::g_scm_desc);
    LOG_INFO(Frontend, "JIT {}", IosUI::IsJitEnabled() ? "enabled (debugger attached)"
                                                       : "NOT enabled");

    state->config = std::make_unique<SdlConfig>(std::nullopt);

    // Gamepad events are needed before a game starts, so a controller connected at the game list
    // is already known. The emulator window initializes video later.
    SDL_Init(SDL_INIT_GAMEPAD);

    IosUI::ShowLauncher();
    return SDL_APP_CONTINUE;
}

extern "C" SDL_AppResult SDL_AppIterate(void* appstate) {
    auto* state = static_cast<IosState*>(appstate);
    if (state->quit_requested) {
        return SDL_APP_SUCCESS;
    }
    if (!state->booted) {
        if (const auto game = IosUI::TakeSelectedGame()) {
            Boot(*state, *game);
        }
        return SDL_APP_CONTINUE;
    }
    state->emu_window->ApplyPendingTitle();
    return state->emu_window->IsOpen() ? SDL_APP_CONTINUE : SDL_APP_SUCCESS;
}

extern "C" SDL_AppResult SDL_AppEvent(void* appstate, SDL_Event* event) {
    auto* state = static_cast<IosState*>(appstate);
    switch (event->type) {
    case SDL_EVENT_WILL_ENTER_BACKGROUND:
        // iOS kills apps that use the GPU in the background.
        if (state->booted && state->system.IsPoweredOn()) {
            void(state->system.Pause());
            state->paused_in_background = true;
        }
        return SDL_APP_CONTINUE;
    case SDL_EVENT_DID_ENTER_FOREGROUND:
        if (state->paused_in_background) {
            void(state->system.Run());
            state->paused_in_background = false;
        }
        return SDL_APP_CONTINUE;
    case SDL_EVENT_TERMINATING:
        state->quit_requested = true;
        return SDL_APP_CONTINUE;
    default:
        break;
    }
    if (event->type >= SDL_EVENT_GAMEPAD_AXIS_MOTION && event->type <= SDL_EVENT_GAMEPAD_STEAM_HANDLE_UPDATED) {
        OnGamepadEvent(*state, *event);
    }
    if (state->emu_window) {
        state->emu_window->OnEvent(*event);
    }
    return SDL_APP_CONTINUE;
}

extern "C" void SDL_AppQuit(void* appstate, SDL_AppResult result) {
    auto* state = static_cast<IosState*>(appstate);
    if (state == nullptr) {
        return;
    }
    if (state->system.IsPoweredOn()) {
        void(state->system.Pause());
        state->system.ShutdownMainProcess();
    }
    for (SDL_Gamepad* gamepad : state->gamepads) {
        SDL_CloseGamepad(gamepad);
    }
    const bool network_initialized = state->network_initialized;
    delete state;
    if (network_initialized) {
        Network::Shutdown();
    }
}

#define VMA_IMPLEMENTATION
#include "video_core/vulkan_common/vma.h"
