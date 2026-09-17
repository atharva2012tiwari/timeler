#!/usr/bin/env bash
set -e

echo "==> Building Timeler Release Binary..."
flutter build linux --release

echo "==> Verifying Desktop file..."
desktop-file-validate packaging/linux/com.timeler.Timeler.desktop

echo "==> Verifying AppStream Metadata..."
appstreamcli validate --no-net packaging/linux/com.timeler.Timeler.metainfo.xml

echo "==> Packaging assets ready in packaging/linux/:"
ls -la packaging/linux/

echo ""
echo "✔ All files are ready for Flathub submission!"
