cask "habar" do
  version "1.5.0"
  sha256 :no_check

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
