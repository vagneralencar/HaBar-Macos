cask "habar" do
  version "1.8.1"
  sha256 "59d59eb7e1f02691ec19df848429eb82df6a537a0b8bca519db5d7d8bb4d1f6f"

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
