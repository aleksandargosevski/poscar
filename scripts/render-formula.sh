#!/usr/bin/env bash
# Prints the Homebrew formula for a released version.
# Usage: scripts/render-formula.sh <version> <sha256 of Poscar-<version>.zip>
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <version> <sha256>" >&2
  exit 1
fi

VERSION="$1"
SHA256="$2"
REPOSITORY="aleksandargosevski/poscar"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must look like 1.2.3, got \"$VERSION\"" >&2
  exit 1
fi
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Error: sha256 must be 64 lowercase hex characters" >&2
  exit 1
fi

cat <<EOF
class Poscar < Formula
  desc "Fast, keyboard-first mail app for Gmail and IMAP"
  homepage "https://github.com/${REPOSITORY}"
  url "https://github.com/${REPOSITORY}/releases/download/v${VERSION}/Poscar-${VERSION}.zip"
  sha256 "${SHA256}"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    # Homebrew enters an archive's single top-level directory, which here is Poscar.app itself.
    source = File.directory?("Contents") ? "." : "Poscar.app"
    (prefix/"Poscar.app").install Dir["#{source}/*"]
  end

  def caveats
    <<~EOS
      Make Poscar visible to Spotlight, Raycast and the Dock:
        ln -sfn #{opt_prefix}/Poscar.app /Applications/Poscar.app

      The link keeps pointing at the newest version after brew upgrade.
      Gmail needs an App Password: https://myaccount.google.com/apppasswords
      Shortcuts live in ~/.config/poscar/keybindings.json.
    EOS
  end

  test do
    assert_path_exists prefix/"Poscar.app/Contents/MacOS/Poscar"
  end
end
EOF
