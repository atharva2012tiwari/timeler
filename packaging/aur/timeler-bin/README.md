# Timeler AUR Package (`timeler-bin`)

Official Arch User Repository (AUR) package for Timeler.

## For Arch Linux Users

### Using an AUR helper
```bash
yay -S timeler-bin
# or
paru -S timeler-bin
```

### Manual installation via `makepkg`
```bash
git clone https://aur.archlinux.org/timeler-bin.git
cd timeler-bin
makepkg -si
```

---

## For Maintainers: Publishing to AUR

1. Ensure your SSH key is linked to your Arch Linux account: https://aur.archlinux.org/account
2. Clone the AUR repository:
   ```bash
   git clone ssh://aur@aur.archlinux.org/timeler-bin.git /tmp/aur-timeler-bin
   ```
3. Copy the files from `packaging/aur/timeler-bin/` into the cloned repository:
   ```bash
   cp packaging/aur/timeler-bin/PKGBUILD packaging/aur/timeler-bin/.SRCINFO /tmp/aur-timeler-bin/
   ```
4. Commit and push:
   ```bash
   cd /tmp/aur-timeler-bin
   git add PKGBUILD .SRCINFO
   git commit -m "Update timeler-bin to v1.2.0"
   git push origin master
   ```
