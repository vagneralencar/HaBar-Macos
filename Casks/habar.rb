cask "habar" do
  version "1.7.1"
  sha256 "c1564aa3660181cf15e60ffb2f8dcc40cebd228dc3735a05e13915c2798a9919"

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
