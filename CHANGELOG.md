# Changelog

## Unreleased

### Added

- `Start-GUI.bat` - Easier one click program launch  
- Updated Sunshine to the latest version v2026.516.143833 
- Added a new standalone PowerShell/WPF GUI project under `GUI`.
- Added `GUI/MainWindow.xaml` for the XAML-based interface.
- Added `GUI/EnhancedGpuPv.Gui.ps1` as the GUI launcher and workflow wrapper.
- Added `GUI/README.md` with GUI run notes.
- Added `Start-GUI.bat` for double-click GUI launch from the repo root.
- Added a `PreChecks` tab before `Create VM`.
- Added structured PreChecks results shown in the GUI:
  - overall status
  - last run time
  - warning count
  - blocking issue count
  - computer type
  - Windows compatibility
  - Hyper-V status
  - WSL status
  - partitionable GPU status and details
- Added generated PreChecks result output at `GUI\.generated\PreChecks.latest.json`.
- Added persistent operation logs under `GUI\.generated\logs`.
- Added modal/fallback error reporting for failed operations.
- Added a single `Install profile` dropdown for valid setup combinations:
  - `GPU-PV only`
  - `Parsec + ParsecVDA`
  - `Parsec + Virtual Display Driver`
  - `Sunshine + Virtual Display Driver`
  - `Sunshine + ParsecVDA`
- Added inline explanatory text for install profiles.
- Added inline explanatory text for `Language tag` and `Timezone`.

### Changed

- GUI now starts maximized.
- Header status indicator is fixed in position and expands up to a wider maximum width.
- Moved action buttons into their relevant tabs:
  - `Run PreChecks` is inside the `PreChecks` tab.
  - `Refresh Host Data` and `Create VM` are inside the `Create VM` tab.
- Changed GUI operation execution to use generated runner scripts and log polling instead of fragile live stdout callbacks.
- Changed generated `Create VM` scripts to use the original project root for repo assets.
- Changed generated `Update GPU driver` scripts to import `Add-VMGpuPartitionAdapterFiles.psm1` using a full module path.
- Changed `vmconnect` launch during Create VM to run detached so the GUI can finish/unlock.
- Changed launch/relaunch paths to hide PowerShell windows where possible.

### Fixed

- Fixed GUI closing or disappearing immediately after starting operations.
- Fixed logs not appearing fully in the GUI.
- Fixed Create VM failures caused by generated scripts looking for `VMScripts`, `User`, and `gpt.ini` under `GUI\.generated`.
- Fixed Update GPU Driver generated script placing content before `Param(...)`.
- Fixed Update GPU Driver module import path errors.
- Fixed Update GPU Driver attempting to continue when the selected VM does not exist.
- Fixed PreChecks being marked failed when only warnings were present.
- Fixed WPF popup errors caused by PowerShell's special `$Matches` variable.
- Fixed WPF collection overload errors in error display paths by using a simpler fallback popup.
- Fixed blank `?` info buttons by replacing them with inline helper text.
- Fixed status text being cut off in the header.
- Fixed misleading success reports when scripts emitted known failure text but returned exit code `0`.

### Notes

- Existing project scripts are not edited by the GUI. The GUI creates temporary generated scripts under `GUI\.generated`.
- `GUI\.generated` can be deleted before copying the project to another machine.
- User-selected ISO and VHD paths must still be chosen per machine.

