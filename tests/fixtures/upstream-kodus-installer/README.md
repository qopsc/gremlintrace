# Upstream kodus-installer snapshot for offline bats.

Pin: `PIN.yml` `kodus_installer_ref` must equal `versions.yml:kodus_installer_ref`.

Included files (keep this list in lockstep with the tests):

- `.env.example`
- `docker-compose.yml`
- `scripts/install.sh`
- `scripts/validate-env.sh`
- `scripts/generate-secrets.sh`
- `scripts/schema-vars.sh`
- `scripts/doctor.sh`

Refresh after bumping `kodus_installer_ref` (atomic: write to a temp dir, then replace):

```sh
REF=$(python3 -c "import yaml; print(yaml.safe_load(open('versions.yml'))['kodus_installer_ref'])")
tmp=$(mktemp -d)
git clone --quiet https://github.com/kodustech/kodus-installer.git "$tmp/src"
git -C "$tmp/src" checkout --quiet "$REF"
dest=tests/fixtures/upstream-kodus-installer
rm -rf "$dest.new" && mkdir -p "$dest.new/scripts"
cp "$tmp/src/.env.example" "$tmp/src/docker-compose.yml" "$dest.new/"
cp "$tmp/src/scripts/install.sh" "$tmp/src/scripts/validate-env.sh" \
   "$tmp/src/scripts/generate-secrets.sh" "$tmp/src/scripts/schema-vars.sh" \
   "$tmp/src/scripts/doctor.sh" "$dest.new/scripts/"
printf 'kodus_installer_ref: "%s"\n' "$REF" >"$dest.new/PIN.yml"
rm -rf "$dest" && mv "$dest.new" "$dest"
rm -rf "$tmp"
```
