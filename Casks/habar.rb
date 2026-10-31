cask "habar" do
  version "1.7.0"
  sha256 "edf1fbe8013eb909f684c868701071657704d2041d4e0bbc011ecb55c677f4de"

  url "https://github.com/vagneralencar/HaBar-Macos/releases/download/v#{version}/HaBar.zip"
  name "HaBar"
  desc "Native macOS Menu Bar Controller for Home Assistant"
  homepage "https://github.com/vagneralencar/HaBar-Macos"

  depends_on macos: ">= :sonoma"

  app "HaBar.app"

  zap trash: [
    "~/.config/habar",
    "~/Library/Preferences/io.github.habar.menubar.plist",
  ]
end
