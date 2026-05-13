# tpdl

Small PowerShell and Bash installers for Typst packages distributed from Git
instead of Typst Universe.

## Usage

### Pinned one-liners

- PowerShell:

   ```powershell
   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/hongjr03/tpdl/v0.1.0/tpdl.ps1))) https://github.com/hongjr03/ouc-bachelor-thesis.git -Ref v0.3.1
   ```

- Bash:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/hongjr03/tpdl/v0.1.0/tpdl.sh | bash -s -- https://github.com/hongjr03/ouc-bachelor-thesis.git --ref v0.3.1
   ```

### Local scripts

- PowerShell:

   ```powershell
   .\tpdl.ps1 https://github.com/owner/package-repo.git
   .\tpdl.ps1 https://github.com/owner/package-repo.git -Ref v0.1.0 -Namespace local
   .\tpdl.ps1 https://github.com/owner/package-repo.git -PackagePath D:\typst-packages -Force
   ```

- Bash:

   ```bash
   ./tpdl.sh https://github.com/owner/package-repo.git
   ./tpdl.sh https://github.com/owner/package-repo.git --ref v0.1.0 --namespace local
   ./tpdl.sh https://github.com/owner/package-repo.git --package-path /tmp/typst-packages --force
   ```

Then import the package with the installed identifier:

```typst
#import "@local/package-name:0.1.0": *
```

## Notes

- `typst.toml` must be in the repository root.
- The scripts require `[package]` fields `name`, `version`, and `entrypoint`.
- `version` must use Typst's `major.minor.patch` format.
- Existing package versions are kept by default. Use `--force` or `-Force` to
  replace them.
- `.git` is never copied.
- `package.exclude` is applied on a best-effort basis so Git installs resemble
  published package bundles more closely.
