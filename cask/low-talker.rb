# The body of the Homebrew cask in promptctl/homebrew-tap, Casks/low-talker.rb. Its version
# and sha256 are the two @-words scripts/update-cask fills in from a release; the tap's copy
# is that file's output, so a change to the cask is made here.
cask "low-talker" do
  version "@VERSION@"
  sha256 "@SHA256@"

  # The offline package: the network one replaces it, and only one may be installed.
  url "https://github.com/promptctl/low-talker/releases/download/v#{version}/LowTalker-offline.pkg"
  name "LowTalker"
  desc "Push-to-talk dictation that runs entirely on-device"
  homepage "https://github.com/promptctl/low-talker"

  # Every release so far is a pre-release, which :github_latest never offers.
  livecheck do
    url "https://github.com/promptctl/low-talker/releases"
    strategy :github_releases do |json|
      json.filter_map { |release| release["tag_name"]&.delete_prefix("v") unless release["draft"] }
    end
  end

  depends_on macos: :sequoia

  pkg "LowTalker-offline.pkg"

  # The package writes the app and its input method as plain files, so the receipt, which
  # lists both, is what forgets them; the two are deleted here as well for a Mac whose
  # receipt is gone.
  uninstall quit:    [
              "ai.promptctl.low-talker",
              "ai.promptctl.low-talker.inputmethod.dictation",
            ],
            pkgutil: "ai.promptctl.low-talker",
            delete:  [
              "/Applications/LowTalker.app",
              "/Library/Input Methods/LowTalker Input Method.app",
            ]

  zap trash: "~/Library/Containers/ai.promptctl.low-talker"

  caveats <<~EOS
    Open LowTalker. It asks for microphone access and for its input method to be switched on,
    and then prepares the model, which takes a few minutes the first time.
  EOS
end
