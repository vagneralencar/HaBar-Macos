cask "habar" do
  version "1.6.0"
  sha256 "3d434afd65db0b11ccc4eb2d12a7dc607f4c5196a5ec2af7cee9cc308028a308"

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
